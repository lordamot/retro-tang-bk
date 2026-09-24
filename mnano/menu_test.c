/*
  menu_test.c - the OSD menu on the host (make menu-test).

  menu.c is compiled with -DSDL, which is its host switch: no FreeRTOS,
  menu_init() takes a u8g2 to draw into.  Everything else it calls is
  stubbed here - the card has three files a slot, the core takes the
  values into a log - and the menu is driven through menu_do() with the
  events usb_host.c would send.  Each screen worth looking at is dumped
  as a 128x64 text bitmap under the directory given as the first
  argument (tools/osd_png.py makes PNGs of them), and the things that
  can be asserted are: which form is open and which entry is highlighted
  after a key, what the core was sent, which slot and extensions a file
  selector asks the card for, what image it opens, what the main form
  offers, and that the text page scrolls and returns.

  The walk: the main form, its four AZ unit selectors (each entered,
  closed with ESC and reopened, left by the title; the first also mounts
  and ejects an image, through azbk.c's az_set_unit and never through
  sd_card.v's slots), Reset, the AZ's cold reset, Hardware: every value
  stepped with the cursor keys (and Space) both ways and back, ESC (the
  OSD closes and reopens on the same form), the title back to the main
  form, About opened, scrolled and closed, Debug, Save settings.
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "u8g2.h"
#include "ff.h"
#include "diskio.h"
#include "sysctrl.h"
#include "sdc.h"
#include "azbk.h"
#include "menu.h"

unsigned char core_id = CORE_ID_BK;

//------------------------------------------------------------------------
// stubs
//------------------------------------------------------------------------
void vTaskDelay(int ms) { (void)ms; }
// the AZ controller's side (azbk.c): the boot, and the units the OSD mounts
static int az_boots, az_sets, az_set_unit_last = -1;
static char *az_units[AZ_UNITS];
void az_boot(spi_t *spi) { (void)spi; az_boots++; }
int  az_set_unit(int unit, const char *path) {
  assert(unit >= 0 && unit < AZ_UNITS);
  if(az_units[unit]) free(az_units[unit]);
  az_units[unit] = path ? strdup(path) : NULL;
  az_sets++; az_set_unit_last = unit;
  return 0;
}
const char *az_unit_path(int unit) { return az_units[unit]; }
unsigned long az_unit_blocks(int unit) { return az_units[unit] ? 1600 : 0; }
const char *az_boot_line(int n) { return n == 0 ? "ROM: (menu test, no card)" : NULL; }
void az_handle_event(void) {}
void sdc_lock(void) {}
void sdc_unlock(void) {}
int  sdc_is_ready(void) { return 1; }

// the OSD's visibility, as osd_enable() would set it
static int osd_visible;
void osd_enable(osd_t *osd, char en) { (void)osd; osd_visible = en; }

// FatFs never gets a volume here: f_open fails and the menu takes its
// defaults, which is the path a card without an .ini takes
DSTATUS disk_initialize(BYTE p) { (void)p; return STA_NOINIT; }
DSTATUS disk_status(BYTE p) { (void)p; return STA_NOINIT; }
DRESULT disk_read(BYTE p, BYTE *b, LBA_t s, UINT c) { (void)p; (void)b; (void)s; (void)c; return RES_NOTRDY; }
DRESULT disk_write(BYTE p, const BYTE *b, LBA_t s, UINT c) { (void)p; (void)b; (void)s; (void)c; return RES_NOTRDY; }
DRESULT disk_ioctl(BYTE p, BYTE c, void *b) { (void)p; (void)c; (void)b; return RES_NOTRDY; }

// what the core was told: a log of (id, value)
static char set_log[256][2];
static int  set_n;
void sys_set_val(spi_t *spi, char id, uint8_t v) {
  (void)spi;
  if(set_n < 256) { set_log[set_n][0] = id; set_log[set_n][1] = v; }
  set_n++;
}
void sys_get_debug(spi_t *spi, unsigned char *buf, int len) { (void)spi; memset(buf, 0, len); }
static int set_last(char id) {
  for(int i=set_n-1;i>=0;i--) if(set_log[i][0] == id) return set_log[i][1];
  return -1;
}
static int set_count(char id) {
  int n = 0;
  for(int i=0;i<set_n;i++) if(set_log[i][0] == id) n++;
  return n;
}

// the card: one directory a slot, three files each
static char *cwd[MAX_DRIVES + 1];
static char *image_name[MAX_DRIVES + 1];
static int  open_drive = -1, open_n;          // the last sdc_image_open()
static int  readdir_drive = -1;               // the last sdc_readdir()
static const char *readdir_exts;
char *sdc_get_image_name(int drive) { return image_name[drive]; }
char *sdc_get_cwd(int drive) { if(!cwd[drive]) cwd[drive] = strdup(CARD_MOUNTPOINT); return cwd[drive]; }
void sdc_set_default(int drive, const char *name) { (void)drive; (void)name; }
void sdc_set_image_name(int drive, const char *name) {
  assert(drive >= 0 && drive <= MAX_DRIVES);
  if(image_name[drive]) free(image_name[drive]);
  image_name[drive] = name ? strdup(name) : NULL;
}
int sdc_image_open(int drive, char *name) {
  assert(drive >= 0 && drive < MAX_DRIVES);
  if(image_name[drive]) free(image_name[drive]);
  image_name[drive] = name ? strdup(name) : NULL;
  open_drive = drive; open_n++;
  return 0;
}
sdc_dir_t *sdc_readdir(int drive, char *name, const char *exts) {
  static sdc_dir_entry_t files[4];
  static sdc_dir_t dir = { 4, files };
  static char n0[] = "/No Disk", n1[64], n2[64], n3[64];
  assert(drive >= 0 && drive <= MAX_DRIVES);
  (void)name;
  readdir_drive = drive; readdir_exts = exts;
  char ext[8] = "img";
  sscanf(exts, "%7[a-z]", ext);
  files[0].name = n0; files[0].is_dir = 1;
  snprintf(n1, sizeof(n1), "GAME.%s", ext); files[1].name = n1; files[1].is_dir = 0;
  snprintf(n2, sizeof(n2), "SYSTEM.%s", ext); files[2].name = n2; files[2].is_dir = 0;
  snprintf(n3, sizeof(n3), "A rather long file name that has to scroll.%s", ext); files[3].name = n3; files[3].is_dir = 0;
  return &dir;
}

//------------------------------------------------------------------------
// the screen
//------------------------------------------------------------------------
static u8g2_t u8g2;
static const char *outdir = ".";
static int shots;

static void shot(const char *name) {
  char path[256];
  snprintf(path, sizeof(path), "%s/%02d-%s.txt", outdir, ++shots, name);
  FILE *f = fopen(path, "w");
  if(!f) { perror(path); exit(1); }
  for(int y=0;y<64;y++) {
    for(int x=0;x<128;x++) fputc(u8x8_GetBitmapPixel(u8g2_GetU8x8(&u8g2), x, y) ? '#' : '.', f);
    fputc('\n', f);
  }
  fclose(f);
}

static int errors;
#define CHECK(cond, ...) do { if(!(cond)) { errors++; printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while(0)

// the value the highlighted 'L' entry shows, to check it against the core
static int stepped(menu_t *menu, char id, int step, int expect) {
  menu_do(menu, step > 0 ? MENU_EVENT_RIGHT : MENU_EVENT_LEFT);
  return set_last(id) == expect;
}

// the extension list a selector asked for: ';' terminated in the form
static int exts_are(const char *want) {
  return readdir_exts && strncmp(readdir_exts, want, strlen(want)) == 0 && readdir_exts[strlen(want)] == ';';
}

// the highlighted entry is the title or one of the four rows on screen
#define CHECK_VISIBLE(menu) CHECK((menu)->entry - (menu)->offset >= ((menu)->entry ? 1 : 0) && (menu)->entry - (menu)->offset <= 4 && \
                                  (menu)->offset >= 0 && (menu)->offset <= ((menu)->entries > 5 ? (menu)->entries - 5 : 0), \
                                  "entry %d off screen: offset %d of %d", (menu)->entry, (menu)->offset, (menu)->entries)

// a file selector on the current entry of a form: opened, closed with
// ESC and reopened, left by its title back to the entry it came from
static void selector(menu_t *menu, const char *what, int form, int entry, int drive, const char *exts) {
  int n = set_n;
  menu_do(menu, MENU_EVENT_LEFT); menu_do(menu, MENU_EVENT_RIGHT);
  CHECK(set_n == n && menu->form == form && menu->entry == entry, "%s: left/right on the selector entry did something", what);
  readdir_drive = -1; readdir_exts = NULL;
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(menu->form == MENU_FORM_FSEL, "%s: selector not open, form %d", what, menu->form);
  CHECK(menu->entries == 5, "%s: selector shows %d entries, expected 5 (No Disk + 3 files)", what, menu->entries);
  CHECK(readdir_drive == drive, "%s: selector read slot %d, expected %d", what, readdir_drive, drive);
  CHECK(exts_are(exts), "%s: selector asked for '%.12s', expected '%s'", what, readdir_exts ? readdir_exts : "(null)", exts);
  menu_do(menu, MENU_EVENT_HIDE);
  CHECK(!osd_visible && menu->form == MENU_FORM_FSEL, "%s: ESC on the selector", what);
  menu_do(menu, MENU_EVENT_SHOW);
  CHECK(osd_visible && menu->form == MENU_FORM_FSEL, "%s: the selector did not come back", what);
  while(menu->entry) menu_do(menu, MENU_EVENT_UP);
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(menu->form == form && menu->entry == entry, "%s: back from the selector: form %d entry %d, expected %d/%d",
        what, menu->form, menu->entry, form, entry);
}

// the selector on the current entry loads its second file into `drive`,
// then ejects it through "No Disk"
static void load_and_eject(menu_t *menu, const char *what, int form, int entry, int drive, const char *file) {
  int n = open_n;
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(menu->form == MENU_FORM_FSEL && menu->entry == 1, "%s: selector opens on entry %d", what, menu->entry);
  menu_do(menu, MENU_EVENT_DOWN);
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(open_n == n+1 && open_drive == drive, "%s: image opened %d times, on slot %d", what, open_n - n, open_drive);
  CHECK(image_name[drive] && strcmp(image_name[drive], file) == 0, "%s: slot %d holds '%s', expected '%s'",
        what, drive, image_name[drive] ? image_name[drive] : "(null)", file);
  CHECK(menu->form == form && menu->entry == entry, "%s: after loading: form %d entry %d", what, menu->form, menu->entry);
  menu_do(menu, MENU_EVENT_SELECT);       // reopened, it highlights the loaded file
  CHECK(menu->form == MENU_FORM_FSEL && menu->entry == 2, "%s: selector reopens on entry %d, expected the file", what, menu->entry);
  menu_do(menu, MENU_EVENT_UP);           // No Disk
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(open_n == n+2 && open_drive == drive && !image_name[drive], "%s: No Disk did not eject slot %d", what, drive);
  CHECK(menu->form == form && menu->entry == entry, "%s: after ejecting: form %d entry %d", what, menu->form, menu->entry);
}

// an On/Off 'L' entry with default `def`: right, right wraps, left, left wraps
static void toggle(menu_t *menu, const char *what, char id, int def) {
  int n = set_n;
  CHECK(stepped(menu, id, +1, !def), "right on %s: %c=%d", what, id, set_last(id));
  CHECK(stepped(menu, id, +1,  def), "right wraps %s: %c=%d", what, id, set_last(id));
  CHECK(stepped(menu, id, -1, !def), "left on %s: %c=%d", what, id, set_last(id));
  CHECK(stepped(menu, id, -1,  def), "left wraps %s: %c=%d", what, id, set_last(id));
  CHECK(set_n == n+4, "%s: %d sends for four steps", what, set_n - n);
}

// a three-way 'L' entry with default 0: right twice, wrap, back
static void three(menu_t *menu, const char *what, char id) {
  int n = set_n;
  CHECK(stepped(menu, id, +1, 1), "right on %s: %c=%d", what, id, set_last(id));
  CHECK(stepped(menu, id, +1, 2), "right again on %s: %c=%d", what, id, set_last(id));
  CHECK(stepped(menu, id, +1, 0), "right wraps %s: %c=%d", what, id, set_last(id));
  CHECK(stepped(menu, id, -1, 2), "left wraps %s: %c=%d", what, id, set_last(id));
  CHECK(stepped(menu, id, -1, 1) && stepped(menu, id, -1, 0), "left back on %s: %c=%d", what, id, set_last(id));
  CHECK(set_n == n+6, "%s: %d sends for six steps", what, set_n - n);
}

// the selector on the current entry mounts its second file on `unit`
// (az_set_unit gets the card's path, the slot remembers the name), then
// ejects it through "No Disk"
static void mount_and_eject(menu_t *menu, const char *what, int form, int entry, int unit, const char *file) {
  int n = az_sets, o = open_n;
  char path[128];
  snprintf(path, sizeof(path), "%s/%s", CARD_MOUNTPOINT, file);
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(menu->form == MENU_FORM_FSEL && menu->entry == 1, "%s: selector opens on entry %d", what, menu->entry);
  menu_do(menu, MENU_EVENT_DOWN);
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(az_sets == n+1 && az_set_unit_last == unit && open_n == o, "%s: az_set_unit %d times, on unit %d; sd_card.v opened %d",
        what, az_sets - n, az_set_unit_last, open_n - o);
  CHECK(az_units[unit] && !strcmp(az_units[unit], path), "%s: unit %d holds '%s', expected '%s'",
        what, unit, az_units[unit] ? az_units[unit] : "(null)", path);
  CHECK(image_name[unit] && !strcmp(image_name[unit], file), "%s: slot %d remembers '%s', expected '%s'",
        what, unit, image_name[unit] ? image_name[unit] : "(null)", file);
  CHECK(!osd_visible && menu->form == form && menu->entry == entry, "%s: after mounting: osd %d form %d entry %d", what, osd_visible, menu->form, menu->entry);
  menu_do(menu, MENU_EVENT_SHOW);
  menu_do(menu, MENU_EVENT_SELECT);       // reopened, it highlights the mounted file
  CHECK(menu->form == MENU_FORM_FSEL && menu->entry == 2, "%s: selector reopens on entry %d, expected the file", what, menu->entry);
  menu_do(menu, MENU_EVENT_UP);           // No Disk
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(az_sets == n+2 && az_set_unit_last == unit && !az_units[unit] && !image_name[unit], "%s: No Disk did not eject unit %d", what, unit);
  CHECK(menu->form == form && menu->entry == entry, "%s: after ejecting: form %d entry %d", what, menu->form, menu->entry);
}

int main(int argc, char **argv) {
  if(argc > 1) outdir = argv[1];

  u8g2_SetupBitmap(&u8g2, &u8g2_cb_r0, 128, 64);
  u8x8_InitDisplay(u8g2_GetU8x8(&u8g2));

  menu_t *menu = menu_init(&u8g2);
  menu_do(menu, MENU_EVENT_SHOW);
  shot("main");

  //---- the main form: four units, Reset, Hardware, About, Debug, Save settings
  CHECK(menu->form == 0 && menu->entry == 1, "start: form %d entry %d", menu->form, menu->entry);
  CHECK(strstr(menu->forms[0], "BK Nano,;") == menu->forms[0], "main form title: %s", menu->forms[0]);
  CHECK(strstr(menu->forms[0], "F,AZ0:,0|img+bkd+dsk;") && strstr(menu->forms[0], "F,AZ1:,1|img+bkd+dsk;") &&
        strstr(menu->forms[0], "F,AZ2:,2|img+bkd+dsk;") && strstr(menu->forms[0], "F,AZ3:,3|img+bkd+dsk;") &&
        strstr(menu->forms[0], "B,Reset,R;") && !strstr(menu->forms[0], "Cold reset") &&
        strstr(menu->forms[0], "S,Hardware,1;") &&
        strstr(menu->forms[0], "T,About,;") && strstr(menu->forms[0], "T,Debug,;") &&
        strstr(menu->forms[0], "B,Save settings,S;"),
        "main form entries: %s", menu->forms[0]);
  CHECK(menu->entries == 10, "main form has %d entries, expected 10", menu->entries);
  CHECK(strstr(menu->forms[1], "Hardware,0|7;") == menu->forms[1], "Hardware title: %s", menu->forms[1]);
  CHECK(strstr(menu->forms[1], "L,CPU:,4 MHz|8 MHz,T;") && strstr(menu->forms[1], "L,Joystick:,Off|On,j;") &&
        strstr(menu->forms[1], "L,Volume:,Mute|33%|66%|100%,A;"),
        "Hardware entries: %s", menu->forms[1]);
  CHECK(az_boots == 1, "az_boot called %d times at start", az_boots);
  CHECK(az_sets == 0, "az_set_unit called %d times at start with no saved images", az_sets);
  CHECK(open_n == 0, "sd_card.v's slots opened %d times at start", open_n);

  //---- the defaults went to the core, every letter once and in order, then the reset
  {
    static const char init_log[][2] = { {'A',1}, {'T',0}, {'j',1}, {'R',3}, {'R',0} };
    int init_n = sizeof(init_log)/sizeof(init_log[0]);
    CHECK(set_n == init_n, "%d values sent at start, expected %d", set_n, init_n);
    for(int i=0;i<init_n && i<set_n;i++)
      CHECK(set_log[i][0] == init_log[i][0] && set_log[i][1] == init_log[i][1],
            "start send %d is %c=%d, expected %c=%d", i, set_log[i][0], set_log[i][1], init_log[i][0], init_log[i][1]);
  }

  //---- the four units
  for(int d=0;d<4;d++) {
    char what[8];
    snprintf(what, sizeof(what), "AZ%d", d);
    CHECK(menu->entry == 1+d, "%s entry %d", what, menu->entry);
    selector(menu, what, 0, 1+d, d, "img+bkd+dsk");
    if(d == 0) { mount_and_eject(menu, what, 0, 1, 0, "GAME.img"); shot("main-mounted"); }
    menu_do(menu, MENU_EVENT_DOWN);
  }

  //---- Reset is a button: a pulse to the core (every reset is the AZ's cold one too), the OSD closes
  int n = set_n, r = set_count('R');
  CHECK(menu->entry == 5, "Reset entry %d", menu->entry);
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(set_count('R') == r+2 && set_n == n+2 && !osd_visible, "Reset sent %d values (R %d times), osd %d", set_n - n, set_count('R') - r, osd_visible);
  menu_do(menu, MENU_EVENT_SHOW);
  CHECK(menu->form == 0 && menu->entry == 5, "after Reset: form %d entry %d", menu->form, menu->entry);

  //---- Hardware: form 1, entered on its first entry
  menu_do(menu, MENU_EVENT_DOWN);
  CHECK(menu->entry == 6, "Hardware entry %d", menu->entry);
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(menu->form == 1 && menu->entry == 1 && menu->offset == 0, "Hardware: form %d entry %d", menu->form, menu->entry);
  CHECK(menu->entries == 4, "Hardware has %d entries, expected 4", menu->entries);
  shot("hardware");

  //---- CPU: 4/8 MHz
  toggle(menu, "CPU", 'T', 0);
  shot("hardware-cpu");

  //---- Joystick
  menu_do(menu, MENU_EVENT_DOWN);
  CHECK(menu->entry == 2, "Joystick entry %d", menu->entry);
  toggle(menu, "Joystick", 'j', 1);

  //---- Volume: right, left, both wrap, Space steps on
  menu_do(menu, MENU_EVENT_DOWN);
  CHECK(menu->entry == 3, "Volume entry %d", menu->entry);
  CHECK_VISIBLE(menu);
  n = set_n;
  CHECK(stepped(menu, 'A', +1, 2) && set_n == n+1, "right on Volume: A=%d", set_last('A'));
  CHECK(stepped(menu, 'A', -1, 1), "left on Volume: A=%d", set_last('A'));
  CHECK(stepped(menu, 'A', -1, 0), "left to Mute: A=%d", set_last('A'));
  CHECK(stepped(menu, 'A', -1, 3), "left wraps to 100%%: A=%d", set_last('A'));
  CHECK(stepped(menu, 'A', +1, 0), "right wraps to Mute: A=%d", set_last('A'));
  CHECK(stepped(menu, 'A', +1, 1), "right to 33%%: A=%d", set_last('A'));
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(set_last('A') == 2, "space on Volume: A=%d", set_last('A'));
  shot("hardware-volume-66");
  CHECK(stepped(menu, 'A', -1, 1), "back to 33%%: A=%d", set_last('A'));
  CHECK(set_n == n+8, "Volume: %d sends for eight steps", set_n - n);

  // every list letter: its default at start, then the steps above
  for(const char *l = "ATj"; *l; l++)
    CHECK(set_last(*l) == (*l == 'A' || *l == 'j'), "letter %c ends at %d, not its default", *l, set_last(*l));

  //---- wrapping in Hardware
  menu_do(menu, MENU_EVENT_DOWN);
  CHECK(menu->entry == 0 && menu->offset == 0, "DOWN past the last: entry %d offset %d, expected the title", menu->entry, menu->offset);
  menu_do(menu, MENU_EVENT_UP);
  CHECK(menu->entry == 3, "UP from the title: entry %d, expected 3", menu->entry);
  CHECK_VISIBLE(menu);
  menu_do(menu, MENU_EVENT_PGUP);
  CHECK(menu->entry == 1 && menu->offset == 0, "PGUP to the top: entry %d offset %d", menu->entry, menu->offset);
  menu_do(menu, MENU_EVENT_PGDOWN);
  CHECK(menu->entry == 3, "PGDOWN to the end: entry %d", menu->entry);

  //---- ESC closes the OSD; F12 opens it again on the same form
  menu_do(menu, MENU_EVENT_HIDE);
  CHECK(!osd_visible, "ESC left the OSD visible");
  menu_do(menu, MENU_EVENT_SHOW);
  CHECK(osd_visible && menu->form == 1 && menu->entry == 3, "after ESC and F12: form %d entry %d", menu->form, menu->entry);

  //---- the title returns to the entry that opened the form
  menu_do(menu, MENU_EVENT_DOWN);
  CHECK(menu->entry == 0, "Hardware title: entry %d", menu->entry);
  shot("hardware-title");
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(menu->form == 0 && menu->entry == 6, "back from Hardware: form %d entry %d, expected 0/6", menu->form, menu->entry);
  CHECK_VISIBLE(menu);
  shot("main-back");

  //---- About: a text page that scrolls and returns
  menu_do(menu, MENU_EVENT_DOWN);
  CHECK(menu->entry == 7, "About entry %d", menu->entry);
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(menu->form == MENU_FORM_TEXT && menu->offset == 0, "About: form %d offset %d", menu->form, menu->offset);
  CHECK(menu_text_line(0) && !strncmp(menu_text_line(0), "BK Nano", 7), "About shows '%s'", menu_text_line(0));
  shot("about-0");
  menu_do(menu, MENU_EVENT_DOWN);
  CHECK(menu->offset == 1, "About scrolled to %d", menu->offset);
  menu_do(menu, MENU_EVENT_PGDOWN);
  CHECK(menu->offset == 5, "About paged to %d, expected 5", menu->offset);
  shot("about-5");
  for(int i=0;i<60;i++) menu_do(menu, MENU_EVENT_DOWN);
  int last = menu->offset;
  CHECK(last > 5 && last < 44, "About scrolled to the end at %d", last);
  shot("about-end");
  menu_do(menu, MENU_EVENT_DOWN);
  CHECK(menu->offset == last, "About scrolls past its end");
  menu_do(menu, MENU_EVENT_UP);
  CHECK(menu->offset == last-1, "About does not scroll back");
  for(int i=0;i<12;i++) menu_do(menu, MENU_EVENT_PGUP);
  CHECK(menu->offset == 0, "About does not page back to the top (%d)", menu->offset);
  n = set_n;
  menu_do(menu, MENU_EVENT_LEFT); menu_do(menu, MENU_EVENT_RIGHT);
  CHECK(set_n == n && menu->form == MENU_FORM_TEXT, "left/right on About did something");
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(menu->form == 0 && menu->entry == 7, "back from About: form %d entry %d", menu->form, menu->entry);

  //---- Debug: a text page of the core's bytes (all zero here: sys_get_debug is stubbed)
  menu_do(menu, MENU_EVENT_DOWN);
  CHECK(menu->entry == 8, "Debug entry %d", menu->entry);
  n = set_n;
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(menu->form == MENU_FORM_TEXT && menu->offset == 0 && set_n == n, "Debug: form %d offset %d", menu->form, menu->offset);
  CHECK(menu_text_line(0) && !strncmp(menu_text_line(0), "init ", 5), "Debug shows '%s'", menu_text_line(0));
  shot("debug");
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(menu->form == 0 && menu->entry == 8, "back from Debug: form %d entry %d", menu->form, menu->entry);

  //---- Save settings is a button on the main form: it writes the card (fails here, no card)
  menu_do(menu, MENU_EVENT_DOWN);
  CHECK(menu->entry == 9 && menu->offset == 5, "Save settings entry %d offset %d", menu->entry, menu->offset);
  n = set_n;
  menu_do(menu, MENU_EVENT_SELECT);
  CHECK(menu->form == 0 && menu->entry == 9 && set_n == n && osd_visible, "Save settings left the main form or sent something");
  shot("main-end");
  menu_do(menu, MENU_EVENT_DOWN);    // the main form's title is not selectable: straight to AZ0
  CHECK(menu->entry == 1 && menu->offset == 0, "DOWN past Save settings: entry %d offset %d, expected AZ0", menu->entry, menu->offset);
  menu_do(menu, MENU_EVENT_UP);
  CHECK(menu->entry == 9 && menu->offset == 5, "UP from AZ0: entry %d offset %d, expected Save settings", menu->entry, menu->offset);
  menu_do(menu, MENU_EVENT_HIDE);

  printf("menu-test: %d screens in %s, %d error(s)\n", shots, outdir, errors);
  return errors ? 1 : 0;
}

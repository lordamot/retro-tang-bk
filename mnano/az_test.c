/*
  az_test.c - the controller's boot on the host (make az-test).

  azbk.c's az_boot() is what puts the ROM set into the machine: it reads
  /bk/AZ.INI off the card through FatFs and sends every ROM over SYS
  command 6.  Nothing in the FPGA simulation runs that code, so this
  does: FatFs is built with an in-memory disk, a FAT32 volume is made on
  it and filled from soft/azbk/ (its DISKS/dave.img also as DAVE.IMG there and at the root)
  exactly as the card is laid out, then az_boot() runs against it with
  sys_poke24() writing into a model of the SDRAM.  The checks: every ROM
  file's bytes are at 0x40000 + slot * 4096, the logo at 0x20000, the
  units are the AZ.INI's, and the poke stream is what the FPGA expects
  (three address bytes, contiguous, 512 a transaction).
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <glob.h>
#include <sys/stat.h>
#include "ff.h"
#include "diskio.h"
#include "sysctrl.h"
#include "sdc.h"
#include "azbk.h"

unsigned char core_id = CORE_ID_BK;

//------------------------------------------------------------------------
// the disk: 64 MB in memory, volume 2 ("sd")
//------------------------------------------------------------------------
#define DISK_SECTORS (64 * 2048)
static unsigned char *disk;

DSTATUS disk_initialize(BYTE p) { return p == 2 ? 0 : STA_NOINIT; }
DSTATUS disk_status(BYTE p) { return p == 2 ? 0 : STA_NOINIT; }
DRESULT disk_read(BYTE p, BYTE *b, LBA_t s, UINT c) {
  if(p != 2 || s + c > DISK_SECTORS) return RES_PARERR;
  memcpy(b, disk + s * 512, c * 512); return RES_OK;
}
DRESULT disk_write(BYTE p, const BYTE *b, LBA_t s, UINT c) {
  if(p != 2 || s + c > DISK_SECTORS) return RES_PARERR;
  memcpy(disk + s * 512, b, c * 512); return RES_OK;
}
DRESULT disk_ioctl(BYTE p, BYTE c, void *b) {
  if(p != 2) return RES_PARERR;
  switch(c) {
  case CTRL_SYNC: return RES_OK;
  case GET_SECTOR_COUNT: *(LBA_t *)b = DISK_SECTORS; return RES_OK;
  case GET_SECTOR_SIZE: *(WORD *)b = 512; return RES_OK;
  case GET_BLOCK_SIZE: *(DWORD *)b = 1; return RES_OK;
  }
  return RES_PARERR;
}
DWORD get_fattime(void) { return 0; }

//------------------------------------------------------------------------
// the firmware's surroundings
//------------------------------------------------------------------------
void sdc_lock(void) {}
void sdc_unlock(void) {}
int  sdc_timeouts(void) { return 0; }
void vTaskDelay(int ms) { (void)ms; }

// the SPI: every transaction's bytes are kept, and SYS command 6 lands
// in the SDRAM model
#define MEM_SIZE (8 * 1024 * 1024)
static unsigned char *mem;
static unsigned char *touched;
static unsigned char tx[600];
static int txn, transactions, pokes, bad_txn;
static unsigned long poke_bytes;
static int size_pushes; static unsigned long size_unit0;   // the size table into the AZ target (azbk.c's az_push_sizes)

void spi_begin(spi_t *spi) { (void)spi; txn = 0; }
unsigned char spi_tx_u08(spi_t *spi, unsigned char b) { (void)spi; if(txn < (int)sizeof(tx)) tx[txn] = b; txn++; return 0; }
void spi_end(spi_t *spi) {
  (void)spi;
  transactions++;
  if(txn >= 5 && tx[0] == 0 && tx[1] == 6) {
    unsigned long a = ((unsigned long)tx[2] << 16) | (tx[3] << 8) | tx[4];
    if(txn - 5 > 512) bad_txn++;
    for(int i = 5; i < txn && i < (int)sizeof(tx); i++, a++) {
      if(a < MEM_SIZE) { mem[a] = tx[i]; touched[a] = 1; }
      poke_bytes++;
    }
    pokes++;
  }
  if(txn >= 4 && tx[0] == 4 && tx[1] == 3 && ((tx[2] << 8) | tx[3]) == AZ_R_USIZE) {
    size_pushes++;
    size_unit0 = tx[4] | (tx[5] << 8) | ((unsigned long)tx[6] << 16) | ((unsigned long)tx[7] << 24);
  }
}
// sysctrl.c's sys_peek24, against the model: the word holding the address
static int peeks;
int sys_peek24(spi_t *spi, unsigned long addr, unsigned char *word) {
  (void)spi;
  peeks++;
  unsigned long a = addr & ~3UL;
  if(a + 4 > MEM_SIZE) return -1;
  for(int i = 0; i < 4; i++) word[i] = mem[a + i];
  return 0;
}
// sysctrl.c's sys_poke24, verbatim (that file needs the whole firmware)
static void sys_begin(spi_t *spi, unsigned char cmd) { spi_begin(spi); spi_tx_u08(spi, 0); spi_tx_u08(spi, cmd); }
void sys_poke24(spi_t *spi, unsigned long addr, const unsigned char *buf, int len) {
  sys_begin(spi, SPI_SYS_POKE);
  spi_tx_u08(spi, (addr >> 16) & 0xff);
  spi_tx_u08(spi, (addr >> 8) & 0xff);
  spi_tx_u08(spi, addr & 0xff);
  for(int i=0;i<len;i++) spi_tx_u08(spi, buf[i]);
  spi_end(spi);
}

//------------------------------------------------------------------------
// the card's content, from the host's files
//------------------------------------------------------------------------
static int errors;
#define CHECK(cond, ...) do { if(!(cond)) { errors++; printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while(0)

static void put_file(const char *host, const char *card) {
  FILE *f = fopen(host, "rb");
  if(!f) { printf("cannot read %s\n", host); errors++; return; }
  FIL fil;
  FRESULT r = f_open(&fil, card, FA_CREATE_ALWAYS | FA_WRITE);
  CHECK(r == FR_OK, "f_open(%s) for writing: %d", card, r);
  if(r == FR_OK) {
    static unsigned char buf[4096];
    size_t n;
    while((n = fread(buf, 1, sizeof(buf), f)) > 0) {
      UINT w = 0;
      r = f_write(&fil, buf, (UINT)n, &w);
      CHECK(r == FR_OK && w == n, "f_write(%s): %d", card, r);
    }
    f_close(&fil);
  }
  fclose(f);
}

// a host folder's files into a card folder (one level; the card has no deeper ones)
static void put_dir(const char *host, const char *card) {
  FRESULT mr = f_mkdir(card);
  CHECK(mr == FR_OK || mr == FR_EXIST, "f_mkdir(%s): %d", card, mr);
  char pat[512];
  snprintf(pat, sizeof(pat), "%s/*", host);
  glob_t g;
  if(glob(pat, 0, NULL, &g) != 0) { printf("cannot list %s\n", host); errors++; return; }
  for(size_t i = 0; i < g.gl_pathc; i++) {
    const char *name = strrchr(g.gl_pathv[i], '/') + 1;
    char c[512];
    snprintf(c, sizeof(c), "%s/%s", card, name);
    struct stat st;
    if(stat(g.gl_pathv[i], &st) != 0 || S_ISDIR(st.st_mode)) continue;   // a folder: the caller's
    put_file(g.gl_pathv[i], c);
  }
  globfree(&g);
}

// the ROM as the host has it against the SDRAM model
static void check_rom(const char *host, unsigned long addr) {
  FILE *f = fopen(host, "rb");
  if(!f) { printf("cannot read %s\n", host); errors++; return; }
  static unsigned char buf[65536];
  size_t n = fread(buf, 1, sizeof(buf), f);
  fclose(f);
  int wrong = 0;
  for(size_t i = 0; i < n; i++) if(mem[addr + i] != buf[i] || !touched[addr + i]) wrong++;
  CHECK(wrong == 0, "%s at %06lx: %d of %zu bytes wrong or never sent", host, addr, wrong, n);
  printf("  %-28s %6zu bytes at %06lx %s\n", host + 14, n, addr, wrong ? "WRONG" : "ok");
}

int main(void) {
  disk = calloc(DISK_SECTORS, 512);
  mem = calloc(MEM_SIZE, 1);
  touched = calloc(MEM_SIZE, 1);

  // the volume
  static FATFS fs;
  static BYTE work[4096];
  MKFS_PARM opt = { FM_FAT32, 1, 0, 0, 0 };
  FRESULT r = f_mkfs("/sd", &opt, work, sizeof(work));
  CHECK(r == FR_OK, "f_mkfs: %d", r);
  r = f_mount(&fs, "/sd", 1);
  CHECK(r == FR_OK, "f_mount: %d", r);

  // the card: soft/azbk as /bk, plus Dave
  put_dir("soft/azbk", "/sd/bk");
  put_dir("soft/azbk/ROM", "/sd/bk/ROM");
  put_dir("soft/azbk/DISKS", "/sd/bk/DISKS");
  put_file("soft/azbk/DISKS/dave.img", "/sd/bk/DISKS/DAVE.IMG");
  put_file("soft/azbk/DISKS/dave.img", "/sd/DAVE.IMG");          // ...and at the card's root, where the OSD may pick it

  // what the firmware does at start
  spi_t spi;
  memset(&spi, 0, sizeof(spi));
  az_boot(&spi);

  printf("az_boot: %d transactions, %d pokes of %lu bytes, %d oversize, %d peeks\n", transactions, pokes, poke_bytes, bad_txn, peeks);
  CHECK(bad_txn == 0, "%d poke transactions longer than 512 bytes", bad_txn);
  CHECK(pokes > 0, "no ROM bytes were sent at all");
  for(int i = 0; az_boot_line(i); i++) printf("  debug: %s\n", az_boot_line(i));
  CHECK(az_boot_line(0) && strstr(az_boot_line(0), "ini ok, 20 files") && strstr(az_boot_line(0), "0 missing"), "the boot's first Debug line is '%s'", az_boot_line(0) ? az_boot_line(0) : "(none)");
  CHECK(az_boot_line(1) && strstr(az_boot_line(1), " 0 bad, 0 unanswered") && peeks > 1000, "the verify's Debug line is '%s' (%d peeks)", az_boot_line(1) ? az_boot_line(1) : "(none)", peeks);
  CHECK(az_boot_line(6) == NULL, "a bad-word Debug line although nothing was wrong");
  CHECK(size_pushes > 0 && size_unit0 == 1600, "the unit sizes went to the FPGA %d times, unit 0 as %lu blocks (expect 1600)", size_pushes, size_unit0);

  // the ROM set at its slots (AZ.INI's R lines), the logo at page 40
  static const struct { const char *file; int slot; } roms[] = {
    { "azboot.ROM", 0 }, { "AZLIB00.ROM", 1 }, { "AZLIB01.ROM", 2 }, { "AZLIB02.ROM", 3 }, { "AZLIB03.ROM", 4 },
    { "AZ337.ROM", 8 }, { "11M_324.ROM", 16 }, { "11M_325.ROM", 18 }, { "11M_327.ROM", 20 }, { "11M_328.ROM", 22 },
    { "11M_329.ROM", 24 }, { "11M_330.ROM", 26 }, { "10_017.ROM", 28 }, { "10_018.ROM", 30 }, { "10_019.ROM", 32 },
    { "10_106.ROM", 34 }, { "10_107.ROM", 36 }, { "10_108.ROM", 38 }, { "SETUP.ROM", 56 } };
  for(unsigned i = 0; i < sizeof(roms) / sizeof(roms[0]); i++) {
    char h[256];
    snprintf(h, sizeof(h), "soft/azbk/ROM/%s", roms[i].file);
    check_rom(h, 0x40000UL + roms[i].slot * 4096UL);
  }
  check_rom("soft/azbk/ROM/AZLOGO.RAW", 0x20000UL);

  // the units
  for(int u = 0; u < 4; u++) printf("  unit %d: %s\n", u, az_unit_path(u) ? az_unit_path(u) : "-");
  CHECK(az_unit_path(0) && strstr(az_unit_path(0), "WRKANDOS2"), "unit 0 is not AZ.INI's D0");
  CHECK(az_set_unit(0, "/sd/bk/DISKS/DAVE.IMG") == 0 && az_unit_blocks(0) > 0, "the OSD cannot mount /sd/bk/DISKS/DAVE.IMG as unit 0 (%lu blocks)", az_unit_blocks(0));
  CHECK(az_set_unit(1, "/sd/DAVE.IMG") == 0 && az_unit_blocks(1) > 0, "the OSD cannot mount /sd/DAVE.IMG (the card's root) as unit 1 (%lu blocks)", az_unit_blocks(1));
  CHECK(az_set_unit(2, "0:/DISKS/DAVE.IMG") == 0 && az_unit_blocks(2) > 0, "AZ.INI's form 0:/DISKS/DAVE.IMG does not mount (%lu blocks)", az_unit_blocks(2));

  printf("az-test: %d error(s)\n", errors);
  return errors ? 1 : 0;
}

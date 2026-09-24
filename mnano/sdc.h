#ifndef SDC_H
#define SDC_H

#include "spi.h"

// up to four image files can be open. E.g. two
// floppy disks and two ACSI hard drives
#define MAX_DRIVES  5   // sd_card.v's image slots: four floppies and the SMUC's disk
// one more, browsed but never mounted: the ROM image, which romload.c
// sends into the core itself
#define SDC_SLOT_EXTRA  MAX_DRIVES
#define SDC_SLOT_ROM    SDC_SLOT_EXTRA

// fatfs mounts the card under /sd
#define CARD_MOUNTPOINT "/sd"
int sdc_timeouts(void);   // BK Nano: card waits that gave up (sdc_read_sector)

typedef struct {
  char *name;
  unsigned long len;
  int is_dir;
} sdc_dir_entry_t;

typedef struct {
  int len;
  sdc_dir_entry_t *files;
} sdc_dir_t;

int sdc_init(spi_t *spi);
int sdc_image_open(int drive, char *name);
sdc_dir_t *sdc_readdir(int drive, char *name, const char *exts);
int sdc_handle_event(void);
int sdc_is_ready(void);
void sdc_lock(void);
void sdc_unlock(void);
char *sdc_get_image_name(int drive);
char *sdc_get_cwd(int drive);
void sdc_set_default(int drive, const char *name);
void sdc_set_image_name(int drive, const char *name);

#endif // SDC_H

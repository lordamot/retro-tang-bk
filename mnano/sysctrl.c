/*
  sysctrl.c

  MiSTeryNano system control interface
*/

#include "sysctrl.h"
#include "bflb_wdg.h"
#include "sdc.h"
#include "azbk.h"

unsigned char core_id = 0;

static const char *core_names[] = {
  "<unset>", "Atari ST", "C64", "UNEON", "AMIGA", "UKNC", "AGAT9", "PK8000", "Korvet", "ZS-256", "BK Nano"
};

static void sys_begin(spi_t *spi, unsigned char cmd) {
  spi_begin(spi);  
  spi_tx_u08(spi, SPI_TARGET_SYS);
  spi_tx_u08(spi, cmd);
}  

int sys_status_is_valid(spi_t *spi) {
  sys_begin(spi, SPI_SYS_STATUS);
  spi_tx_u08(spi, 0);
  unsigned char b0 = spi_tx_u08(spi, 0);
  unsigned char b1 = spi_tx_u08(spi, 0);
  core_id = spi_tx_u08(spi, 0);
  unsigned char coldboot = spi_tx_u08(spi, 0);
  spi_end(spi);  

  if((b0 == 0x5c) && (b1 == 0x42)) {
    printf("Core ID: %02x\r\n", core_id);
    if(core_id < 11) printf("Core: %s\r\n", core_names[core_id]);

    // coldboot status equals core_id on cores not supporting cold
    // boot status
    if(coldboot != core_id) {
      // check colboot status
      printf("Coldboot status is %02x\r\n", coldboot);

    }
  }
  
  return((b0 == 0x5c) && (b1 == 0x42));
}

void sys_set_leds(spi_t *spi, char leds) {
  sys_begin(spi, SPI_SYS_LEDS);
  spi_tx_u08(spi, leds);
  spi_end(spi);  
}

void sys_set_rgb(spi_t *spi, unsigned long rgb) {
  sys_begin(spi, SPI_SYS_RGB);
  spi_tx_u08(spi, (rgb >> 16) & 0xff); // R
  spi_tx_u08(spi, (rgb >> 8) & 0xff);  // G
  spi_tx_u08(spi, rgb & 0xff);         // B
  spi_end(spi);    
}

unsigned char sys_get_buttons(spi_t *spi) {
  unsigned char btns = 0;
  
  sys_begin(spi, SPI_SYS_BUTTONS);
  spi_tx_u08(spi, 0x00);
  btns = spi_tx_u08(spi, 0);
  spi_end(spi);

  return btns;
}

void sys_set_val(spi_t *spi, char id, uint8_t value) {
  printf("SYS set value %c = %d\r\n", id, value);
  
  sys_begin(spi, SPI_SYS_SETVAL);   // send value command
  spi_tx_u08(spi, id);              // value id
  spi_tx_u08(spi, value);           // value itself
  spi_end(spi);  
}

// bytes into the SDRAM (poke.v through sysctrl.v's CMD 6): three address bytes, high first, then the bytes,
// the address stepping.  The ROM image goes in this way at start
// (romload.c); the core's own processor is held in reset meanwhile.
void sys_poke24(spi_t *spi, unsigned long addr, const unsigned char *buf, int len) {
  sys_begin(spi, SPI_SYS_POKE);
  spi_tx_u08(spi, (addr >> 16) & 0xff);
  spi_tx_u08(spi, (addr >> 8) & 0xff);
  spi_tx_u08(spi, addr & 0xff);
  for(int i=0;i<len;i++) spi_tx_u08(spi, buf[i]);
  spi_end(spi);
}

// BK Nano: a word back out of the SDRAM (poke.v through sysctrl.v's
// CMD 8): three address bytes, high first; then the core needs a few
// microseconds (its read is the arbiter's last port, behind the
// display's bursts), a byte during which it sets its ready flag, the
// ready byte, and the four bytes of the 32-bit word holding the address,
// low byte first - every answer is one byte behind the byte that set it.
// Not ready: once more with a longer pause, three times in all.
int sys_peek24(spi_t *spi, unsigned long addr, unsigned char *word) {
  for(int attempt = 0; attempt < 3; attempt++) {
    sys_begin(spi, SPI_SYS_PEEK);
    spi_tx_u08(spi, (addr >> 16) & 0xff);
    spi_tx_u08(spi, (addr >> 8) & 0xff);
    spi_tx_u08(spi, addr & 0xff);
    bflb_mtimer_delay_us(5 << attempt);
    spi_tx_u08(spi, 0);                          // the ready flag is set at the end of this byte
    unsigned char ready = spi_tx_u08(spi, 0);
    for(int i=0;i<4;i++) word[i] = spi_tx_u08(spi, 0);
    spi_end(spi);
    if(ready & 1) return 0;
  }
  return -1;
}

// PK8000: the debug window (memcheck.v through sysctrl.v's CMD 7),
// eight bytes a transaction - the core answers one strobe behind, so
// the byte after the offset is already the first of them
void sys_get_debug(spi_t *spi, unsigned char *buf, int len) {
  for(int off=0;off<len;off+=8) {
    sys_begin(spi, SPI_SYS_DEBUG);
    spi_tx_u08(spi, off);
    for(int i=0;i<8 && off+i<len;i++) buf[off+i] = spi_tx_u08(spi, 0);
    spi_end(spi);
  }
}

unsigned char sys_irq_ctrl(spi_t *spi, unsigned char ack) {
  sys_begin(spi, SPI_SYS_IRQ_CTRL);
  spi_tx_u08(spi, ack);
  unsigned char ret = spi_tx_u08(spi, 0);
  spi_end(spi);  
  return ret;
}

static void sys_handle_event(void) {
  // the FPGAs cold boot flag was set indicating that the
  // FPGA has be reloaded while the MCU was running. Reset
  // the MCU to re-initialize everything and get into a
  // sane state
  
  printf("FPGA cold boot detected, resetting MCU ...\r\n");
  
  struct bflb_wdg_config_s wdg_cfg;
  wdg_cfg.clock_source = WDG_CLKSRC_32K;
  wdg_cfg.clock_div = 31;
  wdg_cfg.comp_val = 500;
  wdg_cfg.mode = WDG_MODE_RESET;
  
  struct bflb_device_s *wdg = bflb_device_get_by_name("watchdog");
  bflb_wdg_init(wdg, &wdg_cfg);

  // the watchdog should trigger and reset the device
  bflb_wdg_start(wdg);
}

void sys_handle_interrupts(unsigned char pending) {
  if(pending & 0x01) // irq 0 = SYSCTRL
    sys_handle_event();
    
  if(pending & 0x02) // irq 1 = HID
    hid_handle_event();
  
  if(pending & 0x08) // irq 3 = SDC
    sdc_handle_event();

  if(pending & 0x10) // irq 4 = the AZ controller (azctrl.v)
    az_handle_event();

}


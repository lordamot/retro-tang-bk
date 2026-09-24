/*
  sysctrl.h

  MiSTeryNano system control interface
*/

#ifndef SYS_CTRL_H
#define SYS_CTRL_H

#include "spi.h"

// the MCU can adopt to the core running to e.g.
// change the menu and the keyboard mapping
#define CORE_ID_UNKNOWN  0x00
#define CORE_ID_ATARI_ST 0x01
#define CORE_ID_C64      0x02
#define CORE_ID_UNEON    0x03
#define CORE_ID_AMIGA    0x04
#define CORE_ID_UKNC     0x05
#define CORE_ID_AGAT9    0x06
#define CORE_ID_PK8000   0x07
#define CORE_ID_KORVET   0x08
#define CORE_ID_ZS256    0x09
#define CORE_ID_BK       0x0A   // BK Nano: the БК-0011М with an AZBK (this repository)
#define CORE_ID_VIC20    0x10

extern unsigned char core_id;

int  sys_status_is_valid(spi_t *);
void sys_set_leds(spi_t *, char);
void sys_set_rgb(spi_t *, unsigned long);
unsigned char sys_get_buttons(spi_t *);
void sys_set_val(spi_t *, char, uint8_t);
void sys_get_debug(spi_t *, unsigned char *, int);
// ZS-256: bytes into the SDRAM at a 24-bit byte address (sysctrl.v's CMD 6)
void sys_poke24(spi_t *, unsigned long addr, const unsigned char *buf, int len);
// BK Nano: the 32-bit word holding a 24-bit byte address back out of the
// SDRAM (sysctrl.v's CMD 8), low byte first; -1 if the core never answered
int  sys_peek24(spi_t *, unsigned long addr, unsigned char *word);
unsigned char sys_irq_ctrl(spi_t *, unsigned char);
void sys_handle_interrupts(unsigned char);

#endif // SYS_CTRL_H

`timescale 1ns / 1ps
//========================================================================
// sys_pll.v - the system clock: 27 MHz in, 64.8 MHz out.
//
// Everything in this design runs on the one 64.8 MHz clock: the HDMI
// pixel is one (1024x768 at 59.8 Hz, 1344 x 806 of them a frame), the
// К1801ВМ1's clock is sixteen (4.05 MHz), the AY's 1.7 MHz an enable every
// 38, the SDRAM takes the phase-shifted copy on its own pad.  64.8 is
// 27 x 12 / 5: IDIV 5 puts the phase detector at 5.4 MHz, FBDIV 12
// multiplies it back up, ODIV 8 puts the VCO at 518.4 MHz, inside its
// 400-1200.  The serial clock for HDMI is five times this, made from it
// in hdmi_serdes.v.  ZS-256 Nano's file with the ratios changed.
//
// A hand-written instantiation of the rPLL primitive, like
// hdmi_serdes.v; stubbed in simulation by sim/stubs/gowin_ip_sim.v,
// which quotes these ratios.
//========================================================================
module sys_pll (
    input        clkin,     // 27 MHz, pin 4
    input  [3:0] psda,      // clkoutp's phase behind clkout, in sixteenths of a period (sdram.v tunes it)
    output       clkout,    // 64.8 MHz
    output       clkoutp,   // 64.8 MHz, psda/16 of a period later, for the SDRAM pad
    output       lock
);

rPLL rpll_inst (
    .CLKOUT  (clkout ),
    .LOCK    (lock   ),
    .CLKOUTP (clkoutp),
    .CLKOUTD (       ),
    .CLKOUTD3(       ),
    .RESET   (1'b0   ),
    .RESET_P (1'b0   ),
    .CLKIN   (clkin  ),
    .CLKFB   (1'b0   ),
    .FBDSEL  (6'b000000),
    .IDSEL   (6'b000000),
    .ODSEL   (6'b000000),
    .PSDA    (psda   ),
    .DUTYDA  (4'b1000),   // 50% with the dynamic adjust on
    .FDLY    (4'b1111)
);

defparam rpll_inst.FCLKIN           = "27";
defparam rpll_inst.DEVICE           = "GW2AR-18C";
defparam rpll_inst.DYN_IDIV_SEL     = "false";
defparam rpll_inst.IDIV_SEL         = 4;        // divide by 5: 5.4 MHz at the phase detector
defparam rpll_inst.DYN_FBDIV_SEL    = "false";
defparam rpll_inst.FBDIV_SEL        = 11;       // multiply by 12
defparam rpll_inst.DYN_ODIV_SEL     = "false";
defparam rpll_inst.ODIV_SEL         = 8;        // VCO 518.4 MHz
defparam rpll_inst.PSDA_SEL         = "0110";   // unused with DYN_DA_EN; 135 degrees was the static choice
defparam rpll_inst.DYN_DA_EN        = "true";    // the phase from the PSDA pins: sdram.v sweeps it at power-up (19 Sep 2026)
defparam rpll_inst.DUTYDA_SEL       = "1000";
defparam rpll_inst.CLKOUT_FT_DIR    = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR   = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP  = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
defparam rpll_inst.CLKFB_SEL        = "internal";
defparam rpll_inst.CLKOUT_BYPASS    = "false";
defparam rpll_inst.CLKOUTP_BYPASS   = "false";
defparam rpll_inst.CLKOUTD_BYPASS   = "false";
defparam rpll_inst.DYN_SDIV_SEL     = 2;
defparam rpll_inst.CLKOUTD_SRC      = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC     = "CLKOUT";

endmodule

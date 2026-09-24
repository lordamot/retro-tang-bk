//========================================================================
// Behavioural models of what Verilator cannot read, for simulation only.
//========================================================================
// Two modules of the design are nothing but Gowin primitives:
//   src/sys_pll.v            an rPLL
//   src/hdmi/hdmi_serdes.v   an rPLL, four OSER10s, four ELVDS_OBUFs
// tools/srcs.py lists them as STUBBED and the flows take these instead.
// Each matches its counterpart's port list exactly and quotes the
// parameters it stands in for, so a change there can be checked here.
//========================================================================
`timescale 1ns / 1ps

//------------------------------------------------------------------------
// sys_pll - src/sys_pll.v
//   IDIV_SEL 4, FBDIV_SEL 11 => clkout = clkin * 12 / 5 = 64.8 MHz from 27
//   PSDA pins (DYN_DA_EN)    => clkoutp psda/16 of a period behind
// The input period is measured rather than assumed, so a testbench that
// clocks something other than 27 MHz still gets the right ratio.
//------------------------------------------------------------------------
module sys_pll (
    input       clkin,
    input [3:0] psda,
    output      clkout,
    output      clkoutp,
    output reg  lock
);
    parameter IDIV  = 5;
    parameter FBDIV = 12;

    real tin  = 0.0;
    real tout = 0.0;
    time prev = 0;

    reg clkout_r  = 1'b0;
    reg clkoutp_r = 1'b0;
    assign clkout  = clkout_r;
    assign clkoutp = clkoutp_r;

    initial lock = 1'b0;

    always @(posedge clkin) begin
        if (prev != 0 && tin == 0.0) begin
            tin  = $realtime - prev;
            tout = tin * IDIV / FBDIV;
        end
        prev = $realtime;
    end

    initial begin
        wait (tout > 0.0);
        #(tout * 3);
        lock = 1'b1;
    end

    initial begin
        wait (tout > 0.0);
        forever #(tout / 2.0) clkout_r = ~clkout_r;
    end

    // clkoutp: clkout delayed by psda sixteenths of the period, following
    // psda as it changes (a transport delay, so no edge is lost)
    always @(clkout_r) clkoutp_r <= #(tout * psda / 16.0) clkout_r;
endmodule

//------------------------------------------------------------------------
// hdmi_serdes - src/hdmi/hdmi_serdes.v.  The pads are tied off; the
// checking happens one level up, on the ten-bit TMDS words, which
// sim/tb/tb_top.v decodes back into pixels and packets.
//------------------------------------------------------------------------
module hdmi_serdes (
    input        clk_pixel,
    input        ref_locked,
    input  [9:0] tmds_ch0,
    input  [9:0] tmds_ch1,
    input  [9:0] tmds_ch2,
    output       O_tmds_clk_p,
    output       O_tmds_clk_n,
    output [2:0] O_tmds_data_p,
    output [2:0] O_tmds_data_n
);
    assign O_tmds_clk_p  = 1'b0;
    assign O_tmds_clk_n  = 1'b1;
    assign O_tmds_data_p = 3'b000;
    assign O_tmds_data_n = 3'b111;
endmodule

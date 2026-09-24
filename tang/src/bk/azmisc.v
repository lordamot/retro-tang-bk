`timescale 1ns / 1ps
//========================================================================
// azmisc.v - the AZBK's small registers.
//
//   177550  the random number: the low 16 bits of a 128-bit LFSR that
//           steps every clock, so every read is a new word; writes are
//           ignored (MAXIOL: "Генератор псевдослучайных чисел")
//   177370  the FPGA firmware version the software checks against the
//           STM32's: 18, GID's FPGA_version
//   177560-177566  the RS-232 port: nothing is wired to it here, so the
//           receiver never has a byte and the transmitter is always
//           done - a program that prints to it does not hang
//   177130/177132  the disk controller of a real BK-0011M: the AZ takes
//           the mode word (azmap.v) and answers zeros, as GID does
//   177176/177177  OPL2, removed in firmware 19: answers zeros
//========================================================================
module azmisc (
    input             clk,
    input             sync,
    input      [15:0] adr,
    input             stb,
    input             we,
    input      [15:0] din,
    output     [15:0] dout,
    output            ack,
    input             wr_stb
);

reg [127:0] lfsr = 128'h3535_5353_1234_5678_9ABC_DEF0_1357_9BDF;
always @(posedge clk)
    lfsr <= {lfsr[126:0], lfsr[127] ^ lfsr[125] ^ lfsr[100] ^ lfsr[98]};

reg [15:0] tkb = 16'o032346;   // the baud word, 9600

wire sel550 = sync && (adr[15:1] == (16'o177550 >> 1));
wire sel370 = sync && (adr[15:1] == (16'o177370 >> 1));
wire sel56x = sync && (adr[15:3] == (16'o177560 >> 3));       // 177560-177566
wire sel13x = sync && (adr[15:2] == (16'o177130 >> 2));       // 177130, 177132
wire sel176 = sync && (adr[15:1] == (16'o177176 >> 1));

reg [15:0] v;
always @(*) begin
    v = 16'd0;
    if (sel550) v = lfsr[15:0];
    else if (sel370) v = 16'd18;
    else if (sel56x) case (adr[2:1])
        2'd0: v = 16'd0;            // receiver status: nothing waiting
        2'd1: v = 16'd0;            // received data
        2'd2: v = 16'o200;          // transmitter status: done
        default: v = 16'd0;
    endcase
end
assign dout = v;
assign ack  = stb && (sel550 || sel370 || sel56x || sel13x || sel176);

always @(posedge clk)
    if (wr_stb && sel56x && adr[2:1] == 2'd1) tkb <= din;

endmodule

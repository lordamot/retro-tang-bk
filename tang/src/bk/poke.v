`timescale 1ns / 1ps
//========================================================================
// poke.v - the MCU's way into the SDRAM: the ROM images and the logo at
// start, a file read straight into memory (AZ command 047), and a word
// out for the screenshot.
//
// sysctrl.v's CMD 6 carries a 24-bit byte address of the whole chip and
// then any number of bytes; each arrives here as a one-clock strobe,
// is queued sixteen deep and written through sdram.v's port p as it has
// a slot, so the SPI link's pace and the machine's traffic never meet.
// A byte at address a is lane a[1:0] of 32-bit word a[23:2]: that is the
// AZBK's word address a[23:1] with the half a[0], the same layout every
// other port uses.  CMD 8 is the read: a 24-bit byte address, then the
// four bytes of that word come back.  ZS-256 Nano's, with the read.
//========================================================================
module poke (
    input             clk,
    input             reset,

    input             stb,          // a byte from sysctrl.v
    input      [23:0] adr,
    input      [7:0]  data,

    input             peek_stb,     // a read request from sysctrl.v
    input      [23:0] peek_adr,
    output reg [31:0] peek_data,
    output reg        peek_ready,

    // sdram.v's port p
    output            p_req,
    output            p_we,
    output     [22:0] p_adr,
    output     [31:0] p_wdata,
    output     [3:0]  p_wmask,
    input             p_take,
    input             p_ack,
    input      [31:0] p_rdata
);

reg [31:0] fifo [0:15];
reg [4:0]  wp = 5'd0, rp = 5'd0;
wire empty = (wp == rp);
wire full  = (wp[3:0] == rp[3:0]) && (wp[4] != rp[4]);

reg        peek_pend = 1'b0;
reg [23:0] peek_a = 24'd0;

wire [23:0] head_adr = fifo[rp[3:0]][31:8];
wire [7:0]  head_dat = fifo[rp[3:0]][7:0];

assign p_req   = !empty || peek_pend;
assign p_we    = !empty;
assign p_adr   = !empty ? {1'b0, head_adr[23:2]} : {1'b0, peek_a[23:2]};
assign p_wdata = {4{head_dat}};
assign p_wmask = (head_adr[1:0] == 2'd0) ? 4'b0001 : (head_adr[1:0] == 2'd1) ? 4'b0010 :
                 (head_adr[1:0] == 2'd2) ? 4'b0100 : 4'b1000;

always @(posedge clk) begin
    if (reset) begin
        wp <= 5'd0; rp <= 5'd0; peek_pend <= 1'b0; peek_ready <= 1'b0;
    end else begin
        if (stb && !full) begin
            fifo[wp[3:0]] <= {adr, data};
            wp <= wp + 5'd1;
        end
        if (p_take) begin
            if (!empty) rp <= rp + 5'd1;
            else peek_pend <= 1'b0;
        end
        if (peek_stb) begin peek_pend <= 1'b1; peek_a <= peek_adr; peek_ready <= 1'b0; end
        if (p_ack && !p_we) begin peek_data <= p_rdata; peek_ready <= 1'b1; end
    end
end

endmodule

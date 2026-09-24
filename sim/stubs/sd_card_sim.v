//========================================================================
// sd_card_sim.v - a stand-in for src/mister/sd_card.v that serves image
// files from the host.
//
// The real module talks to the card over its SD bus and to the MCU over
// SPI, and the MCU's FatFs translates a sector within an image into a
// sector on the card.  None of that is worth simulating to test a
// floppy controller; what the peripherals see is the core-side sector
// interface, and this model implements that alone:
//
//   +TRDA=<file>  +TRDB=<file>  +TRDC=<file>  +TRDD=<file>  +HDD=<file>
//
// mount a file into slot 0..4 at start (image_mounted pulses with the
// size, as the MCU would send them after its settings) - the four
// floppies and the SMUC's disk - and then a
// rstart[i] with rsector is answered like the card would: rbusy up
// after a delay, 512 bytes on outen/outaddr/outbyte, rdone; a wstart
// takes 512 bytes from inbyte at outaddr.  Writes change the model's
// copy only, never the host file.  The MCU-side SPI target answers
// nothing useful (the testbench's MCU stand-in does not use it).
//
// The delay before rbusy stands for the MCU's round trip; +SDFAST makes
// it a few microseconds instead of a millisecond.
//========================================================================
`timescale 1ns / 1ps

module sd_card # (
    parameter [2:0] CLK_DIV = 3'd2,
    parameter       SIMULATE = 0
) (
    input             rstn,
    input             clk,
    output            sdclk,
    inout             sdcmd,
    inout [3:0]       sddat,

    input             data_strobe,
    input             data_start,
    input [7:0]       data_in,
    output reg [7:0]  data_out,

    output reg        irq,
    input             iack,

    output reg [31:0] image_size,
    output reg [4:0]  image_mounted,

    input [4:0]       rstart,
    input [4:0]       wstart,
    input [31:0]      rsector,
    output reg        rbusy,
    output reg        rdone,

    input [7:0]       inbyte,
    output reg        outen,
    output reg [8:0]  outaddr,
    output reg [7:0]  outbyte
);

assign sdclk = 1'b0;
assign sdcmd = 1'bz;
assign sddat = 4'bzzzz;

localparam MAXB = 4 * 1024 * 1024;   // bytes an image may have (a .trd is 655360; a disk image, small)

reg [7:0]  img [0:4][0:MAXB-1];
integer    size [0:4];
integer    fd, n, i, k, slot;
reg [1023:0] fname;

initial begin
    irq = 1'b0; data_out = 8'd0; image_size = 32'd0; image_mounted = 5'd0;
    rbusy = 1'b0; rdone = 1'b0; outen = 1'b0; outaddr = 9'd0; outbyte = 8'd0;
    for (i = 0; i < 5; i = i + 1) size[i] = 0;
    if ($value$plusargs("TRDA=%s", fname)) load(0, fname);
    if ($value$plusargs("TRDB=%s", fname)) load(1, fname);
    if ($value$plusargs("TRDC=%s", fname)) load(2, fname);
    if ($value$plusargs("TRDD=%s", fname)) load(3, fname);
    if ($value$plusargs("HDD=%s", fname))  load(4, fname);
end

task load(input integer s, input [1023:0] name);
    begin
        fd = $fopen(name, "rb");
        if (fd == 0) $display("[sd] cannot open %0s for slot %0d", name, s);
        else begin
            // a byte at a time: $fread cannot load a slice of a 2-D array
            n = 0;
            k = $fgetc(fd);
            while (k != -1 && n < MAXB) begin
                img[s][n] = k[7:0];
                n = n + 1;
                k = $fgetc(fd);
            end
            $fclose(fd);
            size[s] = n;
            $display("[sd] slot %0d: %0s, %0d bytes", s, name, n);
        end
    end
endtask

// mount what was loaded, once the design is out of reset
reg mounted_sent = 1'b0;
always @(posedge clk) begin
    image_mounted <= 5'd0;
    if (rstn && !mounted_sent) begin
        mounted_sent <= 1'b1;
        for (i = 0; i < 5; i = i + 1) if (size[i] != 0) begin
            image_size <= size[i];
            image_mounted[i] <= 1'b1;
            @(posedge clk); image_mounted <= 5'd0; @(posedge clk);
        end
    end
end

// the transfers
integer delay_ns;
initial delay_ns = $test$plusargs("SDFAST") ? 5000 : 1000000;

// The request is sampled once, as the MCU samples it when it starts
// the transfer; a request that is not still up then is a bug in the
// design, and one was (sd_arbiter.v's header).
reg [31:0] sec;
reg        is_read;
integer    b;
always @(posedge clk) begin
    rdone <= 1'b0;
    outen <= 1'b0;
    if (rstn && !rbusy && (rstart != 5'd0 || wstart != 5'd0)) begin
        slot = rstart[0] | wstart[0] ? 0 : rstart[1] | wstart[1] ? 1 : rstart[2] | wstart[2] ? 2 :
               rstart[3] | wstart[3] ? 3 : 4;
        #(delay_ns);
        if (rstart[slot] == 1'b0 && wstart[slot] == 1'b0)
            $display("[sd] %0t slot %0d: the request was dropped before the card took it", $time, slot);
        is_read = rstart[slot];
        sec     = rsector;
        rbusy <= 1'b1;
        if (is_read) begin
            if ($test$plusargs("SDTRACE")) $display("[sd] %0t slot %0d read sector %0d", $time, slot, sec);
            for (b = 0; b < 512; b = b + 1) begin
                repeat (3) @(posedge clk);
                outaddr <= b[8:0];
                outbyte <= (sec * 512 + b < size[slot]) ? img[slot][sec * 512 + b] : 8'h00;
                outen   <= 1'b1;
                @(posedge clk);
                outen   <= 1'b0;
            end
        end else begin
            if ($test$plusargs("SDTRACE")) $display("[sd] %0t slot %0d write sector %0d", $time, slot, sec);
            for (b = 0; b < 512; b = b + 1) begin
                outaddr <= b[8:0];
                repeat (3) @(posedge clk);
                if (sec * 512 + b < size[slot]) img[slot][sec * 512 + b] = inbyte;
            end
        end
        repeat (4) @(posedge clk);
        rdone <= 1'b1;
        rbusy <= 1'b0;
    end
end

endmodule

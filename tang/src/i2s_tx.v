`timescale 1ns / 1ps
//========================================================================
// i2s_tx.v - the I2S output to the dock's DAC, on the system clock.
//
// PK8000 Nano's through ZS-256 Nano's, at 64.8 MHz: an enable every
// twenty clocks gives a 1.62 MHz bit clock, 32 bits a frame, 50.6 kHz.
// The DAC does not mind the rate; the HDMI path resamples on its own and
// never sees this.  Nothing here is clocked by anything but `clk`.
//
// I2S: WS low is the left slot, data MSB first, WS changes one bit
// clock ahead of the word.  The sample pair is taken at the frame start.
//========================================================================
module i2s_tx (
    input             clk,
    input             reset,
    input      [15:0] sample_l,
    input      [15:0] sample_r,
    output reg        bck,
    output reg        ws,
    output reg        din
);

reg [4:0]  div    = 5'd0;     // 0..19: half a bit clock every twenty clocks
reg [4:0]  bit_n  = 5'd0;     // 0..31 within the frame
reg [15:0] sr     = 16'd0;
reg [15:0] hold_r = 16'd0;

always @(posedge clk) begin
    if (reset) begin
        div <= 5'd0; bck <= 1'b0; ws <= 1'b0; din <= 1'b0; bit_n <= 5'd0;
    end else begin
        if (div == 5'd19) begin
            div <= 5'd0;
            bck <= ~bck;
            if (bck) begin
                bit_n <= bit_n + 5'd1;
                if (bit_n == 5'd31) begin
                    sr     <= sample_l;
                    hold_r <= sample_r;
                end else if (bit_n == 5'd15)
                    sr <= hold_r;
                else
                    sr <= {sr[14:0], 1'b0};
                if (bit_n == 5'd30) ws <= 1'b0;
                if (bit_n == 5'd14) ws <= 1'b1;
            end
        end else
            div <= div + 5'd1;
        din <= sr[15];
    end
end

endmodule

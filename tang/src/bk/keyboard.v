`timescale 1ns / 1ps
//========================================================================
// keyboard.v - the BK-0011M's keyboard registers, filled from the MCU.
//
// The real keyboard is a matrix scanned by a chip that delivers one
// 7-bit КОИ-7 code a key into 177662 and raises 177660 bit 7, with an
// interrupt through vector 60 (or 274 for the АР2 chord and the keys that
// imply it) unless bit 6 of 177660 masks it; bit 6 of 177716 (in cpu.v)
// says whether any key is down.  The translation from USB to codes, the
// РУС/ЛАТ state and the shift and control chords, is the MCU's
// (mnano/bk.h, usb_host.c's kbd_tx_bk): what arrives here is one code
// with three flags, on hid.v's two-byte keyboard event:
//
//   code[6:0]   the КОИ-7 code, or 0 for a key that has none
//   flag[0]     release (0 press)
//   flag[1]     АР2 held or implied: the interrupt goes through 274
//   flag[2]     this is the СТОП key: a radial interrupt, not a code
//   flag[3]     the СБР (reset) key
//   flag[4]     a controller hotkey: АР2+ЛАТ (code 1) or АР2+РУС (2)
//
// Register semantics as GID's BK001001.cpp and MiSTer's keyboard.sv:
// 177660 bit 6 R/W (mask), bit 7 R/O (ready, cleared by a read of
// 177662); a press with the mask set still sets bit 7 and the interrupt
// is raised when the mask is cleared.  The RESET instruction (INIT)
// sets the mask, as the real machine's does.
//========================================================================
module keyboard (
    input             clk,
    input             reset,        // INIT from the processor

    // the bus
    input             sync,         // address valid
    input      [15:0] adr,
    input             stb,          // data strobe (level)
    input             we,
    input      [1:0]  wtbt,
    input      [15:0] din,
    output     [15:0] dout,
    output            ack,

    // the MCU's key events
    input      [7:0]  key_code,
    input      [7:0]  key_flags,
    input             key_stb,

    output reg        key_down,     // for 177716 bit 6
    output reg        key_stop,     // the СТОП key, a level
    output reg        key_reset,    // the СБР key, a level
    output reg [1:0]  hotkey,       // one clock: 1 АР2+ЛАТ, 2 АР2+РУС

    // the vector interrupts
    output reg        req60,
    input             ack60,
    output reg        req274,
    input             ack274
);

reg [15:0] r660 = 16'o100;    // the mask up, nothing ready
reg [6:0]  code = 7'd0;

wire sel660 = sync && (adr[15:1] == (16'o177660 >> 1));
wire sel662 = sync && (adr[15:1] == (16'o177662 >> 1)) && !we;   // read-only here; the write is video's
assign dout = sel660 ? r660 : sel662 ? {9'd0, code} : 16'd0;
assign ack  = stb && (sel660 || sel662);

reg  stb_d = 1'b0;
wire wr660 = stb && !stb_d && sel660 && we;
wire rd662 = stb && !stb_d && sel662;

// how many code-bearing keys are held: key_down while any is
reg [3:0] held = 4'd0;

always @(posedge clk) begin
    stb_d  <= stb;
    hotkey <= 2'd0;
    // The flagged keys are taken whether or not the machine is in reset:
    // СБР's own press starts a reset, INIT is up while it lasts, and its
    // release must still clear the level.  (Until 24 Sep 2026 the whole
    // event block sat under `else` of the reset: F11 held the machine in
    // reset until the board was replugged - the OSD's cold reset could
    // not clear a level the keyboard owned.)  СТОП and the hotkeys the
    // same way, so a key is never lost across a reset.
    if (key_stb && key_flags[2]) key_stop  <= !key_flags[0];
    if (key_stb && key_flags[3]) key_reset <= !key_flags[0];
    if (key_stb && key_flags[4] && !key_flags[0]) hotkey <= key_code[1:0];
    if (reset) begin
        r660[6] <= 1'b1;
        r660[7] <= 1'b0;
        req60   <= 1'b0;
        req274  <= 1'b0;
    end else begin
        if (wr660 && wtbt[0]) begin
            r660[6] <= din[6];
            // clearing the mask with a code waiting raises the interrupt
            if (!din[6] && r660[6] && r660[7]) req60 <= 1'b1;
        end
        if (rd662) begin
            r660[7] <= 1'b0;
            req60   <= 1'b0;
            req274  <= 1'b0;
        end
        if (ack60)  req60  <= 1'b0;
        if (ack274) req274 <= 1'b0;

        if (key_stb && !key_flags[2] && !key_flags[3] && !key_flags[4]) begin
            if (key_code[6:0] != 7'd0) begin
                if (!key_flags[0]) begin
                    code    <= key_code[6:0];
                    r660[7] <= 1'b1;
                    if (!r660[6]) begin
                        if (key_flags[1]) req274 <= 1'b1;
                        else              req60  <= 1'b1;
                    end
                    if (held != 4'd15) held <= held + 4'd1;
                end else begin
                    if (held != 4'd0) held <= held - 4'd1;
                end
            end
        end
        key_down <= (held != 4'd0);
    end
end

endmodule

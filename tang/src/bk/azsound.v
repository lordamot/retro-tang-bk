`timescale 1ns / 1ps
//========================================================================
// azsound.v - the AZBK's sound: two AYs, the Covox, the DMA player, the
// speaker, and the mixer.
//
// Registers (MAXIOL's "Проект звуковой части", GID's AZBK.cpp):
//   177160-177170  the DMA player: control, start page, length (words,
//                  24 bits in two registers), current page (read-only)
//   177172/177173  AY1 address and data, 177174/177175 AY2 (bytes; a
//                  word write is address in the low byte, data in the high)
//   177176/177177  OPL2: gone in firmware 19, answers zeros here
//   177200/177202  Covox, 16 bits left and right
//   177204         Covox, 16 bits to both
//   177206         Covox, 8 bits: a word write is left in the low byte,
//                  right in the high; a byte write is both
//   177212         control: bit 0 legacy Covox stereo, bit 1 legacy
//                  Covox off, bit 2 speaker off, bit 3 AY8910 not YM2149
//   177714 (write) the BK's port: the AY the BK way (a word write selects
//                  the register, a byte write loads it, both inverted; bit
//                  14 of the word names chip 2), and the legacy 8-bit Covox
//                  when bit 1 of 177212 allows
//   177716 (write) bits 6, 5, 2 the speaker, three bits
//
// The AYs are MiSTer's ym2149.sv at 1.7 MHz (the BK's clock, an enable
// every 38 clocks - 1.705 MHz).  The DMA player takes a 32-bit word from
// the SDRAM whenever its two-word hold runs out and produces a sample
// every 1/44100 s from a phase accumulator: PCM 16-bit mono, or IMA
// ADPCM mono (a nibble a sample, low first) or stereo (low nibble left,
// high right), decoded as GID's ima.cpp does - the step table is the
// standard one and the state persists across a cycle when bit 4 says so.
//
// The mix is signed 16 bits a side: right is AY channels A and B of
// both chips, left C and B (MAXIOL's formula), plus the Covox, the
// speaker and the DMA, each scaled so that no single source clips; the
// Covox, the speaker and the AYs are unipolar and go through a DC
// blocker, so a program's silence is silence and not an offset.
//========================================================================
module azsound (
    input             clk,
    input             reset,        // INIT: the AYs reset

    // the bus: 177160-177212
    input             sync,
    input      [15:0] adr,
    input             stb,
    input             we,
    input      [1:0]  wtbt,
    input      [15:0] din,
    output     [15:0] dout,
    output            ack,
    input             wr_stb,

    // the processor's own registers, written
    input             sel2_wr,      // 177714
    input             sel1_wr,      // 177716
    input      [15:0] cpu_dout,
    input      [1:0]  cpu_wtbt,

    // the DMA's memory port
    output reg        d_req,
    output reg [22:0] d_adr,
    input             d_take,
    input             d_ack,
    input      [31:0] d_rdata,

    output signed [15:0] out_l,
    output signed [15:0] out_r
);

//------------------------------------------------------------------------
// Registers
//------------------------------------------------------------------------
reg [15:0] dma_csr = 16'd0;
reg        dma_done = 1'b0;          // bit B_DONE of it, the player's to set (one driver a register: Gowin EX2000)
reg [12:0] dma_page = 13'd0;
reg [23:0] dma_len = 24'd0;          // words
reg [12:0] dma_cur = 13'd0;
reg [7:0]  ay1_adr = 8'd0, ay1_dat = 8'd0, ay2_adr = 8'd0, ay2_dat = 8'd0;
reg [15:0] cvx_l = 16'd0, cvx_r = 16'd0, cvx_m = 16'd0;
reg [3:0]  cvx_csr = 4'd0;
reg        ay_bk2 = 1'b0;            // 177714's last select named chip 2
reg [15:0] spk = 16'd0;

wire sel_a = sync && (adr[15:4] == (16'o177160 >> 4));   // 177160-177176
wire sel_b = sync && (adr[15:4] == (16'o177200 >> 4)) && (adr[3:1] <= 3'd5);   // 177200-177212
wire [2:0] ra = adr[3:1];
reg  [15:0] vdata;
always @(*) begin
    if (sel_a) case (ra)
        3'd0: vdata = dma_csr | (dma_done ? (16'd1 << B_DONE) : 16'd0);
        3'd1: vdata = {3'd0, dma_page};
        3'd2: vdata = {8'd0, dma_len[23:16]};
        3'd3: vdata = dma_len[15:0];
        3'd4: vdata = {3'd0, dma_cur};
        3'd5: vdata = {ay1_dat, ay1_adr};
        3'd6: vdata = {ay2_dat, ay2_adr};
        default: vdata = 16'd0;
    endcase
    else case (ra)
        3'd0: vdata = cvx_l;
        3'd1: vdata = cvx_r;
        3'd2: vdata = cvx_m;
        3'd3: vdata = {cvx_r[15:8], cvx_l[15:8]};
        3'd5: vdata = {12'd0, cvx_csr};
        default: vdata = 16'd0;
    endcase
end
assign dout = (sel_a || sel_b) ? vdata : 16'd0;
assign ack  = stb && (sel_a || sel_b);

wire wr_a = wr_stb && sel_a;
wire wr_b = wr_stb && sel_b;

// the AY writes: strobes with address/data for the two chips
reg        ay1_a_stb = 1'b0, ay1_d_stb = 1'b0, ay2_a_stb = 1'b0, ay2_d_stb = 1'b0;
reg        ay1_d_pend = 1'b0, ay2_d_pend = 1'b0;   // a data write behind an address write
reg [7:0]  ay1_wdata = 8'd0, ay2_wdata = 8'd0;
reg        dma_kick = 1'b0;

always @(posedge clk) begin
    ay1_a_stb <= 1'b0; ay2_a_stb <= 1'b0;
    ay1_d_stb <= ay1_d_pend; ay2_d_stb <= ay2_d_pend;
    ay1_d_pend <= 1'b0; ay2_d_pend <= 1'b0;
    dma_kick <= 1'b0;
    if (wr_a) case (ra)
        3'd0: begin dma_csr <= din; dma_kick <= 1'b1; end
        3'd1: dma_page <= din[12:0];
        3'd2: dma_len[23:16] <= din[7:0];
        3'd3: dma_len[15:0] <= din;
        3'd5: begin
            // a word write: address low, data high; a byte write picks one
            if (wtbt[0]) begin ay1_adr <= din[7:0]; ay1_a_stb <= 1'b1; ay1_wdata <= din[7:0]; end
            if (wtbt[1]) begin ay1_dat <= din[15:8]; ay1_d_pend <= 1'b1; end
        end
        3'd6: begin
            if (wtbt[0]) begin ay2_adr <= din[7:0]; ay2_a_stb <= 1'b1; ay2_wdata <= din[7:0]; end
            if (wtbt[1]) begin ay2_dat <= din[15:8]; ay2_d_pend <= 1'b1; end
        end
        default: ;
    endcase
    if (wr_b) case (ra)
        3'd0: cvx_l <= din;
        3'd1: cvx_r <= din;
        3'd2: begin cvx_l <= din; cvx_r <= din; cvx_m <= din; end
        3'd3: begin
            if (wtbt[1] && wtbt[0]) begin cvx_l <= {1'b0, din[7:0], 7'd0}; cvx_r <= {1'b0, din[15:8], 7'd0}; end
            else begin cvx_l <= {1'b0, din[7:0], 7'd0}; cvx_r <= {1'b0, din[7:0], 7'd0}; cvx_m <= {1'b0, din[7:0], 7'd0}; end
        end
        3'd5: cvx_csr <= din[3:0];
        default: ;
    endcase
    // 177714: the AY the BK world's way - a WORD write selects the register,
    // a BYTE write (the low byte) loads it, both inverted, both from the low
    // byte (MiSTer's BK0011M.sv: BC = bus_wtbt[1], DI = ~bus_din[7:0]; the
    // package's AY_TEST: MOV #362,@#177714 then MOVB ~value).  Until 24 Sep
    // 2026 a high-byte write was the select and BK-world music was silent.
    // Which chip: GID's `~word & 0140000` - read here as bit 14 of the
    // written word set = chip 2, else chip 1 (an ordinary BK program writes
    // a zero high byte and gets chip 1); a decision to check against GID's
    // source, not a fact.  The byte goes to the chip last selected.
    if (sel2_wr) begin
        if (cpu_wtbt[1] && cpu_wtbt[0]) begin
            ay_bk2 <= cpu_dout[14];
            if (cpu_dout[14]) begin ay2_adr <= ~cpu_dout[7:0]; ay2_a_stb <= 1'b1; ay2_wdata <= ~cpu_dout[7:0]; end
            else              begin ay1_adr <= ~cpu_dout[7:0]; ay1_a_stb <= 1'b1; ay1_wdata <= ~cpu_dout[7:0]; end
        end
        if (cpu_wtbt[0] && !cpu_wtbt[1]) begin
            if (ay_bk2) begin ay2_dat <= ~cpu_dout[7:0]; ay2_d_pend <= 1'b1; end
            else        begin ay1_dat <= ~cpu_dout[7:0]; ay1_d_pend <= 1'b1; end
        end
        if (!cvx_csr[1]) begin
            if (cvx_csr[0]) begin cvx_l <= {cpu_dout[7:0], 8'd0}; cvx_r <= {cpu_dout[15:8], 8'd0}; end
            else begin cvx_l <= {cpu_dout[7:0], 8'd0}; cvx_r <= {cpu_dout[7:0], 8'd0}; cvx_m <= {cpu_dout[7:0], 8'd0}; end
        end
    end
    // 177716 without bit 11: the speaker's three bits, GID's weighting
    if (sel1_wr && !cpu_dout[11] && !cvx_csr[2])
        spk <= {cpu_dout[6], cpu_dout[5], cpu_dout[2], 1'b0, cpu_dout[2], 2'b00, 9'd0};   // bits 6, 5, 2 (and 2 again as 4), << 9
    if (reset) begin spk <= 16'd0; end
end

//------------------------------------------------------------------------
// The AYs: an enable at 1.705 MHz
//------------------------------------------------------------------------
reg [5:0] ay_div = 6'd0;
reg       ay_ce = 1'b0;
always @(posedge clk) begin
    ay_div <= (ay_div == 6'd37) ? 6'd0 : ay_div + 6'd1;
    ay_ce  <= (ay_div == 6'd0);
end

// the write interface of ym2149.sv: BDIR=1 BC=1 address, BDIR=1 BC=0 data
wire [7:0] a1_a, a1_b, a1_c, a2_a, a2_b, a2_c;
YM2149 ay1 (
    .CLK(clk), .CE(ay_ce), .RESET(reset),
    .BDIR(ay1_a_stb | ay1_d_stb), .BC(ay1_a_stb),
    .DI(ay1_a_stb ? ay1_wdata : ay1_dat), .DO(),
    .CHANNEL_A(a1_a), .CHANNEL_B(a1_b), .CHANNEL_C(a1_c),
    .SEL(1'b0), .MODE(1'b0), .ACTIVE(),
    .IOA_in(8'd0), .IOA_out(), .IOB_in(8'd0), .IOB_out()
);
YM2149 ay2 (
    .CLK(clk), .CE(ay_ce), .RESET(reset),
    .BDIR(ay2_a_stb | ay2_d_stb), .BC(ay2_a_stb),
    .DI(ay2_a_stb ? ay2_wdata : ay2_dat), .DO(),
    .CHANNEL_A(a2_a), .CHANNEL_B(a2_b), .CHANNEL_C(a2_c),
    .SEL(1'b0), .MODE(1'b0), .ACTIVE(),
    .IOA_in(8'd0), .IOA_out(), .IOB_in(8'd0), .IOB_out()
);

//------------------------------------------------------------------------
// The DMA player
//------------------------------------------------------------------------
localparam B_START = 0, B_ONESHOT = 1, B_STOP = 2, B_DONE = 3, B_STREAM = 4;
wire [2:0] dma_mode = dma_csr[11:9];     // 0 PCM16 mono, 4 IMA mono, 5 IMA stereo

reg        playing = 1'b0;
reg [23:0] words_left = 24'd0;           // in the file
reg [23:0] dma_wadr = 24'd0;             // the next word to fetch
reg [31:0] hold = 32'd0;                 // two words fetched
reg [1:0]  hold_n = 2'd0;                // words in hold
reg        hold_pend = 1'b0;
reg [15:0] cur_w = 16'd0;                // the word being consumed
reg [2:0]  cur_left = 3'd0;              // units left in cur_w (1 word, 4 nibbles or 2 bytes)
reg signed [15:0] pcm_l = 16'sd0, pcm_r = 16'sd0;

// the 44100 Hz tick: 64.8 MHz * 44100 / 2^24 ... a 24-bit accumulator
// adds 11418 a clock and wraps at 16777216: 44099.9 Hz
reg [23:0] tick_acc = 24'd0;
wire [24:0] tick_nxt = {1'b0, tick_acc} + 25'd11418;
wire tick = tick_nxt[24];
always @(posedge clk) tick_acc <= tick_nxt[23:0];

// IMA state, two channels
reg signed [15:0] ima_cur [0:1];
reg [6:0]         ima_idx [0:1];
initial begin ima_cur[0] = 16'sd0; ima_cur[1] = 16'sd0; ima_idx[0] = 7'd0; ima_idx[1] = 7'd0; end

function [15:0] step_of; input [6:0] i;
    case (i)
        7'd0: step_of = 7;     7'd1: step_of = 8;     7'd2: step_of = 9;     7'd3: step_of = 10;
        7'd4: step_of = 11;    7'd5: step_of = 12;    7'd6: step_of = 13;    7'd7: step_of = 14;
        7'd8: step_of = 16;    7'd9: step_of = 17;    7'd10: step_of = 19;   7'd11: step_of = 21;
        7'd12: step_of = 23;   7'd13: step_of = 25;   7'd14: step_of = 28;   7'd15: step_of = 31;
        7'd16: step_of = 34;   7'd17: step_of = 37;   7'd18: step_of = 41;   7'd19: step_of = 45;
        7'd20: step_of = 50;   7'd21: step_of = 55;   7'd22: step_of = 60;   7'd23: step_of = 66;
        7'd24: step_of = 73;   7'd25: step_of = 80;   7'd26: step_of = 88;   7'd27: step_of = 97;
        7'd28: step_of = 107;  7'd29: step_of = 118;  7'd30: step_of = 130;  7'd31: step_of = 143;
        7'd32: step_of = 157;  7'd33: step_of = 173;  7'd34: step_of = 190;  7'd35: step_of = 209;
        7'd36: step_of = 230;  7'd37: step_of = 253;  7'd38: step_of = 279;  7'd39: step_of = 307;
        7'd40: step_of = 337;  7'd41: step_of = 371;  7'd42: step_of = 408;  7'd43: step_of = 449;
        7'd44: step_of = 494;  7'd45: step_of = 544;  7'd46: step_of = 598;  7'd47: step_of = 658;
        7'd48: step_of = 724;  7'd49: step_of = 796;  7'd50: step_of = 876;  7'd51: step_of = 963;
        7'd52: step_of = 1060; 7'd53: step_of = 1166; 7'd54: step_of = 1282; 7'd55: step_of = 1411;
        7'd56: step_of = 1552; 7'd57: step_of = 1707; 7'd58: step_of = 1878; 7'd59: step_of = 2066;
        7'd60: step_of = 2272; 7'd61: step_of = 2499; 7'd62: step_of = 2749; 7'd63: step_of = 3024;
        7'd64: step_of = 3327; 7'd65: step_of = 3660; 7'd66: step_of = 4026; 7'd67: step_of = 4428;
        7'd68: step_of = 4871; 7'd69: step_of = 5358; 7'd70: step_of = 5894; 7'd71: step_of = 6484;
        7'd72: step_of = 7132; 7'd73: step_of = 7845; 7'd74: step_of = 8630; 7'd75: step_of = 9493;
        7'd76: step_of = 10442; 7'd77: step_of = 11487; 7'd78: step_of = 12635; 7'd79: step_of = 13899;
        7'd80: step_of = 15289; 7'd81: step_of = 16818; 7'd82: step_of = 18500; 7'd83: step_of = 20350;
        7'd84: step_of = 22385; 7'd85: step_of = 24623; 7'd86: step_of = 27086; 7'd87: step_of = 29794;
        default: step_of = 32767;
    endcase
endfunction

// One IMA nibble on one channel, in three registered stages (a single
// clock of table lookup, three adds and a clamp was 17.8 ns at 64.8 MHz,
// 19 Sep 2026): the step of the index is kept registered; on the tick
// the nibbles are latched; a clock later the difference and the next
// index; a clock later the sum, clamped, into the sample and the outputs.
function [17:0] ima_diff; input [3:0] v; input [15:0] step;
    reg [17:0] d;
    begin
        d = {2'd0, step} >> 3;
        if (v[0]) d = d + ({2'd0, step} >> 2);
        if (v[1]) d = d + ({2'd0, step} >> 1);
        if (v[2]) d = d + {2'd0, step};
        ima_diff = d;
    end
endfunction
function [6:0] ima_next; input [3:0] v; input [6:0] idx;
    case (v[2:0])
        3'd0, 3'd1, 3'd2, 3'd3: ima_next = (idx == 7'd0) ? 7'd0 : idx - 7'd1;
        3'd4: ima_next = (idx > 7'd86) ? 7'd88 : idx + 7'd2;
        3'd5: ima_next = (idx > 7'd84) ? 7'd88 : idx + 7'd4;
        3'd6: ima_next = (idx > 7'd82) ? 7'd88 : idx + 7'd6;
        default: ima_next = (idx > 7'd80) ? 7'd88 : idx + 7'd8;
    endcase
endfunction
function signed [15:0] ima_sum; input sgn; input signed [15:0] cur; input [17:0] diff;
    reg signed [17:0] n;
    begin
        n = sgn ? $signed({{2{cur[15]}}, cur}) - $signed({1'b0, diff[16:0]})
                : $signed({{2{cur[15]}}, cur}) + $signed({1'b0, diff[16:0]});
        if (n > 18'sd32767) n = 18'sd32767;
        if (n < -18'sd32768) n = -18'sd32768;
        ima_sum = n[15:0];
    end
endfunction

reg [15:0] step_r [0:1];
initial begin step_r[0] = 16'd7; step_r[1] = 16'd7; end
always @(posedge clk) begin
    step_r[0] <= step_of(ima_idx[0]);
    step_r[1] <= step_of(ima_idx[1]);
end

reg        dec_a = 1'b0, dec_b = 1'b0, dec_st = 1'b0;   // the stages, and stereo
reg [3:0]  nib [0:1];
reg [17:0] diff_r [0:1];
reg [6:0]  ni_r [0:1];
reg        sgn_r [0:1];
initial begin nib[0] = 4'd0; nib[1] = 4'd0; diff_r[0] = 18'd0; diff_r[1] = 18'd0;
              ni_r[0] = 7'd0; ni_r[1] = 7'd0; sgn_r[0] = 1'b0; sgn_r[1] = 1'b0; end

// how many samples a word holds in each mode: 1 (PCM16), 4 (IMA mono), 2 (IMA stereo)
wire [2:0] units = (dma_mode == 3'd4) ? 3'd4 : (dma_mode == 3'd5) ? 3'd2 : 3'd1;

always @(posedge clk) begin
    // a fetch of two words whenever the hold is empty
    if (playing && hold_n == 2'd0 && !hold_pend && words_left != 24'd0) begin
        d_req <= 1'b1; d_adr <= dma_wadr[23:1]; hold_pend <= 1'b1;
    end
    if (d_take) d_req <= 1'b0;
    if (d_ack && hold_pend) begin
        hold_pend <= 1'b0;
        hold <= d_rdata;
        hold_n <= (words_left == 24'd1) ? 2'd1 : 2'd2;
        dma_wadr <= dma_wadr + 24'd2;
        words_left <= (words_left == 24'd1) ? 24'd0 : words_left - 24'd2;
        dma_cur <= dma_wadr[23:11] + 13'd0;
    end

    if (dma_kick) begin
        dma_done <= 1'b0;
        if (dma_csr[B_STOP]) begin
            playing <= 1'b0;
        end else if (dma_csr[B_START] && !dma_csr[B_DONE] && !dma_done) begin
            playing <= 1'b1;
            words_left <= dma_len;
            dma_wadr <= {dma_page, 11'd0};
            dma_cur <= dma_page;
            hold_n <= 2'd0; cur_left <= 3'd0;
            ima_cur[0] <= 16'sd0; ima_cur[1] <= 16'sd0; ima_idx[0] <= 7'd0; ima_idx[1] <= 7'd0;
        end
    end

    // the decode pipeline (launched at the tick below)
    dec_a <= 1'b0; dec_b <= dec_a;
    if (dec_a) begin
        diff_r[0] <= ima_diff(nib[0], step_r[0]); ni_r[0] <= ima_next(nib[0], ima_idx[0]); sgn_r[0] <= nib[0][3];
        diff_r[1] <= ima_diff(nib[1], step_r[1]); ni_r[1] <= ima_next(nib[1], ima_idx[1]); sgn_r[1] <= nib[1][3];
    end
    if (dec_b) begin
        ima_cur[0] <= ima_sum(sgn_r[0], ima_cur[0], diff_r[0]); ima_idx[0] <= ni_r[0];
        pcm_l <= ima_sum(sgn_r[0], ima_cur[0], diff_r[0]);
        if (dec_st) begin
            ima_cur[1] <= ima_sum(sgn_r[1], ima_cur[1], diff_r[1]); ima_idx[1] <= ni_r[1];
            pcm_r <= ima_sum(sgn_r[1], ima_cur[1], diff_r[1]);
        end else
            pcm_r <= ima_sum(sgn_r[0], ima_cur[0], diff_r[0]);
    end

    if (tick && playing) begin
        if (cur_left == 3'd0) begin
            // take the next word from the hold, or wrap to the start
            if (hold_n != 2'd0) begin
                cur_w <= hold[15:0];
                hold <= {16'd0, hold[31:16]};
                hold_n <= hold_n - 2'd1;
                cur_left <= units - 3'd1;
                // consume the first unit now
                case (dma_mode)
                    3'd4: begin nib[0] <= hold[3:0]; nib[1] <= hold[3:0]; dec_a <= 1'b1; dec_st <= 1'b0; cur_w <= {4'd0, hold[15:4]}; end
                    3'd5: begin nib[0] <= hold[3:0]; nib[1] <= hold[7:4]; dec_a <= 1'b1; dec_st <= 1'b1; cur_w <= {8'd0, hold[15:8]}; end
                    default: begin pcm_l <= hold[15:0]; pcm_r <= hold[15:0]; end
                endcase
            end else if (words_left == 24'd0 && !hold_pend) begin
                // the file is over: once, or again
                if (dma_csr[B_ONESHOT]) begin
                    dma_done <= 1'b1;
                    playing <= 1'b0;
                end else begin
                    words_left <= dma_len;
                    dma_wadr <= {dma_page, 11'd0};
                    dma_cur <= dma_page;
                    if (!dma_csr[B_STREAM]) begin
                        ima_cur[0] <= 16'sd0; ima_cur[1] <= 16'sd0; ima_idx[0] <= 7'd0; ima_idx[1] <= 7'd0;
                    end
                end
            end
        end else begin
            cur_left <= cur_left - 3'd1;
            case (dma_mode)
                3'd4: begin nib[0] <= cur_w[3:0]; nib[1] <= cur_w[3:0]; dec_a <= 1'b1; dec_st <= 1'b0; cur_w <= {4'd0, cur_w[15:4]}; end
                3'd5: begin nib[0] <= cur_w[3:0]; nib[1] <= cur_w[7:4]; dec_a <= 1'b1; dec_st <= 1'b1; cur_w <= {8'd0, cur_w[15:8]}; end
                default: ;
            endcase
        end
    end
    if (!playing) begin pcm_l <= 16'sd0; pcm_r <= 16'sd0; end
end

//------------------------------------------------------------------------
// The mix
//------------------------------------------------------------------------
// the AYs: right A+B, left C+B, of both chips; 8-bit channels
wire [10:0] ay_r = {3'd0, a1_a} + {3'd0, a2_a} + {3'd0, a1_b} + {3'd0, a2_b};
wire [10:0] ay_l = {3'd0, a1_c} + {3'd0, a2_c} + {3'd0, a1_b} + {3'd0, a2_b};
// unipolar sources through a DC blocker: y = x - x1 + y1 * (1 - 1/1024).
// The AYs go through it too (x48, so that after the >>2 below a channel
// is x12 as before): the YM idles at 0, so centring their sum on a
// constant (12240 until 24 Sep 2026) made silence a DC of -12240.
wire signed [19:0] uni_l = {4'd0, cvx_l} + {4'd0, spk} + ({9'd0, ay_l} << 5) + ({9'd0, ay_l} << 4);
wire signed [19:0] uni_r = {4'd0, cvx_r} + {4'd0, spk} + ({9'd0, ay_r} << 5) + ({9'd0, ay_r} << 4);
reg signed [19:0] x1_l = 20'sd0, x1_r = 20'sd0, y_l = 20'sd0, y_r = 20'sd0;
reg [9:0] dc_div = 10'd0;
always @(posedge clk) begin
    // run the blocker at 63 kHz, a sample rate the coefficient suits
    dc_div <= (dc_div == 10'd1023) ? 10'd0 : dc_div + 10'd1;
    if (dc_div == 10'd0) begin
        y_l <= uni_l - x1_l + (y_l - (y_l >>> 10));
        y_r <= uni_r - x1_r + (y_r - (y_r >>> 10));
        x1_l <= uni_l; x1_r <= uni_r;
    end
end

wire signed [19:0] sum_l = (y_l >>> 2) + $signed({{4{pcm_l[15]}}, pcm_l}) / 20'sd2;
wire signed [19:0] sum_r = (y_r >>> 2) + $signed({{4{pcm_r[15]}}, pcm_r}) / 20'sd2;

// clip to 16 bits
wire signed [19:0] c_l = sum_l;
wire signed [19:0] c_r = sum_r;
reg signed [15:0] o_l = 16'sd0, o_r = 16'sd0;
always @(posedge clk) begin
    o_l <= (c_l > 20'sd32767) ? 16'sd32767 : (c_l < -20'sd32768) ? -16'sd32768 : c_l[15:0];
    o_r <= (c_r > 20'sd32767) ? 16'sd32767 : (c_r < -20'sd32768) ? -16'sd32768 : c_r[15:0];
end
assign out_l = o_l;
assign out_r = o_r;

endmodule

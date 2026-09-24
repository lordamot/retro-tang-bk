`timescale 1ns / 1ps
//========================================================================
// azvideo.v - the AZBK's display: 1024x768 at 60 Hz out of the SDRAM.
//
// The AZBK draws the whole picture itself, from its own memory, in a
// fixed VGA frame of 1024x768 at 60 Hz (1344 x 806 clocks at 64.8 MHz
// here, 59.8 Hz).  What is drawn is set by 177230: the bits per pixel
// (1, 2, 4, 8), the length of a line in words (32..256), the horizontal
// stretch (every pixel 1, 2, 4 or 8 wide) and the vertical (every line
// 1, 2, 3 or 4 high), the length of the "roll" the vertical scroll wraps
// in, and whether one page or three layers are shown.  177232/177240/
// 177242 name the pages (4 KB units of the 32 MB) of the three layers,
// 177244-177256 scroll them, 177234/177236 reach the palette (and the
// controller's hotkeys switch the legacy screen and reset the palette), and the
// BK-0011M's own 177662 (palette number, screen buffer) and 177664
// (scroll, quarter screen) are honoured on top of that.  The register
// meaning is MAXIOL's ("К расширенным видеорежимам добавились слои") and
// the pixel arithmetic is GID's MakeScreenLine (AZBK_Video.cpp), which
// is what the software was tested against.
//
// How it is done here: every display line is fetched, during the line
// before it, into one of two line buffers - all three layers, as many
// words as the line is long, in bursts of eight from sdram.v's top-
// priority port - and the pixel pipeline reads the other buffer a word
// at a time, six clocks ahead of the pixel it produces: the word index
// with the horizontal scroll, the buffer, the bits, the palette index by
// the mode's rule, the palette RAM, the colour.  The vertical position
// of each layer is a row counter that starts the frame at (scroll mod
// roll length) - a subtraction loop run in the vertical blanking - and
// steps every ys display lines, wrapping at the roll length.
//
// Two things in this file are not the display: the 50 Hz and 60 Hz
// frame interrupts (the BK-0011M's own, enabled by 177662 bit 14; the
// controller's, by 177346 bits 3 and 2) and the pulse at line 769 that
// starts the blitter - both live off this raster on the real controller.
//========================================================================
module azvideo (
    input             clk,

    // the bus (registers 177230-177256, 177662 write, 177664)
    input             sync,
    input      [15:0] adr,
    input             stb,
    input             we,
    input      [1:0]  wtbt,
    input      [15:0] din,
    output     [15:0] dout,
    output            ack,
    input             wr_stb,

    input      [15:0] mapper_ctrl,  // 177346: the timer bits
    input             cold,
    input      [1:0]  hotkey,       // keyboard.v, one clock: 1 АР2+ЛАТ, 2 АР2+РУС

    // the SDRAM's burst port
    output reg        v_req,
    output reg [22:0] v_adr,
    input             v_take,
    input             v_dv,
    input      [31:0] v_rdata,

    // the picture
    output reg        hs,
    output reg        vs,
    output reg        de,
    output reg [7:0]  r,
    output reg [7:0]  g,
    output reg [7:0]  b,

    output reg        frame_end,    // one clock at line 769: the blitter's start
    output reg        irq2,         // the frame interrupt, a level of 2 ms
    output     [15:0] reg664_out,   // for the debug window
    output     [15:0] scr_csr_out
);

//------------------------------------------------------------------------
// The raster: 1024 + 24 + 136 + 160 = 1344, 768 + 3 + 6 + 29 = 806.
//------------------------------------------------------------------------
reg [10:0] hcnt = 11'd0;
reg [9:0]  vcnt = 10'd0;
wire line_start = (hcnt == 11'd0);
wire h_active = (hcnt < 11'd1024);
wire v_active = (vcnt < 10'd768);
wire hs_raw = (hcnt >= 11'd1048) && (hcnt < 11'd1184);
wire vs_raw = (vcnt >= 10'd771)  && (vcnt < 10'd777);

always @(posedge clk) begin
    if (hcnt == 11'd1343) begin
        hcnt <= 11'd0;
        vcnt <= (vcnt == 10'd805) ? 10'd0 : vcnt + 10'd1;
    end else
        hcnt <= hcnt + 11'd1;
end

//------------------------------------------------------------------------
// The registers
//------------------------------------------------------------------------
reg [15:0] scr_csr = 16'o012100;
reg [12:0] pg [0:2];
reg [15:0] vscrl [0:2];          // 177250 (L0), 177246 (L1), 177244 (L2)
reg [7:0]  hscrl [0:2];          // 177252, 177254, 177256
reg [8:0]  pal_cell = 9'd0;
reg [3:0]  legacy_pal = 4'd15;
reg [15:0] reg664 = 16'o001330;
reg        extended = 1'b0;
reg        timer_bk = 1'b0;      // 177662 bit 14 clear: the BK-0011M's 50 Hz
initial begin
    pg[0] = 13'd4; pg[1] = 13'd4; pg[2] = 13'd4;
    vscrl[0] = 16'd0; vscrl[1] = 16'd0; vscrl[2] = 16'd0;
    hscrl[0] = 8'd0; hscrl[1] = 8'd0; hscrl[2] = 8'd0;
end
assign reg664_out = reg664;
assign scr_csr_out = scr_csr;

// 177230 csr, 177232 pg0, 177234 pal sq, 177236 pal value, 177240 pg1,
// 177242 pg2, 177244 vs2, 177246 vs1, 177250 vs0, 177252 hs0, 177254 hs1, 177256 hs2
// 177230-177256 straddle a 32-byte boundary: index from 177200 (19 Sep 2026)
wire [4:0] vidx = adr[5:1] - 5'd12;
wire [3:0] vreg = vidx[3:0];
wire sel_v  = sync && (adr[15:6] == (16'o177200 >> 6)) && (adr[5:1] >= 5'd12) && (adr[5:1] <= 5'd23);
wire sel_664 = sync && (adr[15:1] == (16'o177664 >> 1));
wire sel_662w = sync && (adr[15:1] == (16'o177662 >> 1)) && we;

wire [14:0] pal_a_dout;
reg  [15:0] vdata;
always @(*) begin
    case (vreg)
        4'd0:  vdata = scr_csr;
        4'd1:  vdata = {3'd0, pg[0]};
        4'd2:  vdata = {7'd0, pal_cell};
        4'd3:  vdata = {1'b0, pal_a_dout};
        4'd4:  vdata = {3'd0, pg[1]};
        4'd5:  vdata = {3'd0, pg[2]};
        4'd6:  vdata = vscrl[2];
        4'd7:  vdata = vscrl[1];
        4'd8:  vdata = vscrl[0];
        4'd9:  vdata = {8'd0, hscrl[0]};
        4'd10: vdata = {8'd0, hscrl[1]};
        default: vdata = {8'd0, hscrl[2]};
    endcase
end
assign dout = sel_v ? vdata : sel_664 ? reg664 : 16'd0;
assign ack  = stb && (sel_v || sel_664 || sel_662w);

wire wr_v   = wr_stb && sel_v;
wire wr_664 = wr_stb && sel_664;
wire wr_662 = wr_stb && sel_662w && wtbt[1];

// the frame timers: 50 Hz from a counter, 60 Hz from the raster
wire az_v100 = mapper_ctrl[3];
wire az_50hz = mapper_ctrl[2];
// The "50 Hz" - the BK's own frame interrupt and the AZ's 50 Hz timer -
// is the AZBK's "v-sync timer 48Hz" (its BIOS's name for it): derived
// from the 60 Hz frame, four interrupts in every five frames, each at
// the end of the visible part like the 60 Hz.  Until 23 Sep 2026 it was
// a free-running counter at exactly 50 Hz, and a game whose handler
// switches its pages on it did so at a raster line drifting with the
// beat between 50 and 59.8 Hz: the band moving through Dangerous Dave's
// picture on the board (`soft/current1.mp4`).
reg  [2:0]  frame5 = 3'd0;
wire tick50 = (vcnt == 10'd769) && line_start && (frame5 != 3'd4);
reg  [17:0] irq_hold = 18'd0;

always @(posedge clk) begin
    // The controller's hotkeys (mcu.md): АР2+ЛАТ shows the BK's screen as
    // the colour monitor would (2 bits a pixel, 256 wide, stretched x4)
    // or as the monochrome one would (1 bit, 512 wide, x2) - a real BK
    // has both outputs and the AZ one, so the key chooses; it does
    // nothing outside the two legacy modes.  АР2+РУС puts the legacy
    // palette sets, the 16-colour set and the monochrome pair back to
    // their power-up values (az_palette.v's reload), for a program that
    // left the palette in a state the BK's screen is unreadable in.
    // Both from mnano/bk.h's account of the AZ's keys; not checked
    // against MAXIOL's controller itself.
    if (hotkey == 2'd1 && scr_csr[2:1] == 2'b00) begin
        scr_csr[0]   <= ~scr_csr[0];
        scr_csr[7:6] <= scr_csr[0] ? scr_csr[7:6] - 2'd1 : scr_csr[7:6] + 2'd1;
    end
    if (wr_v) case (vreg)
        4'd0:  scr_csr <= din;
        4'd1:  pg[0] <= din[12:0];
        4'd2:  pal_cell <= din[8:0];
        4'd4:  pg[1] <= din[12:0];
        4'd5:  pg[2] <= din[12:0];
        4'd6:  vscrl[2] <= {5'd0, din[10:0]};
        4'd7:  vscrl[1] <= {5'd0, din[10:0]};
        4'd8:  vscrl[0] <= {5'd0, din[10:0]};
        4'd9:  hscrl[0] <= din[7:0];
        4'd10: hscrl[1] <= din[7:0];
        4'd11: hscrl[2] <= din[7:0];
        default: ;
    endcase
    // the BK-0011M's registers, as the controller intercepts them
    if (wr_662) begin
        legacy_pal <= din[11:8];
        pg[0]      <= din[15] ? 13'o034 : 13'd4;
        timer_bk   <= ~din[14];
    end
    if (wr_664) begin
        reg664   <= {6'd0, din[9], 1'b0, din[7:0]};
        vscrl[0] <= {8'd0, din[7:0]} - 16'o330;
        extended <= ~din[9];
    end
    if (cold) timer_bk <= 1'b0;

    // the interrupts
    if ((vcnt == 10'd769) && line_start) frame5 <= (frame5 == 3'd4) ? 3'd0 : frame5 + 3'd1;
    frame_end <= (vcnt == 10'd769) && line_start;
    // The AZ's 60 Hz is the frame: line 769, the end of the visible
    // part, as MAXIOL's controller raises it (thread 5556) - inside the
    // blanking, where a game's handler flips its pages.  For a few
    // hours on 23 Sep 2026 it waited for the blitter's automatic run
    // to end, on the reading that GID interrupts after executing the
    // packet; that put the flip mid-frame and was a wrong turn (see
    // frame_sync below and progress.md).
    if ((tick50 && (timer_bk || (az_v100 && az_50hz))) ||
        ((vcnt == 10'd769) && line_start && az_v100 && !az_50hz)) begin
        irq2 <= 1'b1;
        irq_hold <= 18'd129600;
    end else if (irq_hold != 18'd0) begin
        irq_hold <= irq_hold - 18'd1;
        if (irq_hold == 18'd1) irq2 <= 1'b0;
    end
end

// the palette: port A is the processor's
wire pal_we = wr_v && (vreg == 4'd3);
wire [14:0] pal_b_dout;
wire [8:0]  pal_b_adr;
az_palette pal (
    .clk(clk),
    .a_adr(pal_cell), .a_we(pal_we), .a_din(din[14:0]), .a_dout(pal_a_dout),
    .b_adr(pal_b_adr), .b_dout(pal_b_dout),
    .reload(hotkey == 2'd2)
);

//------------------------------------------------------------------------
// The mode, decoded, and its frame copy
//------------------------------------------------------------------------
wire [2:0] m_mode  = scr_csr[2:0];
wire [1:0] m_bsh   = scr_csr[1:0];          // bits per pixel: 1 << bsh
wire [1:0] m_llen  = scr_csr[4:3];          // words a line: 32 << llen
wire [1:0] m_xs    = scr_csr[7:6];          // pixel width: 1 << xs
wire [1:0] m_ys    = scr_csr[10:9];         // line height: 1 + ys
wire       m_sync  = scr_csr[11];
wire [3:0] m_roll  = scr_csr[15:12];

// the roll length in words, 6144 .. 262144: a table of the twelve
function [18:0] roll_words; input [3:0] n;
    case (n)
        4'd0: roll_words = 19'd6144;   4'd1: roll_words = 19'd8192;
        4'd2: roll_words = 19'd12288;  4'd3: roll_words = 19'd16384;
        4'd4: roll_words = 19'd24576;  4'd5: roll_words = 19'd32768;
        4'd6: roll_words = 19'd49152;  4'd7: roll_words = 19'd65536;
        4'd8: roll_words = 19'd98304;  4'd9: roll_words = 19'd131072;
        4'd10: roll_words = 19'd196608; default: roll_words = 19'd262144;
    endcase
endfunction

// captured for the frame at the last line before it
reg [2:0]  f_mode = 3'd0;
reg [1:0]  f_bsh = 2'd0, f_llen = 2'd0, f_xs = 2'd0, f_ys = 2'd0;
reg        f_sync = 1'b0;
reg [13:0] f_lines = 14'd0;             // roll length in lines (max 8192)
reg [3:0]  f_lpal = 4'd0;
reg        f_ext = 1'b0;
reg [12:0] f_pg [0:2];
reg [7:0]  f_hs [0:2];
initial begin f_pg[0] = 13'd0; f_pg[1] = 13'd0; f_pg[2] = 13'd0; f_hs[0] = 8'd0; f_hs[1] = 8'd0; f_hs[2] = 8'd0; end

wire [7:0] f_lmask = (f_llen == 2'd0) ? 8'h1f : (f_llen == 2'd1) ? 8'h3f : (f_llen == 2'd2) ? 8'h7f : 8'hff;
wire [2:0] layers  = (f_mode >= 3'd4) ? 3'd3 : 3'd1;

//------------------------------------------------------------------------
// The row counters: at the frame's start each is (scroll mod lines),
// found by subtracting in the vertical blanking; each steps every ys
// display lines.
//------------------------------------------------------------------------
reg [15:0] row [0:2];
reg [1:0]  ys_cnt = 2'd0;
reg        mod_run = 1'b0;
reg [1:0]  mod_l = 2'd0;
reg [15:0] mod_v = 16'd0;
reg [13:0] mod_lines = 14'd0;
initial begin row[0] = 16'd0; row[1] = 16'd0; row[2] = 16'd0; end

// the frame's parameters are taken at the start of line 768 (the first
// blank one), the modulo runs from there, and the row counters are set
// by line 805, when the first line's fetch starts
wire frame_prep = (vcnt == 10'd768) && line_start;
wire [18:0] roll_w = roll_words(m_roll);
wire [13:0] roll_lines = (m_llen == 2'd0) ? roll_w[18:5] : (m_llen == 2'd1) ? roll_w[18:6] :
                         (m_llen == 2'd2) ? roll_w[18:7] : roll_w[18:8];

always @(posedge clk) begin
    if (frame_prep) begin
        f_mode <= m_mode; f_bsh <= m_bsh; f_llen <= m_llen; f_xs <= m_xs; f_ys <= m_ys;
        f_sync <= m_sync; f_lines <= roll_lines; f_lpal <= legacy_pal; f_ext <= extended;
        f_pg[0] <= pg[0]; f_pg[1] <= pg[1]; f_pg[2] <= pg[2];
        f_hs[0] <= hscrl[0]; f_hs[1] <= hscrl[1]; f_hs[2] <= hscrl[2];
        mod_run <= 1'b1; mod_l <= 2'd0; mod_v <= vscrl[0]; mod_lines <= roll_lines;
        ys_cnt <= 2'd0;
    end else if (mod_run) begin
        if (mod_v >= {2'd0, mod_lines}) mod_v <= mod_v - {2'd0, mod_lines};
        else begin
            row[mod_l] <= mod_v;
            if (mod_l == 2'd2) mod_run <= 1'b0;
            else begin mod_l <= mod_l + 2'd1; mod_v <= (mod_l == 2'd0) ? vscrl[1] : vscrl[2]; end
        end
    end else if (line_start && vcnt < 10'd767) begin
        // the fetch about to start is for display line vcnt + 1: step
        // the source row when its ys lines are done.  (Line 0's row is
        // the frame's, set above; its fetch starts at line 805.)
        if (ys_cnt == f_ys) begin
            ys_cnt <= 2'd0;
            row[0] <= (row[0] + 16'd1 == {2'd0, f_lines}) ? 16'd0 : row[0] + 16'd1;
            row[1] <= (row[1] + 16'd1 == {2'd0, f_lines}) ? 16'd0 : row[1] + 16'd1;
            row[2] <= (row[2] + 16'd1 == {2'd0, f_lines}) ? 16'd0 : row[2] + 16'd1;
        end else
            ys_cnt <= ys_cnt + 2'd1;
    end
end

//------------------------------------------------------------------------
// The line fetch: at the start of every raster line, the next display
// line's words for each layer into the buffer the pipeline is not
// reading.  Buffer `fetch_buf` is being filled; the pipeline reads the
// other.  The row used is the one the counters will hold for that line
// (they step at the same line start, so the values one clock later are
// right; the fetch starts at hcnt 2).
//------------------------------------------------------------------------
reg        fetch_buf = 1'b0;             // the buffer being filled
reg        fetching = 1'b0;
reg [1:0]  fl = 2'd0;                    // layer
reg [4:0]  fb = 5'd0;                    // burst within the layer (llen/8)
reg [1:0]  fw = 2'd0;                    // word within the burst
reg [23:0] fetch_base = 24'd0;
reg        inflight = 1'b0;              // a burst was taken and its four words are still to come
reg [2:0]  drain = 3'd0;                 // words of a burst that straddled the line's end, to be dropped
reg [7:0]  lb_wadr = 8'd0;               // {burst, word} = word index / 2
wire [5:0] bursts_n = 6'd4 << f_llen;    // bursts in a row: 4, 8, 16, 32

// Only the visible window of a row is fetched (23 Sep 2026): the
// pipeline shows 1024 >> xs source pixels from the layer's scroll on,
// and at the game's x4 that is half of a 512-pixel row - the board's
// fetch did not finish its lines (the Debug page's "video" counters)
// with three layers of whole rows and the processor's cycles first in
// the arbiter.  The bursts run from the scroll's, as many as the width
// needs plus the misalignment, wrapping at the row's end; the buffer
// is indexed by the row's absolute word, so nothing else changes.
wire [9:0] vis_words = (10'd64 >> f_xs) << f_bsh;   // 16-bit words on the screen
reg  [5:0] fn = 6'd0, fn_need = 6'd1;    // bursts fetched of this layer, and how many it needs
function [5:0] need_bursts; input [7:0] hs; reg [9:0] w;
    begin
        w = {7'd0, hs[2:0]} + vis_words + 10'd7;
        need_bursts = (w[9:3] >= {1'b0, bursts_n}) ? bursts_n : w[8:3];
    end
endfunction
wire [7:0] hs_l0 = use_hs[0] & f_lmask;
wire [7:0] hs_ln = ((fl == 2'd0) ? use_hs[1] : use_hs[2]) & f_lmask;   // the next layer's
wire       last_burst = (fn == fn_need - 6'd1);

// the page and scroll used for a line: live, or the frame's when synced
wire [12:0] use_pg [0:2];
wire [7:0]  use_hs [0:2];
// The pages and scrolls are live unless bit 11 says otherwise - as
// GID (per line) and the hardware have them.  For a few hours on 23
// Sep 2026 they were latched at the frame's end under the 60 Hz mode,
// and Dangerous Dave, which double-buffers by switching its page set
// live and clearing the other set at once, showed the buffer it had
// just begun to clear for the rest of every frame after a switch: the
// "fixed wrong picture" of the tenth board report.  A flip must be
// immediate.
wire       frame_sync = f_sync;
assign use_pg[0] = frame_sync ? f_pg[0] : pg[0];
assign use_pg[1] = frame_sync ? f_pg[1] : pg[1];
assign use_pg[2] = frame_sync ? f_pg[2] : pg[2];
assign use_hs[0] = frame_sync ? f_hs[0] : hscrl[0];
assign use_hs[1] = frame_sync ? f_hs[1] : hscrl[1];
assign use_hs[2] = frame_sync ? f_hs[2] : hscrl[2];

// the row's word address: page << 11, plus row << (5 + llen)
wire [15:0] cur_row = row[fl];
wire [23:0] row_off = (f_llen == 2'd0) ? {3'd0, cur_row, 5'd0} : (f_llen == 2'd1) ? {2'd0, cur_row, 6'd0} :
                      (f_llen == 2'd2) ? {1'd0, cur_row, 7'd0} : {cur_row, 8'd0};
wire [23:0] layer_base = {use_pg[fl], 11'd0} + row_off;

// which display line is being fetched, and does it need any pixels
wire [9:0] next_line = (vcnt == 10'd805) ? 10'd0 : vcnt + 10'd1;
wire       next_vis  = (next_line < 10'd768);
reg  [2:0] lb_we = 3'd0;
reg  [31:0] lb_wdata = 32'd0;

always @(posedge clk) begin
    lb_we <= 3'd0;
    if (line_start) begin
        fetch_buf <= ~fetch_buf;
        fl <= 2'd0; fw <= 2'd0;
        fb <= hs_l0[7:3]; fn <= 6'd0; fn_need <= need_bursts(hs_l0);
        fetching <= next_vis && !mod_run;
        v_req <= 1'b0;
        inflight <= 1'b0;
        // A burst still in flight delivers its remaining words after the
        // switch.  Until 23 Sep 2026 they were written at the new line's
        // first positions and stepped the word counter, so the whole line
        // landed one burst to the right with the previous line's last
        // burst at its left edge - the first board's flickering band at
        // the left and its lines shifted by a burst wherever the fetch
        // ran close to the line's end under load.  They are dropped now.
        drain <= inflight ? (3'd4 - {1'b0, fw} - (v_dv ? 3'd1 : 3'd0)) : 3'd0;
    end else if (drain != 3'd0) begin
        if (v_dv) drain <= drain - 3'd1;
    end else if (fetching) begin
        if (!v_req && !inflight) begin
            // start a burst: the layer's base plus the burst's eight words
            v_adr <= layer_base[23:1] + {16'd0, fb, 2'b00};   // 32-bit words of the 32 MB: burst*4
            v_req <= 1'b1;
            fw <= 2'd0;
        end else if (v_take) begin
            v_req <= 1'b0;
            inflight <= 1'b1;            // the same burst was re-requested before (19 Sep 2026)
        end
        if (v_dv) begin
            lb_wdata <= v_rdata;
            lb_wadr  <= {fb, fw};
            lb_we    <= (fl == 2'd0) ? 3'b001 : (fl == 2'd1) ? 3'b010 : 3'b100;
            fw <= fw + 2'd1;
            if (fw == 2'd3) begin
                inflight <= 1'b0;
                if (last_burst) begin
                    if (fl == layers - 3'd1) fetching <= 1'b0;
                    else begin
                        fl <= fl + 2'd1;
                        fb <= hs_ln[7:3]; fn <= 6'd0; fn_need <= need_bursts(hs_ln);
                    end
                end else begin
                    fb <= (fb == bursts_n[4:0] - 5'd1) ? 5'd0 : fb + 5'd1;
                    fn <= fn + 6'd1;
                end
            end
        end
    end
end

// the buffers: two sets of three, 128 x 32 bits each (256 BK words)
reg [31:0] lb0a [0:127], lb1a [0:127], lb2a [0:127];
reg [31:0] lb0b [0:127], lb1b [0:127], lb2b [0:127];
wire [6:0] lb_widx = lb_wadr[6:0];
always @(posedge clk) begin
    if (lb_we[0] && !fetch_buf) lb0a[lb_widx] <= lb_wdata;
    if (lb_we[1] && !fetch_buf) lb1a[lb_widx] <= lb_wdata;
    if (lb_we[2] && !fetch_buf) lb2a[lb_widx] <= lb_wdata;
    if (lb_we[0] &&  fetch_buf) lb0b[lb_widx] <= lb_wdata;
    if (lb_we[1] &&  fetch_buf) lb1b[lb_widx] <= lb_wdata;
    if (lb_we[2] &&  fetch_buf) lb2b[lb_widx] <= lb_wdata;
end

//------------------------------------------------------------------------
// The pixel pipeline: stage 0 is combinational on hcnt, stages 1-3
// registers, stage 4 the palette RAM's own register, stage 5 the colour
// - five clocks from the counter to the output, so the syncs and the
// enable go through four registers to be written at the same edge.
//------------------------------------------------------------------------
// stage 0: the pixel's word and bit position, per layer
localparam integer PD = 4;
wire [10:0] px = hcnt + 11'd0;           // the pixel this clock computes
wire        px_vis = h_active && v_active;
wire [10:0] sx = px >> f_xs;             // the source pixel
wire [3:0]  ppw_sh = 4'd4 - {2'd0, f_bsh};
wire [7:0]  widx = sx[10:0] >> ppw_sh;   // the word (8 bits: at most 1024 pixels of 8 bpp = 512... masked below)
wire [3:0]  boff = (sx[3:0] & ((4'd1 << ppw_sh) - 4'd1)) << f_bsh;
wire [7:0]  ridx0 = (widx + use_hs[0]) & f_lmask;
wire [7:0]  ridx1 = (widx + use_hs[1]) & f_lmask;
wire [7:0]  ridx2 = (widx + use_hs[2]) & f_lmask;

// stage 1: the buffer reads (the buffer not being filled)
reg [31:0] w0 = 32'd0, w1 = 32'd0, w2 = 32'd0;
reg        h0 = 1'b0, h1 = 1'b0, h2 = 1'b0;
reg [3:0]  boff1 = 4'd0;
reg        vis1 = 1'b0;
always @(posedge clk) begin
    w0 <= fetch_buf ? lb0a[ridx0[7:1]] : lb0b[ridx0[7:1]];
    w1 <= fetch_buf ? lb1a[ridx1[7:1]] : lb1b[ridx1[7:1]];
    w2 <= fetch_buf ? lb2a[ridx2[7:1]] : lb2b[ridx2[7:1]];
    h0 <= ridx0[0]; h1 <= ridx1[0]; h2 <= ridx2[0];
    boff1 <= boff;
    vis1  <= px_vis;
end

// stage 2: the bits
wire [15:0] hw0 = h0 ? w0[31:16] : w0[15:0];
wire [15:0] hw1 = h1 ? w1[31:16] : w1[15:0];
wire [15:0] hw2 = h2 ? w2[31:16] : w2[15:0];
wire [7:0]  bmask = (f_bsh == 2'd0) ? 8'h01 : (f_bsh == 2'd1) ? 8'h03 : (f_bsh == 2'd2) ? 8'h0f : 8'hff;
reg  [7:0]  p0 = 8'd0, p1 = 8'd0, p2 = 8'd0;
reg         vis2 = 1'b0;
always @(posedge clk) begin
    p0 <= (hw0 >> boff1) & bmask;
    p1 <= (hw1 >> boff1) & bmask;
    p2 <= (hw2 >> boff1) & bmask;
    vis2 <= vis1;
end

// stage 3: the palette index, by the mode's rule (GID's MakeScreenLine)
reg [8:0] pidx = 9'd0;
reg       vis3 = 1'b0;
wire [3:0] lp1 = f_lpal + 4'd1;
wire [3:0] lp2 = f_lpal + 4'd2;
always @(posedge clk) begin
    vis3 <= vis2;
    case (f_mode)
        3'd0: pidx <= 9'd336 + {8'd0, p0[0]};
        3'd1: pidx <= 9'd256 + {3'd0, f_lpal, 2'd0} + {7'd0, p0[1:0]};
        3'd2: pidx <= 9'd320 + {5'd0, p0[3:0]};
        3'd3: pidx <= {1'b0, p0};
        3'd4: pidx <= {6'd0, p0[0], p1[0], p2[0]};
        3'd5: pidx <= (p0[1:0] != 2'd0) ? 9'd256 + {3'd0, f_lpal, 2'd0} + {7'd0, p0[1:0]} :
                      (p1[1:0] != 2'd0) ? 9'd256 + {3'd0, lp1, 2'd0} + {7'd0, p1[1:0]} :
                                          9'd256 + {3'd0, lp2, 2'd0} + {7'd0, p2[1:0]};
        3'd6: pidx <= (p0[3:0] != 4'd0) ? {5'd0, p0[3:0]} :
                      (p1[3:0] != 4'd0) ? 9'd16 + {5'd0, p1[3:0]} : 9'd32 + {5'd0, p2[3:0]};
        default: pidx <= (p0 != 8'd0) ? {1'b0, p0} : (p1 != 8'd0) ? {1'b0, p1} : {1'b0, p2};
    endcase
end

// stage 4: the palette RAM (registered inside); stage 5: the colour
assign pal_b_adr = pidx;
reg vis4 = 1'b0;
always @(posedge clk) vis4 <= vis3;

// the syncs and the enable, delayed to match
reg [PD-1:0] hs_d = 0, vs_d = 0, de_d = 0;
reg [9:0] vline_d [0:PD-1];
reg [10:0] hline_d [0:PD-1];
integer k;
initial for (k = 0; k < PD; k = k + 1) begin vline_d[k] = 10'd0; hline_d[k] = 11'd0; end
always @(posedge clk) begin
    hs_d <= {hs_d[PD-2:0], hs_raw};
    vs_d <= {vs_d[PD-2:0], vs_raw};
    de_d <= {de_d[PD-2:0], px_vis};
    vline_d[0] <= vcnt;
    hline_d[0] <= hcnt;
    for (k = 1; k < PD; k = k + 1) begin vline_d[k] <= vline_d[k-1]; hline_d[k] <= hline_d[k-1]; end
end


wire black = f_ext && (vline_d[PD-1] > 10'd192);
always @(posedge clk) begin
    hs <= hs_d[PD-1];
    vs <= vs_d[PD-1];
    de <= de_d[PD-1];
    if (de_d[PD-1] && !black) begin
        r <= {pal_b_dout[14:10], pal_b_dout[14:12]};
        g <= {pal_b_dout[9:5],   pal_b_dout[9:7]};
        b <= {pal_b_dout[4:0],   pal_b_dout[4:2]};
    end else begin
        r <= 8'd0; g <= 8'd0; b <= 8'd0;
    end
end

endmodule

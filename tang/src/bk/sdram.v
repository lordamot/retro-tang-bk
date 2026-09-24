`timescale 1ns / 1ps
//========================================================================
// sdram.v - the AZBK's 32 MB, in the Tang Nano 20K's 8 MB SDRAM.
//
// One clock, 64.8 MHz (top.v), and one controller with a fixed-priority
// arbiter in front of it.  Five ports:
//
//   v  the display's line fetch  - bursts of four 32-bit words (eight
//                                  BK words), highest priority, so a
//                                  line is always in its buffer in time
//   c  the processor             - one 16-bit word, read or write with
//                                  byte lanes; it waits for nobody but v
//   b  the blitter               - one word, read or write with lanes
//   d  the DMA sound             - one 32-bit word read
//   p  the MCU's poke/peek       - one byte write, one 32-bit read
//   and the refresh, taken when it is due and nothing is in flight, or
//   forced when it is a quarter overdue.
//
// The chip is 2M x 32 (4 banks, 2048 rows, 256 columns), CAS latency 2,
// read burst of four, single writes (mode register bit 9).  A cycle is
// ACTIVE, then READ or WRITE with A10 set (auto-precharge) two clocks
// later; a read's four words are on the bus from the second clock after
// the READ, captured on the fourth to seventh clock of the cycle, and the
// next ACTIVE may go out on the tenth (tRP after the burst's own
// precharge).  A write is six clocks (tWR + tRP from the WRITE).  Every
// figure is the ZS-256 Nano controller's arithmetic at 15.43 ns a clock
// instead of 23.8: the chip is clocked by the PLL's copy 90 degrees
// behind ours, so it takes a command a quarter period after we put it
// out, and with CL2 the first word is on the bus from tAC after its next
// edge, half way into our second clock after the READ, until tOH after
// the one following.  The edge ending that clock is inside the window
// with margin both ways; the power-up self-test moves the capture a clock
// later if a board says otherwise (cap_late), exactly as the siblings do.
//
// Addresses are 32-bit words.  The ports give the AZBK's whole 32 MB
// (23 bits: addr[23:1] of the 24-bit BK-word address, the half by
// addr[0]); the chip has 8 MB (21 bits: a[20:19] the bank, a[18:8] the
// row, a[7:0] the column).  Between them a page table (23 Sep 2026):
// the space's 8192 pages of 4 KB map onto the chip's 2048, the first
// 128 (the БК's own memory, the ROMs, the logo: bytes 0-0x7FFFF) one
// to one, the rest given a physical page at the first write, in order,
// from 128 up; a read of a page never written answers zeros without
// a memory cycle.  Until then the upper 24 MB aliased onto the 8 MB,
// and Dangerous Dave, which keeps one of its two page sets at 13 MB,
// had its sky layer and its backdrop in the same memory.  When the
// 2048 run out the count wraps to 128: aliasing again, for software
// that touches more than 7.5 MB.  The table is cleared at power-up
// and by the AZ's cold reset; a translation costs a cycle two clocks.
//
// Refresh: 4096 rows in 64 ms, one every 15.6 us = 1012 clocks; counted
// as due every 1000 and taken between cycles.
//========================================================================
module sdram (
    input             clk,
    input             lock,         // the PLL has locked
    output            init,         // the memory is initialised and tested
    input             clear,        // the AZ's cold reset: the page table starts afresh
    output reg [10:0] alloc_next,   // the next physical page to be given out (pages used = this - 128), for the debug window
    output reg [4:0]  alloc_wraps,  // times the count ran past 2047 and started again at 128 (aliasing since)

    // v: the display, burst reads of four 32-bit words (a[1:0] ignored)
    input             v_req,
    input      [22:0] v_adr,
    output            v_take,       // one clock: the burst is starting
    output reg        v_dv,         // one clock a word, four times
    output reg [31:0] v_rdata,

    // c: the processor, one 32-bit word with byte lanes
    input             c_req,
    input             c_we,
    input      [22:0] c_adr,
    input      [31:0] c_wdata,
    input      [3:0]  c_wmask,
    output            c_take,
    output reg        c_ack,        // one clock, with c_rdata on a read
    output reg [31:0] c_rdata,

    // b: the blitter
    input             b_req,
    input             b_we,
    input      [22:0] b_adr,
    input      [31:0] b_wdata,
    input      [3:0]  b_wmask,
    output            b_take,
    output reg        b_ack,
    output reg [31:0] b_rdata,

    // d: the DMA sound, reads only
    input             d_req,
    input      [22:0] d_adr,
    output            d_take,
    output reg        d_ack,
    output reg [31:0] d_rdata,

    // p: the MCU, a byte write or a word read
    input             p_req,
    input             p_we,
    input      [22:0] p_adr,
    input      [31:0] p_wdata,
    input      [3:0]  p_wmask,
    output            p_take,
    output reg        p_ack,
    output reg [31:0] p_rdata,

    // the self-test's verdict
    output reg        bist_done,
    output reg        bist_fail,
    output reg [3:0]  phase,        // the SDRAM clock's phase (sys_pll.v's psda): swept at power-up
    output reg [15:0] ok_early,     // which of the sixteen passed the self-test with the early capture
    output reg [15:0] ok_late,      // ...and with the late one
    output reg [7:0]  last_rd,      // the low byte of the last self-test read (the pattern's is F0)
    output reg        cap_late,

    // the chip
    output reg [10:0] SDRAM_A,
    output reg [1:0]  SDRAM_BA,
    inout      [31:0] SDRAM_DQ,
    output            SDRAM_nCS,
    output            SDRAM_nRAS,
    output            SDRAM_nCAS,
    output            SDRAM_nWE,
    output reg [3:0]  SDRAM_DQM
);

localparam [3:0] CMD_INHIBIT      = 4'b1111;
localparam [3:0] CMD_NOP          = 4'b0111;
localparam [3:0] CMD_ACTIVE       = 4'b0011;
localparam [3:0] CMD_READ         = 4'b0101;
localparam [3:0] CMD_WRITE        = 4'b0100;
localparam [3:0] CMD_PRECHARGE    = 4'b0010;
localparam [3:0] CMD_AUTO_REFRESH = 4'b0001;
localparam [3:0] CMD_LOAD_MODE    = 4'b0000;

// Mode register: single writes (bit 9), CAS latency 2, sequential,
// burst length 4.
localparam [10:0] MODE = 11'b0_1_00_010_0_010;

reg  [3:0] cmd = CMD_INHIBIT;
assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd;

reg  [31:0] dq_out = 32'd0;
reg         dq_oe  = 1'b0;
assign SDRAM_DQ = dq_oe ? dq_out : 32'hZZZZZZZZ;

// the bus, registered once on our side before anything looks at it
reg  [31:0] dq_in = 32'd0;
always @(posedge clk) dq_in <= SDRAM_DQ;

//------------------------------------------------------------------------
// Power-up: 65536 clocks of NOP after PLL lock, then the JEDEC steps.
//------------------------------------------------------------------------
reg  [15:0] settle  = 16'd0;
reg  [5:0]  istep   = 6'd0;
reg         started = 1'b0;
wire        running = started && (istep == 6'd0);
assign init = running && bist_done && !bist_fail;

//------------------------------------------------------------------------
// Refresh, kept as a count of those due
//------------------------------------------------------------------------
reg  [9:0] ref_cnt = 10'd0;
reg  [2:0] ref_due = 3'd0;

//------------------------------------------------------------------------
// The cycle in flight: who, what, where.
//------------------------------------------------------------------------
localparam [2:0] P_NONE = 3'd0, P_V = 3'd1, P_C = 3'd2, P_B = 3'd3,
                 P_D = 3'd4, P_P = 3'd5, P_REF = 3'd6, P_BIST = 3'd7;

reg  [2:0]  who      = P_NONE;
reg  [3:0]  t        = 4'd0;      // clock within the cycle
reg         act_we   = 1'b0;
reg         act_burst= 1'b0;
reg  [20:0] act_adr  = 21'd0;     // the physical address
reg  [22:0] act_vadr = 23'd0;     // the port's (the space's)

// the page table: {mapped, physical page}; read on port B at a pick,
// written on port A by the clearing sweep or an allocation
reg  [11:0] pt [0:8191];
reg  [11:0] pt_q = 12'd0;
reg  [12:0] pt_radr = 13'd0;
reg         pt_we = 1'b0;
reg  [12:0] pt_wadr = 13'd0;
reg  [11:0] pt_wdata = 12'd0;
reg         clr_run = 1'b1;       // the sweep: at power-up, and on `clear`
reg  [12:0] clr_adr = 13'd0;
reg  [1:0]  xl_st = 2'd0;         // the translation: 1 the table read issued, 2 its word in
reg  [2:0]  zero_left = 3'd0;     // words of zeros still owed to a read of a page never written
initial begin alloc_next = 11'd128; alloc_wraps = 5'd0; end
always @(posedge clk) begin
    pt_q <= pt[pt_radr];
    if (clr_run) begin
        pt[clr_adr] <= 12'd0;
        clr_adr <= clr_adr + 13'd1;
        if (clr_adr == 13'd8191) clr_run <= 1'b0;
    end else if (pt_we)
        pt[pt_wadr] <= pt_wdata;
    if (clear && !clr_run) begin clr_run <= 1'b1; clr_adr <= 13'd0; end
end
wire        fixed = (act_vadr[22:17] == 6'd0);          // pages 0-127: one to one
wire [20:0] phys_mapped = fixed ? act_vadr[20:0] : {pt_q[10:0], act_vadr[9:0]};
wire [20:0] phys_new    = {alloc_next, act_vadr[9:0]};
reg  [31:0] act_data = 32'd0;
reg  [3:0]  act_mask = 4'd0;
reg  [1:0]  bcnt     = 2'd0;      // burst word delivered

wire idle = (who == P_NONE);

// the self-test: four words at the top of the first 64 KB, all lanes,
// written then read back in the same order
reg         bist_run = 1'b0;
reg         bist_rd  = 1'b0;
reg  [1:0]  bist_i   = 2'd0;
reg         bist_bad = 1'b0;
reg         bist_pend = 1'b0;     // a self-test access is in flight
reg  [31:0] bist_rdata = 32'd0;
wire [20:0] bist_adr = {7'd0, 12'h3FF, bist_i};

// The phase sweep (19 Sep 2026): the chip is clocked by the PLL's copy
// psda/16 of a period behind ours, and which fraction leaves the
// board's setup and hold happy is a property of the board, not of the
// arithmetic - 90 degrees was the siblings' at 42 MHz and failed here at
// 64.8.  So every phase is tried in turn at power-up, the self-test run
// at each with the early capture and then with the late one, each
// result noted in its own mask (ok_early, ok_late - the first board,
// 22 Sep 2026, passed at 5-7 and 10-15 and one mask could not say
// which capture either window belonged to, so the choice could have
// sat on a capture's edge), and the middle of the longest passing run
// of either mask chosen, capture and phase, for the final
// initialisation.  About 3 ms in all.  No pass at any phase and either
// capture is the failure the LEDs and the strip show.
reg  [4:0]  tries = 5'd0;          // phases tried, 0..16
reg         final_run = 1'b0;      // the run at the chosen phase
reg         final_other = 1'b0;    // ...which has fallen back to the other capture
initial begin phase = 4'd6; ok_early = 16'd0; ok_late = 16'd0; last_rd = 8'd0; end

// the choice: a walk of 32 steps round each mask's sixteen bits twice
// (so a run across 15-0 counts whole), the early mask then the late,
// keeping the longest run's end and mask; the middle of that run is
// the phase.  Sequential, so nothing deep.
reg        scan_go = 1'b0, scan_busy = 1'b0, scan_done = 1'b0;
reg [5:0]  scan_k = 6'd0;
reg [4:0]  scan_run = 5'd0, scan_best = 5'd0, scan_end = 5'd0;
reg        scan_cap = 1'b0;
reg [3:0]  best = 4'd6;
reg        best_cap = 1'b0;
wire       scan_bit = scan_k[5] ? ok_late[scan_k[3:0]] : ok_early[scan_k[3:0]];
always @(posedge clk) begin
    scan_done <= 1'b0;
    if (scan_go) begin
        scan_busy <= 1'b1; scan_k <= 6'd0; scan_run <= 5'd0; scan_best <= 5'd0; scan_end <= 5'd0; scan_cap <= 1'b0;
    end else if (scan_busy) begin
        if (scan_bit) begin
            if (scan_run != 5'd16) scan_run <= scan_run + 5'd1;
            if (scan_run + 5'd1 > scan_best && scan_run != 5'd16) begin
                scan_best <= scan_run + 5'd1; scan_end <= scan_k[4:0]; scan_cap <= scan_k[5];
            end
        end else
            scan_run <= 5'd0;
        if (scan_k[4:0] == 5'd31) scan_run <= 5'd0;    // the other mask's walk starts afresh
        scan_k <= scan_k + 6'd1;
        if (scan_k == 6'd63) begin
            scan_busy <= 1'b0; scan_done <= 1'b1;
            best <= scan_end[3:0] - scan_best[4:1];   // the end less half the length, modulo 16
            best_cap <= scan_cap;
        end
    end
end
// the last read of a round has just landed: did the round pass?
wire pass = !(bist_bad || bist_rdata != bist_pat);
reg  [31:0] bist_pat;
always @(*) case (bist_i)
    2'd0: bist_pat = 32'h55AA_1234;
    2'd1: bist_pat = 32'hAA55_5678;
    2'd2: bist_pat = 32'h5A5A_9ABC;
    2'd3: bist_pat = 32'hA5A5_DEF0;
endcase

// who goes next, decided while idle; refresh forced when overdue
wire ref_force = (ref_due >= 3'd2);
wire pick_ref  = ref_force || (ref_due != 3'd0 && !v_req && !c_req && !b_req && !d_req && !p_req && !bist_run);
wire [2:0] pick = !running ? P_NONE :
                  pick_ref  ? P_REF  :
                  bist_run  ? P_BIST :
                  c_req     ? P_C    :     // the processor first: one access a few of its clocks, and a
                  v_req     ? P_V    :     // 60-clock timeout; the video has the whole line for its bursts
                  d_req     ? P_D    :     // (19 Sep 2026: with the video first the processor starved)
                  b_req     ? P_B    :
                  p_req     ? P_P    : P_NONE;

assign v_take = idle && (pick == P_V);
assign c_take = idle && (pick == P_C);
assign b_take = idle && (pick == P_B);
assign d_take = idle && (pick == P_D);
assign p_take = idle && (pick == P_P);

// the capture clocks: word n of a read burst on cycle clock 4+n, or 5+n
// when the board said so
wire [3:0] cap0 = cap_late ? 4'd4 : 4'd3;

always @(posedge clk) begin
    cmd       <= CMD_NOP;
    pt_we     <= 1'b0;
    dq_oe     <= 1'b0;
    SDRAM_DQM <= 4'b1111;
    v_dv  <= 1'b0; c_ack <= 1'b0; b_ack <= 1'b0; d_ack <= 1'b0; p_ack <= 1'b0;

    scan_go <= 1'b0;
    if (clear && !clr_run) begin alloc_next <= 11'd128; alloc_wraps <= 5'd0; end
    if (!lock) begin
        settle  <= 16'd0;
        istep   <= 6'd63;
        started <= 1'b0;
        cmd     <= CMD_INHIBIT;
        ref_due <= 3'd0;
        ref_cnt <= 10'd0;
        who     <= P_NONE;
        t       <= 4'd0;
        xl_st   <= 2'd0; zero_left <= 3'd0;
        alloc_next <= 11'd128; alloc_wraps <= 5'd0;
        bist_run <= 1'b0; bist_rd <= 1'b0; bist_i <= 2'd0; bist_bad <= 1'b0; bist_pend <= 1'b0;
        bist_done <= 1'b0; bist_fail <= 1'b0; cap_late <= 1'b0;
        phase <= 4'd6; ok_early <= 16'd0; ok_late <= 16'd0; tries <= 5'd0; final_run <= 1'b0; final_other <= 1'b0;
    end else if (!started) begin
        if (scan_go || scan_busy) ;                       // the phase choice in flight
        else if (scan_done) begin phase <= best; cap_late <= best_cap; end
        else if (&settle) begin started <= 1'b1; istep <= 6'd63; end
        else settle <= settle + 16'd1;
        SDRAM_A  <= 11'd0;
        SDRAM_BA <= 2'd0;
    end else if (istep != 6'd0) begin
        // the JEDEC steps, eight clocks apart
        istep <= istep - 6'd1;
        case (istep)
            6'd48: begin cmd <= CMD_PRECHARGE; SDRAM_A <= 11'b100_0000_0000; end
            6'd40: cmd <= CMD_AUTO_REFRESH;
            6'd32: cmd <= CMD_AUTO_REFRESH;
            6'd24: cmd <= CMD_AUTO_REFRESH;
            6'd16: begin cmd <= CMD_LOAD_MODE; SDRAM_A <= MODE; end
            default: ;
        endcase
        if (istep == 6'd1) bist_run <= 1'b1;
    end else begin
        //----------------------------------------------------------------
        // Running.
        //----------------------------------------------------------------
        if (ref_cnt == 10'd999) begin
            ref_cnt <= 10'd0;
            if (ref_due != 3'd7) ref_due <= ref_due + 3'd1;
        end else
            ref_cnt <= ref_cnt + 10'd1;

        if (idle) begin
            t <= 4'd0;
            who <= pick;
            case (pick)
            P_REF: begin
                cmd <= CMD_AUTO_REFRESH;
                ref_due <= ref_due - 3'd1;
            end
            P_BIST: begin
                act_we <= ~bist_rd; act_burst <= 1'b0; act_adr <= bist_adr;
                act_data <= bist_pat; act_mask <= 4'b1111;
                SDRAM_BA <= bist_adr[20:19]; SDRAM_A <= bist_adr[18:8];
                cmd <= CMD_ACTIVE;
                bist_pend <= 1'b1;
            end
            // the ports: the space's address, translated over the next two clocks
            P_V: begin
                act_we <= 1'b0; act_burst <= 1'b1; act_vadr <= {v_adr[22:2], 2'b00};
                pt_radr <= v_adr[22:10]; xl_st <= 2'd1;
            end
            P_C: begin
                act_we <= c_we; act_burst <= 1'b0; act_vadr <= c_adr;
                act_data <= c_wdata; act_mask <= c_wmask;
                pt_radr <= c_adr[22:10]; xl_st <= 2'd1;
            end
            P_B: begin
                act_we <= b_we; act_burst <= 1'b0; act_vadr <= b_adr;
                act_data <= b_wdata; act_mask <= b_wmask;
                pt_radr <= b_adr[22:10]; xl_st <= 2'd1;
            end
            P_D: begin
                act_we <= 1'b0; act_burst <= 1'b0; act_vadr <= d_adr;
                pt_radr <= d_adr[22:10]; xl_st <= 2'd1;
            end
            P_P: begin
                act_we <= p_we; act_burst <= 1'b0; act_vadr <= p_adr;
                act_data <= p_wdata; act_mask <= p_wmask;
                pt_radr <= p_adr[22:10]; xl_st <= 2'd1;
            end
            default: ;
            endcase
            bcnt <= 2'd0;
        end else if (xl_st == 2'd1) begin
            xl_st <= 2'd2;                                    // pt_q lands at this edge
        end else if (xl_st == 2'd2 && clr_run && !fixed) begin
            // the table is being cleared (a cold reset): a translated page
            // waits for it; the fixed pages go on, so the ROMs arriving
            // over the link meanwhile (16 bytes of queue, one every 26
            // clocks) are not dropped - the first build of this lost them
            pt_radr <= act_vadr[22:10];
        end else if (xl_st == 2'd2) begin
            xl_st <= 2'd0;
            t <= 4'd0;
            if (fixed || pt_q[11]) begin
                act_adr <= phys_mapped;
                SDRAM_BA <= phys_mapped[20:19]; SDRAM_A <= phys_mapped[18:8];
                cmd <= CMD_ACTIVE;
            end else if (act_we) begin
                // the page's first write: it gets the next physical page
                pt_we <= 1'b1; pt_wadr <= act_vadr[22:10]; pt_wdata <= {1'b1, alloc_next};
                alloc_next <= (alloc_next == 11'd2047) ? 11'd128 : alloc_next + 11'd1;
                if (alloc_next == 11'd2047 && alloc_wraps != 5'd31) alloc_wraps <= alloc_wraps + 5'd1;
                act_adr <= phys_new;
                SDRAM_BA <= phys_new[20:19]; SDRAM_A <= phys_new[18:8];
                cmd <= CMD_ACTIVE;
            end else begin
                // a read of a page never written: zeros, no cycle
                case (who)
                    P_V: zero_left <= 3'd4;
                    P_C: begin c_rdata <= 32'd0; c_ack <= 1'b1; who <= P_NONE; end
                    P_B: begin b_rdata <= 32'd0; b_ack <= 1'b1; who <= P_NONE; end
                    P_D: begin d_rdata <= 32'd0; d_ack <= 1'b1; who <= P_NONE; end
                    P_P: begin p_rdata <= 32'd0; p_ack <= 1'b1; who <= P_NONE; end
                    default: who <= P_NONE;
                endcase
            end
        end else if (zero_left != 3'd0) begin
            v_rdata <= 32'd0; v_dv <= 1'b1;
            zero_left <= zero_left - 3'd1;
            if (zero_left == 3'd1) who <= P_NONE;
        end else begin
            t <= t + 4'd1;
            if (who == P_REF) begin
                // tRFC: seven clocks, then free
                if (t == 4'd6) who <= P_NONE;
            end else begin
                // column with auto-precharge at clock 2
                if (t == 4'd1) begin
                    SDRAM_A  <= {1'b1, 2'b00, act_adr[7:0]};
                    SDRAM_BA <= act_adr[20:19];
                    if (act_we) begin
                        cmd       <= CMD_WRITE;
                        dq_out    <= act_data;
                        dq_oe     <= 1'b1;
                        SDRAM_DQM <= ~act_mask;
                    end else begin
                        cmd       <= CMD_READ;
                        SDRAM_DQM <= 4'b0000;
                    end
                end
                // a read's DQM has two clocks of latency and the burst
                // is four words long: low from the READ for four clocks
                if (!act_we && (t == 4'd2 || t == 4'd3 || t == 4'd4)) SDRAM_DQM <= 4'b0000;
                if (t == 4'd2 && act_we) dq_oe <= 1'b1;

                if (act_we) begin
                    // written: tWR + tRP from the WRITE, then free
                    if (t == 4'd2) begin
                        case (who)
                            P_C: c_ack <= 1'b1;
                            P_B: b_ack <= 1'b1;
                            P_P: p_ack <= 1'b1;
                            default: ;
                        endcase
                    end
                    if (t == 4'd5) begin who <= P_NONE; bist_pend <= 1'b0; end
                end else begin
                    // read: the words are in dq_in one clock after they
                    // were on the bus, i.e. dq_in holds word n at t == cap0+1+n
                    if (t == cap0 + 4'd1) begin
                        case (who)
                            P_V: begin v_rdata <= dq_in; v_dv <= 1'b1; end
                            P_C: begin c_rdata <= dq_in; c_ack <= 1'b1; end
                            P_B: begin b_rdata <= dq_in; b_ack <= 1'b1; end
                            P_D: begin d_rdata <= dq_in; d_ack <= 1'b1; end
                            P_P: begin p_rdata <= dq_in; p_ack <= 1'b1; end
                            P_BIST: bist_rdata <= dq_in;
                            default: ;
                        endcase
                    end
                    if (act_burst && (t == cap0 + 4'd2 || t == cap0 + 4'd3 || t == cap0 + 4'd4)) begin
                        v_rdata <= dq_in; v_dv <= 1'b1;
                    end
                    // the burst's own precharge begins after its last
                    // word (clock 8 of the cycle, 9 when late); tRP
                    // later the next ACTIVE may go out
                    if (t == (cap_late ? 4'd10 : 4'd9)) begin who <= P_NONE; bist_pend <= 1'b0; end
                end
            end
        end

        //----------------------------------------------------------------
        // The self-test: one access at a time, advanced as each ends.
        //----------------------------------------------------------------
        if (bist_run && bist_pend && ((act_we && t == 4'd5) || (!act_we && t == (cap_late ? 4'd10 : 4'd9)))) begin
            if (bist_rd && bist_rdata != bist_pat) bist_bad <= 1'b1;
            if (bist_rd) last_rd <= bist_rdata[7:0];
            bist_i <= bist_i + 2'd1;
            if (bist_i == 2'd3) begin
                if (!bist_rd)
                    bist_rd <= 1'b1;
                else begin
                    bist_rd <= 1'b0;
                    bist_bad <= 1'b0;
                    if (final_run) begin
                        // the run at the chosen phase and capture: a pass
                        // is init; a failure tries the other capture once
                        if (pass) begin
                            bist_run <= 1'b0; bist_done <= 1'b1;
                        end else if (!final_other) begin
                            final_other <= 1'b1; cap_late <= ~cap_late;
                        end else begin
                            bist_run <= 1'b0; bist_done <= 1'b1; bist_fail <= 1'b1;
                        end
                    end else if (!cap_late) begin
                        // the sweep: the early capture's round is in, the
                        // late one's follows at the same phase
                        ok_early[phase] <= pass;
                        cap_late <= 1'b1;
                    end else begin
                        // ...and the late one's: the next phase, or the choice
                        ok_late[phase] <= pass;
                        cap_late <= 1'b0;
                        bist_run <= 1'b0;
                        started <= 1'b0; settle <= 16'hF000;          // 4096 clocks, then the JEDEC steps again
                        if (tries == 5'd15) begin
                            final_run <= 1'b1;
                            if (ok_early == 16'd0 && ok_late == 16'd0 && !pass) begin
                                // nothing passed: say so at once
                                started <= 1'b1; istep <= 6'd0;
                                bist_done <= 1'b1; bist_fail <= 1'b1;
                            end else
                                scan_go <= 1'b1;
                        end else
                            phase <= phase + 4'd1;
                        tries <= tries + 5'd1;
                    end
                end
            end
        end
    end
end

endmodule

`timescale 1ns / 1ps
//========================================================================
// azblit.v - the AZBK's blitter.
//
// A robot that reads a packet of eight-word commands out of a page of
// the memory and executes them, one after the other, either when the
// visible frame ends (line 769) or when told to (bit 12 of 177270 with
// bit 14 set).  177270 holds the command count (0 stops everything),
// the manual/automatic bit (14), the manual start (12, write-only), the
// busy flag (15, read-only) and the "packet being read" flag (9,
// read-only); 177272 the page the packet starts at.  The command words
// and the six operations are MAXIOL's description for firmware 19
// ("Блиттер"), the byte-lane arithmetic is the hardware's own snippet
// there, and the mirroring and the Y word are as GID's AZ_Blitter reads
// them (AZBK_Blitter.cpp, whose structure this follows step for step).
//
// Words, not bytes: the blitter moves 16-bit words, and the two
// overlay operations mask each byte of the write by its own test, so
// that an 8-bit-per-pixel sprite lands pixel by pixel.  The command
// packet is read whole into a buffer first (bit 9 up meanwhile), so the
// page can be rewritten as soon as it drops; then each command walks
// height rows of width words, reading SRC and/or DST as its flags say,
// and writing DST (or SRC for the background save).
//
// The memory port is sdram.v's blitter port, below the processor in
// priority: a word costs a read cycle (ten clocks) or a write (six), so
// a 60 x 60 sprite copy is about two milliseconds - less than the real
// controller, which is a matter of bandwidth, not of behaviour.
//========================================================================
module azblit (
    input             clk,
    input             cold,

    // the bus: 177270, 177272
    input             sync,
    input      [15:0] adr,
    input             stb,
    input             we,
    input      [15:0] din,
    output     [15:0] dout,
    output            ack,
    input             wr_stb,

    input             frame_end,    // one clock at line 769

    // the memory
    output reg        b_req,
    output reg        b_we,
    output reg [22:0] b_adr,
    output reg [31:0] b_wdata,
    output reg [3:0]  b_wmask,
    input             b_take,
    input             b_ack,
    input      [31:0] b_rdata
);

localparam B_RUN = 15, B_MANUAL = 14, B_START = 12, B_READCMD = 9;

reg [8:0]  cmd_count = 9'd0;
reg        manual = 1'b0;
reg [12:0] cmd_page = 13'd0;
reg        running = 1'b0;
reg        reading = 1'b0;

wire sel270 = sync && (adr[15:1] == (16'o177270 >> 1));
wire sel272 = sync && (adr[15:1] == (16'o177272 >> 1));
assign dout = sel270 ? {running, manual, 4'd0, reading, cmd_count} : sel272 ? {3'd0, cmd_page} : 16'd0;
assign ack  = stb && (sel270 || sel272);

wire wr270 = wr_stb && sel270;
wire wr272 = wr_stb && sel272;

// the command buffer: 511 x 8 words
reg [15:0] cbuf [0:4095];
reg [11:0] cb_wadr = 12'd0;
reg [15:0] cb_rdata = 16'd0;
reg [11:0] cb_radr = 12'd0;
reg        cb_we = 1'b0;
reg [15:0] cb_wdata = 16'd0;
always @(posedge clk) begin
    if (cb_we) cbuf[cb_wadr] <= cb_wdata;
    cb_rdata <= cbuf[cb_radr];
end

//------------------------------------------------------------------------
// The machine
//------------------------------------------------------------------------
localparam [3:0] S_IDLE = 4'd0, S_LOAD = 4'd1, S_LOAD_W = 4'd2,
                 S_FETCH = 4'd3, S_FETCH_W = 4'd4, S_PARSE = 4'd5,
                 S_RSRC = 4'd6, S_RSRC_W = 4'd7, S_RDST = 4'd8, S_RDST_W = 4'd9,
                 S_EXEC = 4'd10, S_WRITE = 4'd11, S_WRITE_W = 4'd12, S_STEP = 4'd13;
reg [3:0]  st = S_IDLE;

reg [8:0]  n_cmd = 9'd0;         // commands in this packet
reg [8:0]  i_cmd = 9'd0;         // the current one
reg [12:0] load_cnt = 13'd0;     // words loaded (n_cmd * 8)
reg [23:0] load_adr = 24'd0;     // word address in memory
reg [2:0]  f_w = 3'd0;           // word of the command being fetched
reg [15:0] c [0:7];              // the command's eight words

// the parsed command
wire [23:0] c_src = {c[0][15:8], c[1]};
wire [23:0] c_dst = {c[0][7:0], c[2]};
wire [15:0] c_cmd = c[3];
wire        c_rdsrc = c_cmd[0], c_rddst = c_cmd[1], c_nop = c_cmd[2];
wire [2:0]  c_op = c_cmd[5:3];
wire        c_swap = c_cmd[6], c_mirh = c_cmd[9], c_mirv = c_cmd[10];
wire [8:0]  c_width = {1'b0, c[4][7:0]} + 9'd1;
// the row count: a byte, and 0 rows is nothing, as GID's AZ_Blitter
// has it.  For a few hours on 23 Sep 2026 a 0 was 256 rows, on the
// reading that a whole 256-row layer must be copied in one command;
// the flicker it was meant to cure was the memory's aliasing, and
// the change made a command a game disables by zeroing its rows
// write 256 of them - the blitter's longest run grew from 1412 lines
// to 1909 with the same game, and the game stopped at random points.
wire [8:0]  c_height = {1'b0, c[4][15:8]};
wire [8:0]  c_pitch = {1'b0, c[5][7:0]} - 9'd1;     // signed, -1..254
wire [23:0] c_yadd = {c[6], 8'd0};
wire [7:0]  c_sconst = c[7][7:0];
wire [7:0]  c_dconst = c[7][15:8];

// the walk
reg [23:0] a_dst = 24'd0, a_src = 24'd0;
reg [8:0]  w_left = 9'd0;
reg [8:0]  h_left = 9'd0;
reg [15:0] s_val = 16'd0, d_val = 16'd0;
reg [15:0] out_val = 16'd0;
reg [1:0]  out_mask = 2'd0;      // the two bytes to write
reg        to_src = 1'b0;        // the write goes to SRC (op 4)
wire signed [9:0] hstep = c_mirh ? -10'sd1 : 10'sd1;
// the row step, as GID computes it from the pitch and the mirrors
wire signed [10:0] vstep = (!c_mirh && !c_mirv) ? {2'b0, c_pitch} :
                           ( c_mirh && !c_mirv) ? {2'b0, c_pitch} + 11'sd2 :
                           (!c_mirh &&  c_mirv) ? -({2'b0, c_pitch} + 11'sd2) : -{2'b0, c_pitch};

wire [15:0] s_sw = c_swap ? {s_val[7:0], s_val[15:8]} : s_val;
wire [15:0] d_sw = c_swap ? {d_val[7:0], d_val[15:8]} : d_val;

function [1:0] ovl_mask; input [15:0] s; input [7:0] k;
    ovl_mask = {(s[15:8] != k), (s[7:0] != k)};
endfunction

always @(posedge clk) begin
    cb_we <= 1'b0;
    if (cold) begin
        cmd_count <= 9'd0; manual <= 1'b0; running <= 1'b0; reading <= 1'b0;
        st <= S_IDLE; b_req <= 1'b0;
    end else begin
        if (wr272) cmd_page <= din[12:0];
        if (wr270) begin
            if (din[8:0] == 9'd0) begin
                // 0 commands: an asynchronous stop of everything
                running <= 1'b0; reading <= 1'b0; st <= S_IDLE; b_req <= 1'b0;
                cmd_count <= 9'd0;
                manual <= din[B_MANUAL];
            end else if (running) begin
                cmd_count <= din[8:0];        // only the count may change
            end else begin
                cmd_count <= din[8:0];
                manual <= din[B_MANUAL];
                if (manual && din[B_START]) begin
                    // a manual start: with the count just written
                    running <= 1'b1; reading <= 1'b1;
                    n_cmd <= din[8:0]; load_cnt <= 13'd0;
                    load_adr <= {cmd_page, 11'd0};
                    st <= S_LOAD;
                end
            end
        end
        // the automatic start
        if (frame_end && !running && !manual && cmd_count != 9'd0) begin
            running <= 1'b1; reading <= 1'b1;
            n_cmd <= cmd_count; load_cnt <= 13'd0;
            load_adr <= {cmd_page, 11'd0};
            st <= S_LOAD;
        end

        case (st)
        S_IDLE: ;

        // the packet into the buffer, a word at a time
        S_LOAD: begin
            if (load_cnt == {n_cmd, 3'd0}) begin
                reading <= 1'b0;
                i_cmd <= 9'd0; f_w <= 3'd0;
                st <= S_FETCH;
            end else begin
                b_req <= 1'b1; b_we <= 1'b0; b_adr <= load_adr[23:1];
                st <= S_LOAD_W;
            end
        end
        S_LOAD_W: begin
            if (b_take) b_req <= 1'b0;
            if (b_ack) begin
                cb_we <= 1'b1; cb_wadr <= load_cnt[11:0];
                cb_wdata <= load_adr[0] ? b_rdata[31:16] : b_rdata[15:0];
                load_cnt <= load_cnt + 13'd1;
                load_adr <= load_adr + 24'd1;
                st <= S_LOAD;
            end
        end

        // the next command out of the buffer
        S_FETCH: begin
            if (i_cmd == n_cmd) begin
                running <= 1'b0; st <= S_IDLE;
            end else begin
                cb_radr <= {i_cmd, f_w};
                st <= S_FETCH_W;
            end
        end
        S_FETCH_W: begin
            // cb_rdata is a clock behind cb_radr
            st <= S_PARSE;
        end
        S_PARSE: begin
            c[f_w] <= cb_rdata;
            if (f_w == 3'd7) begin
                i_cmd <= i_cmd + 9'd1;
                st <= S_STEP;       // S_STEP with h_left = 0 starts the command
                h_left <= 9'd0; w_left <= 9'd0;
            end else begin
                f_w <= f_w + 3'd1;
                st <= S_FETCH;
            end
            f_w <= (f_w == 3'd7) ? 3'd0 : f_w + 3'd1;
        end

        // one word of the command
        S_RSRC: begin
            b_req <= 1'b1; b_we <= 1'b0; b_adr <= a_src[23:1];
            st <= S_RSRC_W;
        end
        S_RSRC_W: begin
            if (b_take) b_req <= 1'b0;
            if (b_ack) begin
                s_val <= a_src[0] ? b_rdata[31:16] : b_rdata[15:0];
                st <= c_rddst ? S_RDST : S_EXEC;
            end
        end
        S_RDST: begin
            b_req <= 1'b1; b_we <= 1'b0; b_adr <= a_dst[23:1];
            st <= S_RDST_W;
        end
        S_RDST_W: begin
            if (b_take) b_req <= 1'b0;
            if (b_ack) begin
                d_val <= a_dst[0] ? b_rdata[31:16] : b_rdata[15:0];
                st <= S_EXEC;
            end
        end
        S_EXEC: begin
            to_src <= 1'b0;
            case (c_op)
                3'd0: begin out_val <= {c_sconst, c_sconst}; out_mask <= 2'b11; end
                3'd1: begin out_val <= s_sw; out_mask <= 2'b11; end
                3'd2: begin out_val <= s_sw; out_mask <= ovl_mask(s_sw, c_sconst); end
                3'd3: begin out_val <= s_sw;
                            out_mask <= ovl_mask(s_sw, c_sconst) & {(d_sw[15:8] == c_dconst), (d_sw[7:0] == c_dconst)}; end
                3'd4: begin out_val <= d_sw; out_mask <= 2'b11; to_src <= 1'b1; end
                3'd5: begin out_val <= {c_sconst, c_sconst}; out_mask <= ovl_mask(s_sw, c_dconst); end
                default: begin out_val <= 16'd0; out_mask <= 2'd0; end
            endcase
            st <= S_WRITE;
        end
        S_WRITE: begin
            if (out_mask == 2'd0) st <= S_STEP;
            else begin
                b_req <= 1'b1; b_we <= 1'b1;
                b_adr <= to_src ? a_src[23:1] : a_dst[23:1];
                b_wdata <= {out_val, out_val};
                b_wmask <= (to_src ? a_src[0] : a_dst[0]) ? {out_mask, 2'b00} : {2'b00, out_mask};
                st <= S_WRITE_W;
            end
        end
        S_WRITE_W: begin
            if (b_take) b_req <= 1'b0;
            if (b_ack) st <= S_STEP;
        end

        // step to the next word, row, or command
        S_STEP: begin
            if (h_left == 9'd0 && w_left == 9'd0) begin
                // the command starts here (after S_PARSE)
                if (c_nop || c_op > 3'd5) st <= S_FETCH;
                else begin
                    a_dst <= c_dst + c_yadd;
                    a_src <= c_src;
                    w_left <= c_width;
                    h_left <= c_height;
                    st <= c_rdsrc ? S_RSRC : c_rddst ? S_RDST : S_EXEC;
                    if (c_height == 9'd0) st <= S_FETCH;
                end
            end else begin
                a_dst <= a_dst + {{14{hstep[9]}}, hstep};
                if (c_op != 3'd0) a_src <= a_src + 24'd1;
                if (w_left == 9'd1) begin
                    w_left <= c_width;
                    a_dst <= a_dst + {{14{hstep[9]}}, hstep} + {{13{vstep[10]}}, vstep};
                    if (h_left == 9'd1) begin
                        h_left <= 9'd0; w_left <= 9'd0;
                        st <= S_FETCH;
                    end else begin
                        h_left <= h_left - 9'd1;
                        st <= c_rdsrc ? S_RSRC : c_rddst ? S_RDST : S_EXEC;
                    end
                end else begin
                    w_left <= w_left - 9'd1;
                    st <= c_rdsrc ? S_RSRC : c_rddst ? S_RDST : S_EXEC;
                end
            end
        end
        default: st <= S_IDLE;
        endcase
    end
end

endmodule

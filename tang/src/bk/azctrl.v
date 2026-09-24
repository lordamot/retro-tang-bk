`timescale 1ns / 1ps
//========================================================================
// azctrl.v - the AZ controller: registers 177220-177226, and the MCU
// behind them.
//
// On the real AZBK the four words are the STM32's: a command and status
// register (CSR, 177220), a data register (DR, 177222) through which
// every block moves a word at a time, and two boot ROMs of one word
// (177224/177226, unused on the BK).  The commands are the pseudo-disk
// controller's (MAXIOL: "Команды контролера AZ", "Новые команды") and
// GID's AZBK_ctrl.cpp is the model this follows: a command is accepted
// only while DONE (bit 7) is set; while it runs DONE is clear and DR is
// not acknowledged (a bus timeout, as the doc says); ERR (15) and BIG
// (14) are set with DONE; IE (6) is written with every command and NOP
// (030) exists to write it alone; a finished READ or WRITE with IE set
// interrupts through vector 174.
//
// Here the commands are split.  The ones that only move the DR's
// pointers or answer from state the FPGA holds are done on the spot:
// RESET, the unit select (001: the size comes from the table below,
// filled by the MCU), the block number (002/012), the sizes (007/017), the buffer
// transfers (015/016/022/023), NOP and NET, the feature word (027), the
// diagnostic word (020), the time buffer's reads and writes (032/033),
// the IP and card-size reads (041/057), the ones the network would do
// (035/036/040/043, answered empty), and 037, which resets the machine.
// Everything that needs the card, the clock or the ini file - a unit
// select, a block read or write, the mount table, the directory, the
// EEPROM, the time, the file commands, the screenshot, the network -
// raises an interrupt to the MCU (int_in bit 4), which reads the
// command out over its own SPI target (mcu_spi.v's target 4), serves it
// from FatFs (mnano/azbk.c), moves words in and out of the buffer, and
// says "done" with the DR pointers to set.  DONE stays clear meanwhile,
// which is what the software waits on.
//
// The buffer is 8192 words of BSRAM, laid out as the emulator's several
// arrays: IOBUF at 0 (256 words: the block), CMOS at 256 (256: the
// EEPROM image and the file commands' data), IP at 512 (12), SIZE at
// 528 (2), TS at 544 (14: the timestamp), FEAT at 560 (2), DIAG at 562
// (2), USIZE at 576 (64: every unit's size in blocks, low word then
// high, kept by the MCU - a select reads it), and the units table at
// 1024 (32 x 198 words, command 011).
//
// The select is local because the software does not wait for it: the
// 337 boot ROM (AZ337, 160314) writes 001 and goes straight on to the
// block number and the read, and a command written while DONE is
// clear is dropped - GID's emulator completes the select in the write
// and MAXIOL's controller evidently as fast.  The MCU's answer took a
// task wake-up and a file open, the 002 and 005 fell on the floor, the
// software read an empty buffer, and the third board (23 Sep 2026)
// sat in the BK monitor with "served 28 cmds, 0 rd, last 001 001 001
// 001".  The simulation's stand-in answered inside the software's
// dozen instructions and hid it.
//
// The MCU's SPI target, one transaction a command byte:
//   01  status   the bytes after it: {pending, cmd[5:0]}, {unit_ok, 0,
//                0, unit[4:0]} (the selected unit, for a read or write),
//                blkn (4, high first), {IE}, wr_written (2), seq
//   02  read     addr_hi, addr_lo (a word address), then the words as
//                low byte, high byte, stepping
//   03  write    addr_hi, addr_lo, then low byte, high byte a word
//   04  done     flags {BIG, ERR}, rd_base (2), rd_cnt (2), wr_base (2),
//                wr_cnt (2), rd_buf (2: what 015 will start from),
//                init_wcnt (2), then five bytes kept for the shape
//                (once the unit's size and number; the FPGA holds
//                those itself now)
//   05  reset    the machine: the same as command 037
// As everywhere on this link the core answers one strobe behind.
//========================================================================
module azctrl (
    input             clk,
    input             cold,

    // the bus
    input             sync,
    input      [15:0] adr,
    input             stb,
    input             we,
    input      [15:0] din,
    output     [15:0] dout,
    output            ack,
    input             wr_stb,
    input             rd_stb,

    output reg        virq174,      // vector 174 request
    input             vack174,
    output reg        az_reset,     // one clock: command 037 / MCU 05

    // the MCU's SPI target
    input             mcu_strobe,
    input             mcu_start,
    input      [7:0]  mcu_din,
    output reg [7:0]  mcu_dout,
    output            mcu_irq
);

localparam CS_IE = 6, CS_DONE = 7, CS_BIG = 14, CS_ERR = 15;

// buffer regions, in words
localparam [12:0] R_IOBUF = 13'd0, R_CMOS = 13'd256, R_IP = 13'd512, R_SIZE = 13'd528,
                  R_TS = 13'd544, R_FEAT = 13'd560, R_DIAG = 13'd562, R_USIZE = 13'd576,
                  R_TABLE = 13'd1024;

//------------------------------------------------------------------------
// The buffer: port A the processor's and the local commands', port B
// the MCU's
//------------------------------------------------------------------------
reg [15:0] buf_mem [0:8191];
reg [12:0] a_adr = 13'd0, b_adr = 13'd0;
reg        a_we = 1'b0, b_we = 1'b0;
reg [15:0] a_wdata = 16'd0, b_wdata = 16'd0;
reg [15:0] a_rdata = 16'd0, b_rdata = 16'd0;
// a port reads or writes in a clock, never both: Gowin's DPB has no
// read-old-data write mode (PA2122), so a write clock leaves the read
// data as it was and the address is put back to the read pointer after
always @(posedge clk) begin
    if (a_we) buf_mem[a_adr] <= a_wdata;
    else      a_rdata <= buf_mem[a_adr];
end
always @(posedge clk) begin
    if (b_we) buf_mem[b_adr] <= b_wdata;
    else      b_rdata <= buf_mem[b_adr];
end

//------------------------------------------------------------------------
// The registers
//------------------------------------------------------------------------
reg [15:0] csr = 16'o200;        // DONE at power-up
reg [15:0] dr = 16'd0;           // the last word through the DR
reg [5:0]  cmd = 6'd0;
reg [4:0]  unit = 5'd0;
reg        unit_ok = 1'b0;
reg [31:0] unit_size = 32'd0;    // blocks
reg [31:0] blkn = 32'd0;
reg [12:0] init_wcnt = 13'd256;
reg [12:0] rd_buf = R_IOBUF;     // what 015 starts from
reg [12:0] rd_ptr = 13'd0, wr_ptr = 13'd0;
reg [12:0] rd_cnt = 13'd0, wr_cnt = 13'd0;
reg [12:0] wr_written = 13'd0;
reg        pending = 1'b0;       // an MCU command is out
reg [7:0]  seq = 8'd0;
reg [2:0]  local_st = 3'd0;      // a few local commands need clocks
reg        blk_err = 1'b0;

wire sel220 = sync && (adr[15:1] == (16'o177220 >> 1));
wire sel222 = sync && (adr[15:1] == (16'o177222 >> 1));
wire sel224 = sync && (adr[15:1] == (16'o177224 >> 1));
wire sel226 = sync && (adr[15:1] == (16'o177226 >> 1));
wire done   = csr[CS_DONE];

// the DR read data: `dr`, which holds the buffer word at rd_ptr while a
// stream is up - loaded between strobes, so that it stands still for
// the whole of one (19 Sep 2026: with a_rdata on the bus the pointer's
// step at the strobe's start changed the word under the processor's
// sample, and every second word of the time went missing)
wire [15:0] dr_rd = dr;

assign dout = sel220 ? csr : (sel222 && done) ? dr_rd : (sel226 && done) ? 16'o776 : 16'd0;
assign ack  = stb && (sel220 || (done && (sel222 || sel224 || sel226)));

wire wr220 = wr_stb && sel220;
wire wr222 = wr_stb && sel222 && done;
wire rd222 = rd_stb && sel222 && done;

//------------------------------------------------------------------------
// The MCU's side
//------------------------------------------------------------------------
reg [7:0]  m_cmd = 8'd0;
reg [4:0]  m_st = 5'd0;
reg        m_lo = 1'b0;          // low byte of a word taken
reg [7:0]  m_lobyte = 8'd0;
reg [12:0] m_adr = 13'd0;
reg        m_done = 1'b0;        // a "done" is being applied
reg [1:0]  m_flags = 2'd0;
reg [12:0] m_rd_base = 13'd0, m_rd_cnt = 13'd0, m_wr_base = 13'd0, m_wr_cnt = 13'd0, m_rd_buf = 13'd0, m_init = 13'd0;
reg        m_reset = 1'b0;

assign mcu_irq = pending;

// is this command the MCU's?
function is_mcu; input [5:0] c;
    case (c)
        6'o03, 6'o04, 6'o05, 6'o06, 6'o11, 6'o13, 6'o14,
        6'o21, 6'o24, 6'o25, 6'o26, 6'o31, 6'o34, 6'o42, 6'o44, 6'o47,
        6'o50, 6'o51, 6'o52, 6'o53, 6'o54, 6'o55, 6'o56: is_mcu = 1'b1;
        default: is_mcu = 1'b0;
    endcase
endfunction

always @(posedge clk) begin
    a_we <= 1'b0; b_we <= 1'b0;
    az_reset <= 1'b0;
    if (vack174) virq174 <= 1'b0;
    m_done <= 1'b0; m_reset <= 1'b0;

    if (cold) begin
        csr <= 16'o200; pending <= 1'b0; rd_cnt <= 13'd0; wr_cnt <= 13'd0;
        init_wcnt <= 13'd256; rd_buf <= R_IOBUF; local_st <= 3'd0; virq174 <= 1'b0;
    end else begin
        //----------------------------------------------------------------
        // The processor
        //----------------------------------------------------------------
        if (!stb && rd_cnt != 13'd0 && local_st == 3'd0) dr <= a_rdata;   // the next word, between strobes
        if (rd222) begin
            if (rd_cnt != 13'd0) begin
                rd_ptr <= rd_ptr + 13'd1;
                rd_cnt <= rd_cnt - 13'd1;
            end
        end
        if (wr222) begin
            dr <= din;
            if (wr_cnt != 13'd0) begin
                a_we <= 1'b1; a_adr <= wr_ptr; a_wdata <= din;
                wr_ptr <= wr_ptr + 13'd1;
                wr_cnt <= wr_cnt - 13'd1;
                wr_written <= wr_written + 13'd1;
            end
        end

        if (wr220) begin
            csr[CS_IE] <= din[CS_IE];
            if (din[5:0] == 6'd0) begin
                // RESET: on the spot, whatever is going on
                rd_cnt <= 13'd0; wr_cnt <= 13'd0; init_wcnt <= 13'd256; blkn <= 32'd0;
                csr <= 16'o200;
                pending <= 1'b0; local_st <= 3'd0;
            end else if (done) begin
                cmd <= din[5:0];
                csr[CS_DONE] <= 1'b0; csr[CS_BIG] <= 1'b0; csr[CS_ERR] <= 1'b0;
                if (din[5:0] != 6'o15) init_wcnt <= 13'd256;
                if (is_mcu(din[5:0])) begin
                    pending <= 1'b1;
                    seq <= seq + 8'd1;
                end else
                    local_st <= 3'd1;
            end
        end

        //----------------------------------------------------------------
        // The local commands, a few clocks after the write
        //----------------------------------------------------------------
        if (local_st != 3'd0) begin
            local_st <= local_st + 3'd1;
            case (cmd)
            6'o01: if (local_st == 3'd1) begin
                // select: the unit from the DR, its size from the table
                unit <= dr[4:0];
                a_adr <= R_USIZE + {7'd0, dr[4:0], 1'b0};
            end else if (local_st == 3'd2) begin
                a_adr <= a_adr + 13'd1;                  // the low word lands in a_rdata now
            end else if (local_st == 3'd3) begin
                unit_size[15:0] <= a_rdata;
            end else if (local_st == 3'd4) begin
                unit_size[31:16] <= a_rdata;
            end else begin
                unit_ok <= (unit_size != 32'd0);
                if (unit_size == 32'd0) csr[CS_ERR] <= 1'b1;   // nothing mounted there
                csr[CS_DONE] <= 1'b1; local_st <= 3'd0;
            end
            6'o02, 6'o12: if (local_st == 3'd1) begin
                if (cmd == 6'o02) blkn <= {16'd0, dr}; else blkn[31:16] <= dr;
            end else if (local_st == 3'd2) begin
                if (!unit_ok || unit_size <= blkn) csr[CS_ERR] <= 1'b1;
                csr[CS_DONE] <= 1'b1; local_st <= 3'd0;
            end
            6'o07: if (local_st == 3'd1) begin
                if (!unit_ok || unit_size <= blkn) begin csr[CS_ERR] <= 1'b1; csr[CS_DONE] <= 1'b1; local_st <= 3'd0; end
                else begin
                    a_we <= 1'b1; a_adr <= R_IOBUF;
                    a_wdata <= (unit_size > 32'd65535) ? 16'hFFFF : unit_size[15:0];
                    if (unit_size > 32'd65535) csr[CS_BIG] <= 1'b1;
                end
            end else if (local_st == 3'd2) begin
                rd_ptr <= R_IOBUF; rd_cnt <= 13'd1; wr_cnt <= 13'd0; a_adr <= R_IOBUF;
            end else begin csr[CS_DONE] <= 1'b1; local_st <= 3'd0; end
            6'o17: if (local_st == 3'd1) begin
                if (!unit_ok || unit_size <= blkn) begin csr[CS_ERR] <= 1'b1; csr[CS_DONE] <= 1'b1; local_st <= 3'd0; end
                else begin a_we <= 1'b1; a_adr <= R_IOBUF; a_wdata <= unit_size[15:0]; end
            end else if (local_st == 3'd2) begin
                a_we <= 1'b1; a_adr <= R_IOBUF + 13'd1; a_wdata <= unit_size[31:16];
            end else if (local_st == 3'd3) begin
                rd_ptr <= R_IOBUF; rd_cnt <= 13'd2; wr_cnt <= 13'd0; a_adr <= R_IOBUF;
            end else begin csr[CS_DONE] <= 1'b1; local_st <= 3'd0; end
            6'o15: begin   // read the buffer
                rd_ptr <= rd_buf; rd_cnt <= init_wcnt; wr_cnt <= 13'd0; a_adr <= rd_buf;
                if (local_st == 3'd2) begin csr[CS_DONE] <= 1'b1; local_st <= 3'd0; end
            end
            6'o16: begin   // write the buffer
                wr_ptr <= R_IOBUF; wr_cnt <= init_wcnt; wr_written <= 13'd0; rd_cnt <= 13'd0;
                csr[CS_DONE] <= 1'b1; local_st <= 3'd0;
            end
            6'o22: begin
                rd_ptr <= R_CMOS; rd_cnt <= 13'd256; wr_cnt <= 13'd0; a_adr <= R_CMOS;
                if (local_st == 3'd2) begin csr[CS_DONE] <= 1'b1; local_st <= 3'd0; end
            end
            6'o23: begin
                wr_ptr <= R_CMOS; wr_cnt <= 13'd256; wr_written <= 13'd0; rd_cnt <= 13'd0;
                csr[CS_DONE] <= 1'b1; local_st <= 3'd0;
            end
            6'o27: if (local_st == 3'd1) begin
                a_we <= 1'b1; a_adr <= R_FEAT; a_wdata <= 16'h1204;      // STM 18, hardware 4
            end else if (local_st == 3'd2) begin
                a_we <= 1'b1; a_adr <= R_FEAT + 13'd1; a_wdata <= 16'd31;
            end else if (local_st == 3'd3) begin
                rd_ptr <= R_FEAT; rd_cnt <= 13'd2; wr_cnt <= 13'd0; a_adr <= R_FEAT;
            end else begin csr[CS_DONE] <= 1'b1; local_st <= 3'd0; end
            6'o20: if (local_st == 3'd1) begin
                a_we <= 1'b1; a_adr <= R_DIAG; a_wdata <= 16'd0;
            end else if (local_st == 3'd2) begin
                a_we <= 1'b1; a_adr <= R_DIAG + 13'd1; a_wdata <= 16'd0;
            end else if (local_st == 3'd3) begin
                rd_ptr <= R_DIAG; rd_cnt <= 13'd2; wr_cnt <= 13'd0; a_adr <= R_DIAG;
            end else begin csr[CS_DONE] <= 1'b1; local_st <= 3'd0; end
            6'o32: begin
                rd_ptr <= R_TS; rd_cnt <= 13'd14; wr_cnt <= 13'd0; a_adr <= R_TS;
                if (local_st == 3'd2) begin csr[CS_DONE] <= 1'b1; local_st <= 3'd0; end
            end
            6'o33: begin
                wr_ptr <= R_TS + 13'd7; wr_cnt <= 13'd7; wr_written <= 13'd0; rd_cnt <= 13'd0;
                csr[CS_DONE] <= 1'b1; local_st <= 3'd0;
            end
            6'o41: begin
                rd_ptr <= R_IP; rd_cnt <= 13'd12; wr_cnt <= 13'd0; a_adr <= R_IP;
                if (local_st == 3'd2) begin csr[CS_DONE] <= 1'b1; local_st <= 3'd0; end
            end
            6'o57: begin
                rd_ptr <= R_SIZE; rd_cnt <= 13'd2; wr_cnt <= 13'd0; a_adr <= R_SIZE;
                if (local_st == 3'd2) begin csr[CS_DONE] <= 1'b1; local_st <= 3'd0; end
            end
            6'o40, 6'o43: begin
                // no network: the IP block reads as zeros (twelve clocks)
                a_we <= 1'b1; a_adr <= R_IP + {10'd0, local_st}; a_wdata <= 16'd0;
                if (local_st == 3'd6) begin csr[CS_DONE] <= 1'b1; local_st <= 3'd0; end
            end
            6'o37: begin
                az_reset <= 1'b1;
                csr[CS_DONE] <= 1'b1; local_st <= 3'd0;
            end
            6'o10: begin
                // NET: with IE set it only clears it (and does nothing else)
                if (csr[CS_IE]) csr[CS_IE] <= 1'b0;
                csr[CS_DONE] <= 1'b1; local_st <= 3'd0;
            end
            6'o30, 6'o35, 6'o36: begin
                csr[CS_DONE] <= 1'b1; local_st <= 3'd0;
            end
            default: begin
                csr[CS_ERR] <= 1'b1; csr[CS_DONE] <= 1'b1; local_st <= 3'd0;
            end
            endcase
        end

        //----------------------------------------------------------------
        // The MCU's target
        //----------------------------------------------------------------
        if (mcu_strobe) begin
            if (mcu_start) begin
                m_cmd <= mcu_din; m_st <= 5'd0; m_lo <= 1'b0;
                mcu_dout <= 8'h00;
            end else begin
                if (m_st != 5'd31) m_st <= m_st + 5'd1;
                case (m_cmd)
                8'd1: case (m_st)
                    5'd0: mcu_dout <= {unit_ok, 2'b00, unit};   // the selected unit; (pending, cmd) went with the command byte
                    5'd1: mcu_dout <= blkn[31:24];
                    5'd2: mcu_dout <= blkn[23:16];
                    5'd3: mcu_dout <= blkn[15:8];
                    5'd4: mcu_dout <= blkn[7:0];
                    5'd5: mcu_dout <= {7'd0, csr[CS_IE]};
                    5'd6: mcu_dout <= {3'd0, wr_written[12:8]};
                    5'd7: mcu_dout <= wr_written[7:0];
                    5'd8: mcu_dout <= seq;
                    default: mcu_dout <= 8'h00;
                endcase
                8'd2: begin
                    if (m_st == 5'd0) m_adr[12:8] <= mcu_din[4:0];
                    else if (m_st == 5'd1) begin b_adr <= {m_adr[12:8], mcu_din}; m_lo <= 1'b0; end
                    else begin
                        // b_rdata holds the word at b_adr; low byte then high, then step
                        if (!m_lo) begin mcu_dout <= b_rdata[7:0]; m_lo <= 1'b1; end
                        else begin mcu_dout <= b_rdata[15:8]; m_lo <= 1'b0; b_adr <= b_adr + 13'd1; end
                        if (m_st == 5'd31) m_st <= 5'd30;
                    end
                end
                8'd3: begin
                    if (m_st == 5'd0) m_adr[12:8] <= mcu_din[4:0];
                    else if (m_st == 5'd1) begin m_adr[7:0] <= mcu_din; m_lo <= 1'b0; end
                    else begin
                        if (!m_lo) begin m_lobyte <= mcu_din; m_lo <= 1'b1; end
                        else begin
                            b_we <= 1'b1; b_adr <= m_adr; b_wdata <= {mcu_din, m_lobyte};
                            m_adr <= m_adr + 13'd1; m_lo <= 1'b0;
                        end
                        if (m_st == 5'd31) m_st <= 5'd30;
                    end
                end
                8'd4: case (m_st)
                    5'd0: m_flags <= mcu_din[1:0];
                    5'd1: m_rd_base[12:8] <= mcu_din[4:0];
                    5'd2: m_rd_base[7:0] <= mcu_din;
                    5'd3: m_rd_cnt[12:8] <= mcu_din[4:0];
                    5'd4: m_rd_cnt[7:0] <= mcu_din;
                    5'd5: m_wr_base[12:8] <= mcu_din[4:0];
                    5'd6: m_wr_base[7:0] <= mcu_din;
                    5'd7: m_wr_cnt[12:8] <= mcu_din[4:0];
                    5'd8: m_wr_cnt[7:0] <= mcu_din;
                    5'd9: m_rd_buf[12:8] <= mcu_din[4:0];
                    5'd10: m_rd_buf[7:0] <= mcu_din;
                    5'd11: m_init[12:8] <= mcu_din[4:0];
                    5'd12: m_init[7:0] <= mcu_din;
                    5'd17: m_done <= 1'b1;                  // after five bytes the FPGA no longer needs
                    default: ;
                endcase
                8'd5: if (m_st == 5'd0 && mcu_din == 8'hA5) az_reset <= 1'b1;
                default: ;
                endcase
            end
            // the status's first byte goes out with the command byte's successor
            if (mcu_start && mcu_din == 8'd1) mcu_dout <= {pending, 1'b0, cmd};
        end

        // applying a "done"
        if (m_done && pending) begin
            pending <= 1'b0;
            csr[CS_DONE] <= 1'b1;
            csr[CS_ERR] <= m_flags[0];
            csr[CS_BIG] <= m_flags[1];
            rd_ptr <= m_rd_base; rd_cnt <= m_rd_cnt; a_adr <= m_rd_base;
            wr_ptr <= m_wr_base; wr_cnt <= m_wr_cnt; wr_written <= 13'd0;
            rd_buf <= m_rd_buf; init_wcnt <= m_init;
            if ((cmd == 6'o05 || cmd == 6'o06) && csr[CS_IE]) virq174 <= 1'b1;
        end

        // keep port A on the read pointer when idle, so dr_rd is ready
        if (!a_we && local_st == 3'd0 && !wr222) a_adr <= rd_ptr;
    end
end

endmodule

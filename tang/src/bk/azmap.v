`timescale 1ns / 1ps
//========================================================================
// azmap.v - the AZBK memory mapper: sixteen 4 KB windows over 32 MB.
//
// The processor's 64 KB is sixteen windows of 4 KB (four in a BK page),
// and each window has a 13-bit page number (177300-177336), an "active"
// bit (177340), a read-only bit (177342) and a "shadow" bit (177344).
// The controller's own register is 177346, and 177350/177352 are copies
// of the last words written to the SMK's 177130 and the BK-0011M's
// 177716 in their memory-management sense.  MAXIOL's description
// (forum.maxiol.com, "Модель управления памятью в AZ V2") is the
// authority for the register meaning, and GID's emulator (BKemu v4.6,
// devemu/AZBK/AZBK_MemMapper.cpp) for what the software sees; where they
// differ this follows the emulator, which is what Dangerous Dave was
// tested on.  .claude/docs/platform.md has the whole account.
//
// On a real BK-0011M the AZ sits on the bus beside the machine's own
// 128 KB, and a "shadow" window is one the machine's RAM answers and the
// AZ merely copies writes of, so that its display can read them.  Here
// there is no other RAM: the shadow pages 030-037 ARE the machine's
// memory, so a shadow window reads and writes like an active one.  That
// is the one liberty taken, and it is exactly what the emulator's board
// RAM plus its shadow copy amount to.
//
// The same goes for a window the AZ leaves alone (neither active nor
// shadow): on the real machine the BK's own ВП1-037 answers it, with the
// page its 177716 word selects, and the ROMs answer 100000-177777.  The
// start ROM relies on this: its first instruction after the stack
// pointer stores the trap vector at 4 while window 0 is still off (19
// Sep 2026).  So a window the AZ does not claim falls back to the
// machine's memory as the emulator's platform does behind the AZ: pages
// 030-033 for 0-37777, the 177716 page for 40000-77777, the 177716 page
// or the BASIC/BOS ROM pages for 100000-137777, and the 324/325 ROM pages
// (0120-0123) for 140000-177777.  Writes into ROM there are answered and
// dropped, as the 037 answers them.
//
// The physical address space (in 4 KB pages, octal):
//     0-037   the BK-0011M's 128 KB (shadow), 030-033 its page 0
//    40-077   the controller's own pages (page 076 the screenshot header,
//             077 the CMOS block and configuration) - always R/W
//   100-177   the ROM images, loaded from the card: never writable
//   200-377   the SMK-512 emulation's 512 KB
//   400-      free RAM, up to page 17777 on the real controller; here
//             the SDRAM's 2048 pages wrap (sdram.v)
//
// The whole 24-bit word address of an access is {page, addr[11:1]}.
//========================================================================
module azmap (
    input             clk,
    input             cold,         // the controller's cold reset (RESET on the AZ, cmd 037)

    // the bus: a one-clock write strobe with the address and the data,
    // and the address alone for the decode
    input             wr_stb,
    input      [15:0] wr_adr,
    input      [15:0] wr_data,
    input      [1:0]  wr_wtbt,

    // the current access: which page, and may it be read or written
    input      [15:0] adr,
    output     [12:0] page,
    output            rd_ok,
    output            wr_ok,        // the write is performed
    output            wr_drop,      // the write is answered but goes nowhere (ROM)

    // the registers, for reading back (177300-177352)
    input      [5:0]  rd_reg,       // (adr - 177300) >> 1, 0..21
    output reg [15:0] rd_data,

    output reg [15:0] mapper_ctrl,  // 177346, for the video and the timer
    input             sel1_rd,      // the processor reads 177716 (one clock)
    output            sel1_start,   // bSEL1: 177716 says start at 170000
    output            sel1_bk11     // ...or at 140000 (REVTYPE, 037_OFF and BK11EMU all set)
);

// bits of 177346
localparam B_SMK_WND1 = 15, B_REVTYPE = 14, B_WND1_REV = 13, B_BRDTYPE = 12,
           B_BK11EMU = 11, B_014_OFF = 10, B_037_OFF = 9, B_ROM11 = 5,
           B_V100 = 3, B_50HZ = 2;

reg [12:0] mapper [0:15];
reg [15:0] win_ctrl = 16'd0, win_ro = 16'd0, win_shdw = 16'd0;
reg [15:0] az130 = 16'd0, az716 = 16'd0;

// the precomputed halves: the BK-0011M's and the SMK's
reg [6:0]  pre_b [0:7];
reg        pre_b_ctrl = 1'b0, pre_b_shdw = 1'b0;
reg [7:0]  pre_s [0:7];
reg [7:0]  pre_s_ctrl = 8'd0, pre_s_ro = 8'd0;
reg        smk_flag = 1'b0;
reg [2:0]  b_win0 = 3'd0;                // the machine's own mapping, from 177716
reg [6:0]  b_win1 [0:3];
reg        b_roms34 = 1'b0;              // the external ROMs 10/11 asked for: nothing there

integer i;
initial begin
    for (i = 0; i < 16; i = i + 1) mapper[i] = 13'd0;
    for (i = 0; i < 8; i = i + 1) begin pre_b[i] = 7'd0; pre_s[i] = 8'd0; end
    for (i = 0; i < 4; i = i + 1) b_win1[i] = 7'd0;
    mapper_ctrl = 16'd4;          // AZ_version: the hardware type in bits 2:0
end

//------------------------------------------------------------------------
// The decode
//------------------------------------------------------------------------
wire [3:0]  w = adr[15:12];
wire [12:0] pg = mapper[w];
wire        rom_page = (pg[12:6] == 7'b0000001);     // 0100-0177
wire        act  = win_ctrl[w];
wire        shd  = win_shdw[w] & ~win_ctrl[w];

// the machine's own memory behind an unclaimed window (see the head)
reg  [12:0] fb_pg;
reg         fb_ok, fb_rom;
always @(*) begin
    fb_ok = 1'b1; fb_rom = 1'b0; fb_pg = 13'd0;
    case (w[3:2])
        2'd0: fb_pg = {9'o06, w[1:0]};                       // 030-033
        2'd1: fb_pg = {6'd0, b_win0, w[1:0]};                // the 177716 page in window 0
        2'd2: begin fb_pg = {6'd0, b_win1[w[1:0]]}; fb_rom = b_win1[w[1:0]][6]; fb_ok = ~b_roms34; end
        2'd3: begin fb_pg = {9'o24, w[1:0]}; fb_rom = 1'b1; end   // the 324/325 ROMs, 0120-0123
    endcase
end
wire        claimed = act | shd;
assign page    = claimed ? pg : fb_pg;
assign rd_ok   = claimed | fb_ok;
assign wr_ok   = (act & ~win_ro[w] & ~rom_page) | shd | (~claimed & fb_ok & ~fb_rom);
assign wr_drop = ~wr_ok & ((act & (win_ro[w] | rom_page)) | (~claimed & fb_ok & fb_rom));

// bSEL1, as the emulator has it (Platform.cpp: SetSel(true) before the
// board's reset, so the processor's start read of 177716 says 170000,
// SetSel(false) once the controller's own reset is done): true from a
// cold reset until the processor has read its start address, then
// false, and 177716 reads as the machine's own word - 140000 with the
// three revision bits set, 100000 otherwise (AZ_716_Out).  The 700 the
// start ROM writes into 177346 is what the real FPGA keys its flag on;
// the emulator, which Dave was proven on, does it this way.
reg sel1 = 1'b1;
always @(posedge clk)
    if (cold) sel1 <= 1'b1;
    else if (sel1_rd) sel1 <= 1'b0;
assign sel1_start = sel1;
assign sel1_bk11  = mapper_ctrl[B_REVTYPE] & mapper_ctrl[B_037_OFF] & mapper_ctrl[B_BK11EMU];

//------------------------------------------------------------------------
// Reading the registers back
//------------------------------------------------------------------------
always @(*) begin
    case (rd_reg)
        6'd16: rd_data = win_ctrl;
        6'd17: rd_data = win_ro;
        6'd18: rd_data = win_shdw;
        6'd19: rd_data = mapper_ctrl;
        6'd20: rd_data = az130;
        6'd21: rd_data = az716;
        default: rd_data = (rd_reg < 6'd16) ? {3'd0, mapper[rd_reg[3:0]]} : 16'd0;
    endcase
end

//------------------------------------------------------------------------
// The SMK's mode table (forum.maxiol.com, "6.4 STATE_DOUT_reg_az_130_pre")
//------------------------------------------------------------------------
wire [3:0] smk_page = {wr_data[10], wr_data[3], wr_data[2], wr_data[0]};
wire [2:0] smk_mode = {wr_data[6], wr_data[5], wr_data[4]};
function [7:0] sp; input [3:0] p; input [2:0] n; sp = {1'b1, p, n}; endfunction

// the BK-0011M's 177716: what goes into windows 4-11
wire [2:0] win0_map = wr_data[14:12];
wire [2:0] win1_map = wr_data[10:8];
wire       roms01   = wr_data[1] | wr_data[0];
wire       roms34   = wr_data[3] | wr_data[4];
wire       n_ctrl   = (roms01 & mapper_ctrl[B_ROM11]) | (~roms34 & mapper_ctrl[B_037_OFF]);
wire       n_shdw   = ~(roms01 | roms34) & ~mapper_ctrl[B_037_OFF];

// the three sequenced steps of a 177716 write (as the hardware does
// them): latch, precompute, apply
reg [1:0] step716 = 2'd0;
reg [1:0] step130 = 2'd0;
reg       apply_smk1 = 1'b0;

wire sel_map  = wr_stb && (wr_adr[15:5] == (16'o177300 >> 5));   // 177300-177336
wire sel_regs = wr_stb && (wr_adr[15:4] == (16'o177340 >> 4));   // 177340-177356
wire sel_716  = wr_stb && (wr_adr[15:1] == (16'o177716 >> 1)) && wr_data[11] && wr_wtbt[1];
wire sel_130  = wr_stb && (wr_adr[15:1] == (16'o177130 >> 1));

always @(posedge clk) begin
    step716 <= {step716[0], 1'b0};
    step130 <= {step130[0], 1'b0};

    if (cold) begin
        // ResetCold: everything off, the start ROM in window 15
        win_ctrl <= 16'o100000;
        win_ro   <= 16'd0;
        win_shdw <= 16'd0;
        mapper[15] <= 13'o100;
        mapper_ctrl <= {mapper_ctrl[15:2] & ~((14'd1 << (B_SMK_WND1 - 2)) | (14'd1 << (B_V100 - 2)) |
                                              (14'd1 << (B_014_OFF - 2)) | (14'd1 << (B_037_OFF - 2)) |
                                              (14'd1 << (B_REVTYPE - 2))), 2'b00};
        pre_b_ctrl <= 1'b0; pre_b_shdw <= 1'b0;
        pre_s_ctrl <= 8'd0; pre_s_ro <= 8'd0;
        for (i = 0; i < 8; i = i + 1) begin pre_b[i] <= 7'd0; pre_s[i] <= 8'd0; end
        smk_flag <= 1'b0;
        step716 <= 2'd0; step130 <= 2'd0;
    end else begin
        // the plain registers
        if (sel_map)  mapper[wr_adr[4:1]] <= wr_data[12:0];
        if (sel_regs) case (wr_adr[3:1])
            3'd0: win_ctrl <= wr_data;
            3'd1: win_ro   <= wr_data;
            3'd2: win_shdw <= wr_data;
            3'd3: mapper_ctrl <= {(mapper_ctrl[15:2] & (14'd1 << (B_REVTYPE - 2))) |
                                  (wr_data[15:2] & ~(14'd1 << (B_REVTYPE - 2))), 2'b00};   // bits 1:0 stay 0 (the hardware type is 4): driven, not kept
            default: ;   // 177350, 177352: read-only copies
        endcase

        // 177716, bit 11: the BK-0011M's memory word, translated
        if (sel_716) begin
            az716 <= wr_data;
            b_win0 <= win0_map;
            b_roms34 <= roms34;
            if (wr_data[1]) begin
                b_win1[0] <= 7'o124; b_win1[1] <= 7'o125; b_win1[2] <= 7'o122; b_win1[3] <= 7'o123;
            end else if (wr_data[0]) begin
                b_win1[0] <= 7'o126; b_win1[1] <= 7'o127; b_win1[2] <= 7'o130; b_win1[3] <= 7'o131;
            end else begin
                b_win1[0] <= {2'd0, win1_map, 2'd0}; b_win1[1] <= {2'd0, win1_map, 2'd1};
                b_win1[2] <= {2'd0, win1_map, 2'd2}; b_win1[3] <= {2'd0, win1_map, 2'd3};
            end
            pre_b[0] <= {2'd0, win0_map, 2'd0};
            pre_b[1] <= {2'd0, win0_map, 2'd1};
            pre_b[2] <= {2'd0, win0_map, 2'd2};
            pre_b[3] <= {2'd0, win0_map, 2'd3};
            if (wr_data[1]) begin
                pre_b[4] <= 7'o124; pre_b[5] <= 7'o125; pre_b[6] <= 7'o122; pre_b[7] <= 7'o123;
            end else if (wr_data[0]) begin
                pre_b[4] <= 7'o126; pre_b[5] <= 7'o127; pre_b[6] <= 7'o130; pre_b[7] <= 7'o131;
            end else begin
                pre_b[4] <= {2'd0, win1_map, 2'd0};
                pre_b[5] <= {2'd0, win1_map, 2'd1};
                pre_b[6] <= {2'd0, win1_map, 2'd2};
                pre_b[7] <= {2'd0, win1_map, 2'd3};
            end
            pre_b_ctrl <= n_ctrl;
            pre_b_shdw <= n_shdw;
            step716 <= 2'b01;
        end

        // 177130: the SMK's mode word, after its 6 flag
        if (sel_130) begin
            if (!smk_flag)
                smk_flag <= (wr_data == 16'd6);
            else begin
                smk_flag <= 1'b0;
                az130 <= wr_data;
                case (smk_mode)
                3'b111: begin   // Start
                    pre_s[7] <= 8'o100; pre_s[6] <= 8'o110;
                    pre_s[5] <= sp(smk_page, 3'd1); pre_s[4] <= sp(smk_page, 3'd0);
                    pre_s[3] <= sp(smk_page, 3'd7); pre_s[2] <= sp(smk_page, 3'd6);
                    pre_s_ctrl <= 8'b11111100; pre_s_ro <= 8'd0;
                end
                3'b011: begin   // Std10
                    pre_s[7] <= sp(smk_page, 3'd7); pre_s[6] <= 8'o110;
                    pre_s[5] <= sp(smk_page, 3'd5); pre_s[4] <= sp(smk_page, 3'd4);
                    pre_s[3] <= sp(smk_page, 3'd3); pre_s[2] <= sp(smk_page, 3'd2);
                    pre_s_ctrl <= 8'b11111100; pre_s_ro <= 8'd0;
                end
                3'b101: begin   // OZU10
                    for (i = 0; i < 8; i = i + 1) pre_s[i] <= sp(smk_page, i[2:0]);
                    pre_s_ctrl <= 8'b11111111; pre_s_ro <= 8'd0;
                end
                3'b001: begin   // All
                    pre_s[7] <= sp(smk_page, 3'd3); pre_s[6] <= sp(smk_page, 3'd2);
                    pre_s[5] <= sp(smk_page, 3'd1); pre_s[4] <= sp(smk_page, 3'd0);
                    pre_s[3] <= sp(smk_page, 3'd7); pre_s[2] <= sp(smk_page, 3'd6);
                    pre_s[1] <= sp(smk_page, 3'd5); pre_s[0] <= sp(smk_page, 3'd4);
                    pre_s_ctrl <= 8'b11111111; pre_s_ro <= 8'd0;
                end
                3'b110: begin   // Std11
                    pre_s[7] <= sp(smk_page, 3'd7); pre_s[6] <= 8'o110;
                    pre_s[5] <= 8'o121; pre_s[4] <= 8'o120;
                    pre_s_ctrl <= 8'b11110000; pre_s_ro <= 8'd0;
                end
                3'b010: begin   // OZU11
                    pre_s[7] <= sp(smk_page, 3'd7); pre_s[6] <= sp(smk_page, 3'd6);
                    pre_s[5] <= sp(smk_page, 3'd5); pre_s[4] <= sp(smk_page, 3'd4);
                    pre_s_ctrl <= 8'b11110000; pre_s_ro <= 8'd0;
                end
                3'b100: begin   // HLT10
                    for (i = 0; i < 8; i = i + 1) pre_s[i] <= sp(smk_page, i[2:0]);
                    pre_s_ctrl <= 8'b11111111; pre_s_ro <= 8'b00000001;
                end
                default: begin  // HLT11
                    pre_s[7] <= sp(smk_page, 3'd7); pre_s[6] <= sp(smk_page, 3'd6);
                    pre_s[5] <= sp(smk_page, 3'd5); pre_s[4] <= sp(smk_page, 3'd4);
                    pre_s_ctrl <= 8'b11110000; pre_s_ro <= 8'd0;
                end
                endcase
                apply_smk1 <= wr_data[4];
                step130 <= 2'b01;
            end
        end

        // apply the BK-0011M's word (AZ_MemoryManager)
        if (step716[1]) begin
            mapper[0] <= 13'o030; mapper[1] <= 13'o031;
            mapper[2] <= 13'o032; mapper[3] <= 13'o033;
            mapper[4] <= {6'd0, pre_b[0]}; mapper[5] <= {6'd0, pre_b[1]};
            mapper[6] <= {6'd0, pre_b[2]}; mapper[7] <= {6'd0, pre_b[3]};
            win_ctrl[7:0] <= {8{mapper_ctrl[B_037_OFF]}};
            win_shdw[7:0] <= {8{~mapper_ctrl[B_037_OFF]}};
            win_ro[7:0]   <= 8'd0;
            if (!mapper_ctrl[B_SMK_WND1]) begin
                mapper[8]  <= {6'd0, pre_b[4]}; mapper[9]  <= {6'd0, pre_b[5]};
                mapper[10] <= {6'd0, pre_b[6]}; mapper[11] <= {6'd0, pre_b[7]};
                win_ctrl[11:8] <= {4{pre_b_ctrl}};
                win_shdw[11:8] <= {4{pre_b_shdw}};
                win_ro[11:8]   <= 4'd0;
            end else begin
                mapper[8]  <= {5'd0, pre_s[0]}; mapper[9]  <= {5'd0, pre_s[1]};
                mapper[10] <= {5'd0, pre_s[2]}; mapper[11] <= {5'd0, pre_s[3]};
                win_ctrl[11:8] <= pre_s_ctrl[3:0];
                win_shdw[11:8] <= 4'd0;
                win_ro[11:8]   <= pre_s_ro[3:0];
            end
        end

        // apply the SMK's word (AltPro_MemoryManager)
        if (step130[1]) begin
            mapper[15] <= {5'd0, pre_s[7]}; mapper[14] <= {5'd0, pre_s[6]};
            mapper[13] <= {5'd0, pre_s[5]}; mapper[12] <= {5'd0, pre_s[4]};
            win_ctrl[15:12] <= pre_s_ctrl[7:4];
            win_ro[15:12]   <= pre_s_ro[7:4];
            win_shdw[15:12] <= 4'd0;
            if (apply_smk1) begin
                mapper[8]  <= {5'd0, pre_s[0]}; mapper[9]  <= {5'd0, pre_s[1]};
                mapper[10] <= {5'd0, pre_s[2]}; mapper[11] <= {5'd0, pre_s[3]};
                win_ctrl[11:8] <= pre_s_ctrl[3:0];
                win_ro[11:8]   <= pre_s_ro[3:0];
                win_shdw[11:8] <= 4'd0;
            end else begin
                mapper[8]  <= {6'd0, pre_b[4]}; mapper[9]  <= {6'd0, pre_b[5]};
                mapper[10] <= {6'd0, pre_b[6]}; mapper[11] <= {6'd0, pre_b[7]};
                win_ctrl[11:8] <= {4{pre_b_ctrl}};
                win_ro[11:8]   <= 4'd0;
                win_shdw[11:8] <= {4{pre_b_shdw}};
            end
            mapper_ctrl[B_SMK_WND1] <= apply_smk1;
        end
    end
end

endmodule

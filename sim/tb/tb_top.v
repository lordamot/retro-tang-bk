//========================================================================
// Top-level testbench: the whole machine, with the SDRAM modelled, the
// AZBK's ROM set in it, and a stand-in for the BL616 that also plays
// the AZ controller's STM32 - the MCU side of azctrl.v.
//========================================================================
// Plusargs:
//   +VCD          dump sim/out/tb_top.vcd (large)
//   +VIDEO_PPM    write each decoded frame as a .ppm
//   +RUN_MS=<n>   how long to run, in simulated milliseconds (default 40)
//   +NOFASTBOOT   do not shortcut the 130 ms power-on reset counter
//   +ROMDIR=<dir> where the ROM files are (default soft/azbk/ROM)
//   +NOROM        load no ROMs (the processor runs zeros)
//   +ROMSPI       send the ROMs over SYS CMD 6 as the firmware does, not into the model
//   +D0= +D1= +D2= +D3=<file>  the disk images of units 0..3 (defaults
//                 soft/azbk/DISKS/WRKANDOS2.IMG and nothing else)
//   +EEPROM=<file>  the controller's settings block (default soft/azbk/eeprom.dat)
//   +CPUTRACE     every bus cycle the processor starts: address, direction,
//                 and the word when it is acknowledged
//   +IOTRACE      every I/O-page access
//   +AZTRACE      every AZ command and what the stand-in did with it
//   +TRACE_MS=<n> hold the traces off until n ms
//   +SPITRACE     every byte the MCU stand-in gets into sysctrl
//   +RSTTRACE     the reset chain: request, DCLO, ACLO, INIT
//   +MAPTRACE     the mapper's control word, the cold resets, the start flag
//   +CYCTRACE=<us> from that microsecond, for +CYCLEN=<us> (default 100):
//                 every processor clock inside the VM1 (+CORETRACE is the
//                 same from 69 ms, every 200 us), every clock of the bus
//                 while a cycle is on (+BUSALL: every clock), and with
//                 +MEMTRACE every clock of a memory cycle in top.v
//   +PPM_MAX=<n>  cap how many .ppm frames are written (default 4)
//   +PPM_EVERY=<n>  write every n-th frame only (default 1)
//   +PPM_FROM=<n> skip the frames before n ms
//   +NOMEMCHECK   turn off the read-after-write check on the SDRAM
//   +WAV=<file> +WAV_FROM=<ms>  the sound output as raw s16le stereo, 50625 pairs a second, from that time
//   +HDMIDBG      print every data island packet the decoder sees
//   +NODECODE     no TMDS decode before +PPM_FROM (faster long runs)
//   +TURBO=<n>    the OSD's turbo switch: 0 4 MHz (default), 1 8 MHz
//   +KEYS=<codes> press and release these КОИ-7 codes in turn (hex pairs) at +TYPE_MS=<n> (default 2500)
//   +TYPE_STR=<text>  type the text ('_' for a space) and Enter, +TYPE_DELAY=<ms> after the keys
//   +KEYS2=<codes> +KEYS2_MS=<ms>, +KEYS3=/+KEYS3_MS=  more keys at their own times
//   +RESETKEY_MS=<ms>  press and release the СБР key (F11) at that time
//   +HOTKEY=<n> +HOTKEY_MS=<ms>  the controller's hotkey n (1: 512/256, 2: the palette reset)
//   +RAMDUMP      write the SDRAM's words to sim/out/ram.hex at the end
//
// Every delay in milliseconds is `ms * 64'd1000000`: a 32-bit product
// wraps past 4294 ms.
//
// The SPI master, the HDMI decoder and the .ppm writer are UKNC Nano's
// through ZS-256 Nano's; the AZ service and the checks are this machine's.
//========================================================================
`timescale 1ns / 1ps

module tb_top;

    //--------------------------------------------------------------------
    // Clock and board inputs
    //--------------------------------------------------------------------
    reg clk27 = 1'b0;
    always #18.518 clk27 = ~clk27;      // 27 MHz

    reg  [1:0] buts = 2'b00;
    wire [5:0] leds;

    wire uart_tx;
    reg  uart_rx = 1'b1;

    wire sdclk;
    wire sdcmd, sddat0, sddat1, sddat2, sddat3;
    pullup (sdcmd); pullup (sddat0); pullup (sddat1);
    pullup (sddat2); pullup (sddat3);

    wire       O_tmds_clk_p, O_tmds_clk_n;
    wire [2:0] O_tmds_data_p, O_tmds_data_n;

    wire HP_BCK, HP_WS, HP_DIN, PA_EN;

    wire        O_sdram_clk, O_sdram_cke, O_sdram_cs_n;
    wire        O_sdram_cas_n, O_sdram_ras_n, O_sdram_wen_n;
    wire [3:0]  O_sdram_dqm;
    wire [10:0] O_sdram_addr;
    wire [1:0]  O_sdram_ba;
    wire [31:0] IO_sdram_dq;

    reg  spi_io_ss  = 1'b1;
    reg  spi_io_clk = 1'b0;
    reg  spi_io_din = 1'b0;

    wire [4:0] m0s;
    assign m0s[1] = spi_io_din ;
    assign m0s[2] = spi_io_ss  ;
    assign m0s[3] = spi_io_clk ;
    wire spi_io_dout = m0s[0];
    wire mcu_intn    = m0s[4];

    //--------------------------------------------------------------------
    // The design
    //--------------------------------------------------------------------
    wire reconfig_n;
    wire mspi_clk, mspi_cs_n, mspi_do;
    wire mspi_di = 1'b1;
    top uut (
        .clk27(clk27), .buts(buts), .leds(leds),
        .uart_tx(uart_tx), .uart_rx(uart_rx),
        .sdclk(sdclk), .sdcmd(sdcmd),
        .sddat0(sddat0), .sddat1(sddat1), .sddat2(sddat2), .sddat3(sddat3),
        .O_tmds_clk_p(O_tmds_clk_p),   .O_tmds_clk_n(O_tmds_clk_n),
        .O_tmds_data_p(O_tmds_data_p), .O_tmds_data_n(O_tmds_data_n),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .O_sdram_clk(O_sdram_clk),     .O_sdram_cke(O_sdram_cke),
        .O_sdram_cs_n(O_sdram_cs_n),   .O_sdram_cas_n(O_sdram_cas_n),
        .O_sdram_ras_n(O_sdram_ras_n), .O_sdram_wen_n(O_sdram_wen_n),
        .O_sdram_dqm(O_sdram_dqm),     .O_sdram_addr(O_sdram_addr),
        .O_sdram_ba(O_sdram_ba),       .IO_sdram_dq(IO_sdram_dq),
        .m0s(m0s),
        .reconfig_n(reconfig_n),
        .mspi_clk(mspi_clk), .mspi_cs_n(mspi_cs_n),
        .mspi_do(mspi_do),   .mspi_di(mspi_di)
    );

    //--------------------------------------------------------------------
    // Memory.  sdram.v uses read bursts of four, CAS 2, 32 bits.
    //--------------------------------------------------------------------
    sdram_model #(.BURST(4)) ram (
        .clk(O_sdram_clk), .cke(O_sdram_cke),
        .cs_n(O_sdram_cs_n), .ras_n(O_sdram_ras_n),
        .cas_n(O_sdram_cas_n), .we_n(O_sdram_wen_n),
        .ba(O_sdram_ba), .a(O_sdram_addr),
        .dqm(O_sdram_dqm), .dq(IO_sdram_dq)
    );

    // a file into the model, a byte at a time into the word/lane layout
    // poke.v uses: word = byte address / 4, lane = its bits 1:0
    task load_image(input [1023:0] name, input integer base, output integer n);
        integer fd, c, w;
        reg [31:0] v;
        begin
            n = 0;
            fd = $fopen(name, "rb");
            if (fd == 0) $display("[tb] cannot open %0s", name);
            else begin
                c = $fgetc(fd);
                while (c != -1) begin
                    w = base + n;
                    v = ram.mem[w >> 2];
                    case (w & 3)
                        0: v[7:0]   = c[7:0];
                        1: v[15:8]  = c[7:0];
                        2: v[23:16] = c[7:0];
                        3: v[31:24] = c[7:0];
                    endcase
                    ram.mem[w >> 2] = v;
                    n = n + 1;
                    c = $fgetc(fd);
                end
                $fclose(fd);
                $display("[tb] %0s: %0d bytes into the SDRAM model at %06x", name, n, base);
            end
        end
    endtask

    // the same file read back out of the model, byte by byte, against
    // what the poke should have left there (+ROMSPI's check)
    task verify_image(input [1023:0] name, input integer base, output integer bad);
        integer fd, c, w, n;
        reg [31:0] v;
        reg [7:0] b;
        begin
            bad = 0; n = 0;
            fd = $fopen(name, "rb");
            if (fd != 0) begin
                c = $fgetc(fd);
                while (c != -1) begin
                    w = base + n;
                    v = ram.mem[w >> 2];
                    case (w & 3)
                        0: b = v[7:0];
                        1: b = v[15:8];
                        2: b = v[23:16];
                        3: b = v[31:24];
                    endcase
                    if (b !== c[7:0]) begin
                        if (bad < 8) $display("[tb] *** poke mismatch %0s +%0d (%06x): model %02x file %02x", name, n, w, b, c[7:0]);
                        bad = bad + 1;
                    end
                    n = n + 1;
                    c = $fgetc(fd);
                end
                $fclose(fd);
                $display("[tb] %0t %0s: %0d bytes verified, %0d wrong", $time, name, n, bad);
            end
        end
    endtask

    // the same file the firmware's way: SYS CMD 6 with three address bytes,
    // then the bytes, 512 a transaction (sys_poke24 in mnano/sysctrl.c)
    task poke_image(input [1023:0] name, input integer base, output integer n);
        integer fd, c, k;
        begin
            n = 0;
            fd = $fopen(name, "rb");
            if (fd == 0) $display("[tb] cannot open %0s", name);
            else begin
                c = $fgetc(fd);
                while (c != -1) begin
                    spi_begin;
                    spi_byte(8'd0);
                    spi_byte(8'd6);
                    spi_byte((base + n) >> 16);
                    spi_byte((base + n) >> 8);
                    spi_byte(base + n);
                    k = 0;
                    while (c != -1 && k < 512) begin
                        spi_byte(c[7:0]);
                        n = n + 1; k = k + 1;
                        c = $fgetc(fd);
                    end
                    spi_end;
                    #2000;
                end
                $fclose(fd);
                $display("[tb] %0t %0s: %0d bytes poked at %06x", $time, name, n, base);
            end
        end
    endtask

    // the ROM set as AZ.INI names it: slot n at page 100+n (4 KB), the logo at page 40
    reg [1023:0] romdir;
    reg romspi;
    reg [1023:0] rname;
    integer rn, rtot, rbad, rbadtot, pk_bad, pk_noans;
    task load_rom(input [255:0] file, input integer slot);
        begin
            $sformat(rname, "%0s/%0s", romdir, file);
            if (romspi) begin poke_image(rname, 32'h40000 + slot * 4096, rn); verify_image(rname, 32'h40000 + slot * 4096, rbad); rbadtot = rbadtot + rbad; end
            else        load_image(rname, 32'h40000 + slot * 4096, rn);
            rtot = rtot + rn;
        end
    endtask

    //--------------------------------------------------------------------
    // A minimal BL616: SPI master, mode 1, MSB first.
    //--------------------------------------------------------------------
    localparam SPI_HALF = 25;           // ns; 20 MHz like the real firmware
    localparam SPI_HOLD = 5;

    reg [7:0] spi_rx;

    task spi_byte(input [7:0] tx);
        integer b;
        begin
            for (b = 7; b >= 0; b = b - 1) begin
                spi_io_din  = tx[b];
                #SPI_HALF spi_io_clk = 1'b1;
                #SPI_HALF spi_io_clk = 1'b0;
                #SPI_HOLD;
                spi_rx = {spi_rx[6:0], spi_io_dout};
            end
            #(SPI_HALF * 20);
        end
    endtask

    task spi_begin; begin spi_io_ss = 1'b0; #SPI_HALF; end endtask
    task spi_end;   begin #SPI_HALF spi_io_ss = 1'b1; #(SPI_HALF*4); end endtask

    // SYS command 4: set a configuration value
    task sys_set_val(input [7:0] id, input [7:0] val);
        begin
            spi_begin;
            spi_byte(8'd0);     // target SYS
            spi_byte(8'd4);     // command "set value"
            spi_byte(id);
            spi_byte(val);
            spi_end;
        end
    endtask

    // HID command 1: a keyboard event, code then flags (usb_host.c's kbd_tx_bk)
    task hid_key(input [7:0] code, input [7:0] flags);
        begin
            spi_begin;
            spi_byte(8'd1);     // target HID
            spi_byte(8'd1);     // keyboard
            spi_byte(code);
            spi_byte(flags);
            spi_end;
        end
    endtask

    // press and release a key: held for 70 ms
    localparam KEY_HOLD = 70000000;
    task key(input [7:0] code);
        begin
            hid_key(code, 8'h00);
            #KEY_HOLD;
            hid_key(code, 8'h01);
            #KEY_HOLD;
        end
    endtask

    task type_string(input [8*255:1] str);
        integer n, i;
        reg [7:0] c;
        begin
            n = 0;
            for (i = 0; i < 255; i = i + 1) if (str[8*(i+1) -: 8] != 8'd0) n = i + 1;
            for (i = n - 1; i >= 0; i = i - 1) begin
                c = str[8*(i+1) -: 8];
                if (c == "_") c = " ";
                if (c >= "a" && c <= "z") c = c - 8'h20;
                key(c);
            end
        end
    endtask

    reg [7:0] st0, st1, st2, st3;

    // Exactly what sys_status_is_valid() in mnano/sysctrl.c does.
    task sys_status;
        begin
            spi_begin;
            spi_byte(8'd0);
            spi_byte(8'd0);
            spi_byte(8'h00);
            spi_byte(8'h00);  st0 = spi_rx;
            spi_byte(8'h00);  st1 = spi_rx;
            spi_byte(8'h00);  st2 = spi_rx;
            spi_byte(8'h00);  st3 = spi_rx;
            spi_end;
        end
    endtask

    // SYS command 8: a word out of the SDRAM, exactly as sysctrl.c's
    // sys_peek24 asks for it - the three address bytes, a pause, a byte
    // for the ready flag to be set, the ready byte, the four bytes
    reg [31:0] peek_word;
    reg        peek_ok;
    task sys_peek(input [23:0] adr);
        begin
            spi_begin;
            spi_byte(8'd0);
            spi_byte(8'd8);
            spi_byte(adr[23:16]);
            spi_byte(adr[15:8]);
            spi_byte(adr[7:0]);
            #5000;
            spi_byte(8'h00);
            spi_byte(8'h00);  peek_ok = spi_rx[0];
            spi_byte(8'h00);  peek_word[7:0]   = spi_rx;
            spi_byte(8'h00);  peek_word[15:8]  = spi_rx;
            spi_byte(8'h00);  peek_word[23:16] = spi_rx;
            spi_byte(8'h00);  peek_word[31:24] = spi_rx;
            spi_end;
        end
    endtask

    // n words from base read back over the link against the model
    // (which verify_image has already held against the file)
    task peek_check(input integer base, input integer n, output integer bad, output integer noans);
        integer i;
        begin
            bad = 0; noans = 0;
            for (i = 0; i < n; i = i + 1) begin
                sys_peek(base + 4 * i);
                if (!peek_ok) noans = noans + 1;
                else if (peek_word !== ram.mem[(base >> 2) + i]) begin
                    if (bad < 8) $display("[tb] *** peek mismatch %06x: link %08x model %08x", base + 4 * i, peek_word, ram.mem[(base >> 2) + i]);
                    bad = bad + 1;
                end
            end
        end
    endtask

    // SYS command 7: the debug window
    reg [7:0] dbgb [0:31];

    // the blitter's runs: how long, and how many outlast the vertical blanking
    integer blit_runs = 0, blit_max = 0, blit_over = 0, blit_len = 0;
    reg blit_d = 1'b0;
    always @(posedge uut.clk) begin
        blit_d <= uut.blt.running;
        if (uut.blt.running) blit_len = blit_len + 1;
        if (blit_d && !uut.blt.running) begin
            blit_runs = blit_runs + 1;
            if (blit_len > blit_max) blit_max = blit_len;
            if (blit_len > 37 * 1344) blit_over = blit_over + 1;
            blit_len = 0;
        end
    end
    integer dbg_i, dbg_o;
    task sys_debug;
        begin
            for (dbg_o = 0; dbg_o < 32; dbg_o = dbg_o + 8) begin
                spi_begin;
                spi_byte(8'd0);
                spi_byte(8'd7);
                spi_byte(dbg_o[7:0]);
                for (dbg_i = 0; dbg_i < 8; dbg_i = dbg_i + 1) begin
                    spi_byte(8'h00);
                    dbgb[dbg_o + dbg_i] = spi_rx;
                end
                spi_end;
            end
        end
    endtask

    //--------------------------------------------------------------------
    // The AZ controller's MCU: SPI target 4 (azctrl.v's header has the
    // bytes).  A command is noticed by watching the design's interrupt
    // line, read out with STATUS, served, and answered with DONE.
    //--------------------------------------------------------------------
    localparam [12:0] R_IOBUF = 13'd0, R_CMOS = 13'd256, R_IP = 13'd512, R_SIZE = 13'd528,
                      R_TS = 13'd544, R_USIZE = 13'd576, R_TABLE = 13'd1024;

    reg [7:0]  az_cmd; reg az_pending; reg [7:0] az_unit; reg [31:0] az_blkn; reg az_ie;
    reg [12:0] az_written; reg [7:0] az_seq;
    task az_status;
        begin
            spi_begin;
            spi_byte(8'd4); spi_byte(8'd1);
            spi_byte(8'h00); az_pending = spi_rx[7]; az_cmd = {2'd0, spi_rx[5:0]};
            spi_byte(8'h00); az_unit = spi_rx;
            spi_byte(8'h00); az_blkn[31:24] = spi_rx;
            spi_byte(8'h00); az_blkn[23:16] = spi_rx;
            spi_byte(8'h00); az_blkn[15:8] = spi_rx;
            spi_byte(8'h00); az_blkn[7:0] = spi_rx;
            spi_byte(8'h00); az_ie = spi_rx[0];
            spi_byte(8'h00); az_written[12:8] = spi_rx[4:0];
            spi_byte(8'h00); az_written[7:0] = spi_rx;
            spi_byte(8'h00); az_seq = spi_rx;
            spi_end;
        end
    endtask

    reg [15:0] az_buf [0:8191];      // the stand-in's copy of what it moves
    task az_write(input [12:0] adr, input integer n);
        integer i;
        begin
            spi_begin;
            spi_byte(8'd4); spi_byte(8'd3);
            spi_byte({3'd0, adr[12:8]}); spi_byte(adr[7:0]);
            for (i = 0; i < n; i = i + 1) begin
                spi_byte(az_buf[i][7:0]); spi_byte(az_buf[i][15:8]);
            end
            spi_end;
        end
    endtask
    task az_read(input [12:0] adr, input integer n);
        integer i;
        begin
            spi_begin;
            spi_byte(8'd4); spi_byte(8'd2);
            spi_byte({3'd0, adr[12:8]}); spi_byte(adr[7:0]);
            spi_byte(8'h00);            // the first word is set up at the address byte's strobe
            for (i = 0; i < n; i = i + 1) begin
                spi_byte(8'h00); az_buf[i][7:0] = spi_rx;
                spi_byte(8'h00); az_buf[i][15:8] = spi_rx;
            end
            spi_end;
        end
    endtask
    task az_done(input err, input big, input [12:0] rd_base, input [12:0] rd_cnt,
                 input [12:0] wr_base, input [12:0] wr_cnt, input [12:0] rd_buf, input [12:0] init,
                 input [31:0] usize, input uvalid, input [4:0] unum);
        begin
            spi_begin;
            spi_byte(8'd4); spi_byte(8'd4);
            spi_byte({6'd0, big, err});
            spi_byte({3'd0, rd_base[12:8]}); spi_byte(rd_base[7:0]);
            spi_byte({3'd0, rd_cnt[12:8]});  spi_byte(rd_cnt[7:0]);
            spi_byte({3'd0, wr_base[12:8]}); spi_byte(wr_base[7:0]);
            spi_byte({3'd0, wr_cnt[12:8]});  spi_byte(wr_cnt[7:0]);
            spi_byte({3'd0, rd_buf[12:8]});  spi_byte(rd_buf[7:0]);
            spi_byte({3'd0, init[12:8]});    spi_byte(init[7:0]);
            spi_byte(usize[31:24]); spi_byte(usize[23:16]); spi_byte(usize[15:8]); spi_byte(usize[7:0]);
            spi_byte({uvalid, 2'd0, unum});
            spi_end;
        end
    endtask

    // the units: files, sizes in blocks
    reg [1023:0] unit_file [0:3];
    integer      unit_fd [0:3];
    integer      unit_blocks [0:3];
    integer      cur_unit = -1;
    reg [31:0]   cur_size = 0;
    integer      ui, uc, ub, ux;
    integer      az_cmds = 0, az_reads = 0, az_writes = 0, az_errs = 0;
    reg          az_trace = 1'b0;
    reg [1023:0] eeprom_file;
    integer      efd;

    task az_serve;
        reg err; reg [12:0] rdb, rdc, wrb, wrc, rbf, ini;
        integer c;
        begin
            az_status;
            if (!az_pending) begin end
            else begin
                az_cmds = az_cmds + 1;
                err = 0; rdb = 0; rdc = 0; wrb = 0; wrc = 0; rbf = R_IOBUF; ini = 256;
                case (az_cmd)
                8'o01: begin   // select unit: the FPGA's own since 23 Sep 2026 (from the size table); never here
                    err = 1;
                    $display("[tb] *** a select (001) reached the MCU stand-in");
                    cfg_errs = cfg_errs + 1;
                end
                8'o05: begin   // read a block into IOBUF, of the unit the status names
                    ux = az_unit[4:0];
                    cur_unit = az_unit[7] ? ux : -1; cur_size = unit_blocks[ux];
                    if (cur_unit < 0 || ux > 3 || unit_fd[ux] == 0 || az_blkn >= cur_size) err = 1;
                    else begin
                        $fseek(unit_fd[cur_unit], az_blkn * 512, 0);
                        for (ui = 0; ui < 256; ui = ui + 1) begin
                            c = $fgetc(unit_fd[cur_unit]); az_buf[ui][7:0] = c[7:0];
                            c = $fgetc(unit_fd[cur_unit]); az_buf[ui][15:8] = c[7:0];
                        end
                        az_write(R_IOBUF, 256);
                        az_reads = az_reads + 1;
                    end
                    if (az_trace) $display("[az] %0t read unit %0d block %0d -> %s", $time, cur_unit, az_blkn, err ? "ERR" : "ok");
                end
                8'o06: begin   // write a block: taken out and dropped (the host file is not changed)
                    ux = az_unit[4:0];
                    cur_unit = az_unit[7] ? ux : -1; cur_size = unit_blocks[ux];
                    if (cur_unit < 0 || ux > 3 || unit_fd[ux] == 0 || az_blkn >= cur_size) err = 1;
                    else begin az_read(R_IOBUF, 256); az_writes = az_writes + 1; end
                    if (az_trace) $display("[az] %0t write unit %0d block %0d -> %s", $time, cur_unit, az_blkn, err ? "ERR" : "ok");
                end
                8'o21: begin   // the EEPROM block into CMOS: status word, then 255 words
                    efd = $fopen(eeprom_file, "rb");
                    az_buf[0] = (efd == 0) ? 16'd1 : 16'd0;
                    for (ui = 1; ui < 256; ui = ui + 1) begin
                        if (efd != 0) begin c = $fgetc(efd); az_buf[ui][7:0] = c[7:0]; c = $fgetc(efd); az_buf[ui][15:8] = c[7:0]; end
                        else az_buf[ui] = 16'd0;
                    end
                    if (efd != 0) $fclose(efd);
                    az_write(R_CMOS, 256);
                    if (az_trace) $display("[az] %0t eeprom read (%s)", $time, (efd == 0) ? "no file" : "ok");
                end
                8'o24: begin   // the EEPROM written: taken out, kept in az_buf only
                    az_read(R_CMOS, 256);
                    if (az_trace) $display("[az] %0t eeprom write", $time);
                end
                8'o31, 8'o42: begin   // the time: 19 Sep 2026, 12:00:00, a Saturday
                    az_buf[0] = ((54 / 32) << 14) | (9 << 10) | (19 << 5) | (54 % 32);   // rt11date: year 2026-1972 = 54
                    az_buf[1] = 16'd32; az_buf[2] = 16'd60096;   // 12*3600*50 = 2160000 = 0x20F5C0
                    az_buf[3] = 16'd39; az_buf[4] = 16'd35136;   // 12*3600*60 = 2592000 = 0x278D00
                    az_buf[5] = (19) | (9 << 5) | ((2026 - 1980) << 9);
                    az_buf[6] = (12 << 11);
                    az_buf[7] = 16'd2026; az_buf[8] = 16'd9; az_buf[9] = 16'd19; az_buf[10] = 16'd6;
                    az_buf[11] = 16'd12; az_buf[12] = 16'd0; az_buf[13] = 16'd0;
                    az_write(R_TS, 14);
                    if (az_trace) $display("[az] %0t time", $time);
                end
                8'o11: begin   // the units table: 32 entries of 198 words
                    for (ui = 0; ui < 32 * 198; ui = ui + 1) az_buf[ui] = 16'd0;
                    for (uc = 0; uc < 4; uc = uc + 1) if (unit_fd[uc] != 0) begin
                        az_buf[uc*198 + 0] = unit_blocks[uc][15:0];
                        az_buf[uc*198 + 1] = unit_blocks[uc][31:16];
                        az_buf[uc*198 + 4] = 16'h0005;   // flag CFG|MTD, attr 0
                        // the name: "0:/DISKS/Dn.IMG"
                        az_buf[uc*198 + 5] = {8'h3A, 8'h30}; az_buf[uc*198 + 6] = {8'h44, 8'h2F};
                        az_buf[uc*198 + 7] = {8'h53, 8'h49}; az_buf[uc*198 + 8] = {8'h53, 8'h4B};
                        az_buf[uc*198 + 9] = {8'h44, 8'h2F}; az_buf[uc*198 + 10] = {8'h2E, 8'h30 + uc[7:0]};
                        az_buf[uc*198 + 11] = {8'h4D, 8'h49}; az_buf[uc*198 + 12] = {8'h00, 8'h47};
                    end
                    az_write(R_TABLE, 32 * 198);
                    rbf = R_TABLE; ini = 32 * 198;
                    if (az_trace) $display("[az] %0t units table", $time);
                end
                8'o25, 8'o26: begin   // HOF: no network
                    // {"RESULT":"ERROR","DESCRIPTION":"CONNECTION_ERROR"}
                    begin : hof
                        reg [8*52:1] js; integer j;
                        js = "{\"RESULT\":\"ERROR\",\"DESCRIPTION\":\"CONNECTION_ERROR\"}";
                        for (j = 0; j < 256; j = j + 1) az_buf[j] = 16'd0;
                        for (j = 0; j < 52; j = j + 1) begin
                            if (j % 2 == 0) az_buf[j/2][7:0]  = js[8*(52-j) -: 8];
                            else            az_buf[j/2][15:8] = js[8*(52-j) -: 8];
                        end
                        az_write(R_CMOS, 256);
                    end
                    if (az_trace) $display("[az] %0t HOF %0o -> connection error", $time, az_cmd);
                end
                8'o03, 8'o13, 8'o04, 8'o14, 8'o44, 8'o47, 8'o50, 8'o51, 8'o52, 8'o53, 8'o54, 8'o55: begin
                    err = 1;
                    if (az_trace) $display("[az] %0t command %0o -> ERR (not served here)", $time, az_cmd);
                end
                8'o56: begin
                    az_buf[0] = 16'd15185; az_buf[1] = 16'd15119;
                    az_write(R_SIZE, 2);
                end
                8'o34: begin
                    if (az_trace) $display("[az] %0t set time", $time);
                end
                default: begin
                    err = 1;
                    if (az_trace) $display("[az] %0t command %0o -> ERR (unknown)", $time, az_cmd);
                end
                endcase
                if (err) az_errs = az_errs + 1;
                az_done(err, 1'b0, rdb, rdc, wrb, wrc, rbf, ini, cur_size, cur_unit >= 0, cur_unit[4:0]);
            end
        end
    endtask

    //--------------------------------------------------------------------
    // Run
    //--------------------------------------------------------------------
    integer run_ms, type_ms, type_delay, keys2_ms, keys3_ms, turbo_n, magic_ms, resetkey_ms, hotkey_n, hotkey_ms;
    reg [8*255:1] type_str, keys_str;
    integer tries, ki, kn;
    reg     fastboot;
    integer cfg_errs = 0;
    reg     az_on = 1'b0;

    initial begin
        if (!$value$plusargs("RUN_MS=%d", run_ms)) run_ms = 40;
        fastboot = !$test$plusargs("NOFASTBOOT");
        az_trace = $test$plusargs("AZTRACE");

        if ($test$plusargs("VCD")) begin
            $dumpfile("sim/out/tb_top.vcd");
            $dumpvars(0, tb_top);
        end

        // the ROM set into the model before anything runs (or, +ROMSPI,
        // over the link once the FPGA answers, as the firmware does it)
        if (!$value$plusargs("ROMDIR=%s", romdir)) romdir = "soft/azbk/ROM";
        rtot = 0; rbadtot = 0;
        romspi = $test$plusargs("ROMSPI");
        if (!$test$plusargs("NOROM") && !romspi) begin
            load_rom("azboot.ROM", 0);
            load_rom("AZLIB00.ROM", 1);  load_rom("AZLIB01.ROM", 2);
            load_rom("AZLIB02.ROM", 3);  load_rom("AZLIB03.ROM", 4);
            load_rom("AZ337.ROM", 8);
            load_rom("11M_324.ROM", 16); load_rom("11M_325.ROM", 18);
            load_rom("11M_327.ROM", 20); load_rom("11M_328.ROM", 22);
            load_rom("11M_329.ROM", 24); load_rom("11M_330.ROM", 26);
            load_rom("10_017.ROM", 28);  load_rom("10_018.ROM", 30);
            load_rom("10_019.ROM", 32);  load_rom("10_106.ROM", 34);
            load_rom("10_107.ROM", 36);  load_rom("10_108.ROM", 38);
            load_rom("SETUP.ROM", 56);
            $sformat(rname, "%0s/AZLOGO.RAW", romdir);
            load_image(rname, 32'h20000, rn);
            $display("[tb] ROM set: %0d bytes", rtot);
        end

        // the units
        for (ui = 0; ui < 4; ui = ui + 1) begin unit_fd[ui] = 0; unit_blocks[ui] = 0; end
        if (!$value$plusargs("D0=%s", unit_file[0])) unit_file[0] = "soft/azbk/DISKS/WRKANDOS2.IMG";
        if (!$value$plusargs("D1=%s", unit_file[1])) unit_file[1] = "";
        if (!$value$plusargs("D2=%s", unit_file[2])) unit_file[2] = "";
        if (!$value$plusargs("D3=%s", unit_file[3])) unit_file[3] = "";
        for (ui = 0; ui < 4; ui = ui + 1) if (unit_file[ui] != 0) begin
            unit_fd[ui] = $fopen(unit_file[ui], "rb");
            if (unit_fd[ui] != 0) begin
                $fseek(unit_fd[ui], 0, 2);
                unit_blocks[ui] = ($ftell(unit_fd[ui]) + 511) / 512;
                $display("[tb] unit %0d: %0s, %0d blocks", ui, unit_file[ui], unit_blocks[ui]);
            end else $display("[tb] unit %0d: cannot open %0s", ui, unit_file[ui]);
        end
        if (!$value$plusargs("EEPROM=%s", eeprom_file)) eeprom_file = "soft/azbk/eeprom.dat";

        if (fastboot) begin
            wait (uut.init);
            #20000;
            force uut.count_rst = 24'h7FFFF0;
            #20000;
            release uut.count_rst;
            $display("[tb] %0t fastboot: count_rst forced", $time);
        end

        tries = 0;
        st0 = 0; st1 = 0; st2 = 0;
        while (tries < 200 && !(st0 == 8'h5c && st1 == 8'h42)) begin
            #100000;
            sys_status;
            tries = tries + 1;
        end

        if (st0 == 8'h5c && st1 == 8'h42)
            $display("[tb] %0t FPGA ready, core id 0x%02x (expect 0a = BK Nano)", $time, st2);
        else begin
            $display("[tb] %0t FPGA never answered (got %02x %02x %02x)", $time, st0, st1, st2);
            cfg_errs = cfg_errs + 1;
        end
        if (st2 !== 8'h0a) cfg_errs = cfg_errs + 1;

        sys_set_val("R", 8'd3);
        #50000;
        if (romspi) begin
            load_rom("azboot.ROM", 0);
            load_rom("AZLIB00.ROM", 1);  load_rom("AZLIB01.ROM", 2);
            load_rom("AZLIB02.ROM", 3);  load_rom("AZLIB03.ROM", 4);
            load_rom("AZ337.ROM", 8);
            load_rom("11M_324.ROM", 16); load_rom("11M_325.ROM", 18);
            load_rom("11M_327.ROM", 20); load_rom("11M_328.ROM", 22);
            load_rom("11M_329.ROM", 24); load_rom("11M_330.ROM", 26);
            load_rom("10_017.ROM", 28);  load_rom("10_018.ROM", 30);
            load_rom("10_019.ROM", 32);  load_rom("10_106.ROM", 34);
            load_rom("10_107.ROM", 36);  load_rom("10_108.ROM", 38);
            load_rom("SETUP.ROM", 56);
            $sformat(rname, "%0s/AZLOGO.RAW", romdir);
            poke_image(rname, 32'h20000, rn);
            verify_image(rname, 32'h20000, rbad); rbadtot = rbadtot + rbad;
            $display("[tb] %0t ROM set over the link: %0d bytes, %0d wrong", $time, rtot + rn, rbadtot);
            // and back out through CMD 8, as the firmware's verify reads it
            peek_check(32'h40000, 64, pk_bad, pk_noans);
            $display("[tb] %0t AZBOOT's first 64 words back over CMD 8: %0d wrong, %0d unanswered (expect 0 0)", $time, pk_bad, pk_noans);
            if (pk_bad != 0 || pk_noans != 0 || rbadtot != 0) cfg_errs = cfg_errs + 1;
        end
        if (!$value$plusargs("TURBO=%d", turbo_n)) turbo_n = 0;
        sys_set_val("A", 8'd1);
        sys_set_val("T", turbo_n[7:0]);
        sys_set_val("j", 8'd1);
        // the units' sizes into the controller's buffer, as az_boot's
        // az_push_sizes does: the FPGA's select answers from them
        for (ui = 0; ui < 64; ui = ui + 1) az_buf[ui] = 16'd0;
        for (ui = 0; ui < 4; ui = ui + 1) begin az_buf[2*ui] = unit_blocks[ui][15:0]; az_buf[2*ui+1] = unit_blocks[ui][31:16]; end
        az_write(R_USIZE, 64);
        sys_set_val("R", 8'd0);
        az_on = 1'b1;
        $display("[tb] %0t released reset (turbo %0d)", $time, turbo_n);
        #2000;
        if (uut.system_volume !== 2'd1 || uut.system_turbo !== turbo_n[0] || uut.system_joy !== 1'b1) begin
            $display("[tb] *** OSD VALUES WRONG after the defaults");
            cfg_errs = cfg_errs + 1;
        end

        // the keys first (+KEYS at +TYPE_MS), then the text (+TYPE_STR)
        // +TYPE_DELAY ms later, with Enter after it
        if (!$value$plusargs("TYPE_MS=%d", type_ms)) type_ms = 2500;
        if (!$value$plusargs("TYPE_DELAY=%d", type_delay)) type_delay = 0;
        if ($test$plusargs("KEYS=") || $test$plusargs("TYPE_STR=")) #(type_ms * 64'd1000000);
        if ($value$plusargs("KEYS=%s", keys_str)) begin
            kn = 0;
            for (ki = 0; ki < 255; ki = ki + 1) if (keys_str[8*(ki+1) -: 8] != 8'd0) kn = ki + 1;
            for (ki = kn - 1; ki >= 1; ki = ki - 2) begin
                $display("[tb] %0t key %0o", $time, hexpair(keys_str[8*(ki+1) -: 8], keys_str[8*ki -: 8]));
                key(hexpair(keys_str[8*(ki+1) -: 8], keys_str[8*ki -: 8]));
            end
        end
        if ($value$plusargs("TYPE_STR=%s", type_str)) begin
            #(type_delay * 64'd1000000);
            $display("[tb] %0t typing %0s", $time, type_str);
            type_string(type_str);
            key(8'o012);
        end
        // a second and a third set of keys, at their own times (from the start)
        if ($value$plusargs("KEYS2=%s", keys_str)) begin
            if (!$value$plusargs("KEYS2_MS=%d", keys2_ms)) keys2_ms = 0;
            if (keys2_ms * 64'd1000000 > $time) #(keys2_ms * 64'd1000000 - $time);
            kn = 0;
            for (ki = 0; ki < 255; ki = ki + 1) if (keys_str[8*(ki+1) -: 8] != 8'd0) kn = ki + 1;
            for (ki = kn - 1; ki >= 1; ki = ki - 2) begin
                $display("[tb] %0t key %0o", $time, hexpair(keys_str[8*(ki+1) -: 8], keys_str[8*ki -: 8]));
                key(hexpair(keys_str[8*(ki+1) -: 8], keys_str[8*ki -: 8]));
            end
        end
        if ($value$plusargs("KEYS3=%s", keys_str)) begin
            if (!$value$plusargs("KEYS3_MS=%d", keys3_ms)) keys3_ms = 0;
            if (keys3_ms * 64'd1000000 > $time) #(keys3_ms * 64'd1000000 - $time);
            kn = 0;
            for (ki = 0; ki < 255; ki = ki + 1) if (keys_str[8*(ki+1) -: 8] != 8'd0) kn = ki + 1;
            for (ki = kn - 1; ki >= 1; ki = ki - 2) begin
                $display("[tb] %0t key %0o", $time, hexpair(keys_str[8*(ki+1) -: 8], keys_str[8*ki -: 8]));
                key(hexpair(keys_str[8*(ki+1) -: 8], keys_str[8*ki -: 8]));
            end
        end

        // +RESETKEY_MS=<ms>: press and release the СБР key (F11: flag 3) at
        // that time - the machine must come back from the reset it causes
        if ($value$plusargs("RESETKEY_MS=%d", resetkey_ms)) begin
            if (resetkey_ms * 64'd1000000 > $time) #(resetkey_ms * 64'd1000000 - $time);
            $display("[tb] %0t reset key pressed (resets so far %0d)", $time, uut.rst_count);
            hid_key(8'h00, 8'h08);
            #KEY_HOLD;
            hid_key(8'h00, 8'h09);
            $display("[tb] %0t reset key released", $time);
        end

        // +HOTKEY=<n> +HOTKEY_MS=<ms>: the controller's hotkey n (1 АР2+ЛАТ, the
        // legacy 512/256 switch; 2 АР2+РУС, the palette reset) at that time
        if ($value$plusargs("HOTKEY=%d", hotkey_n)) begin
            if (!$value$plusargs("HOTKEY_MS=%d", hotkey_ms)) hotkey_ms = 0;
            if (hotkey_ms * 64'd1000000 > $time) #(hotkey_ms * 64'd1000000 - $time);
            // for the palette reset: spoil two cells first, so the reload shows
            if (hotkey_n == 2) begin uut.vid.pal.mem[300] = 15'h1234; uut.vid.pal.mem[337] = 15'h0001; end
            $display("[tb] %0t hotkey %0d: before 177230 %06o, palette cells 256 %04x 300 %04x 336 %04x 337 %04x", $time, hotkey_n,
                     uut.vid.scr_csr, uut.vid.pal.mem[256], uut.vid.pal.mem[300], uut.vid.pal.mem[336], uut.vid.pal.mem[337]);
            hid_key(hotkey_n[7:0], 8'h10);
            #1000000;
            $display("[tb] %0t hotkey %0d: 1 ms on, 177230 %06o, palette cells 256 %04x 300 %04x 336 %04x 337 %04x", $time, hotkey_n,
                     uut.vid.scr_csr, uut.vid.pal.mem[256], uut.vid.pal.mem[300], uut.vid.pal.mem[336], uut.vid.pal.mem[337]);
            #(KEY_HOLD - 1000000);
            hid_key(hotkey_n[7:0], 8'h11);
            $display("[tb] %0t hotkey %0d: after  177230 %06o, palette cells 256 %04x 300 %04x 336 %04x 337 %04x", $time, hotkey_n,
                     uut.vid.scr_csr, uut.vid.pal.mem[256], uut.vid.pal.mem[300], uut.vid.pal.mem[336], uut.vid.pal.mem[337]);
        end

        #(run_ms * 64'd1000000);
        $display("[tb] %0t done: %0d video frames, leds=%b", $time, rx_frames, leds);
        $display("[tb] config checks: %0d wrong", cfg_errs);
        $display("[tb] cpu: %0d bus cycles, %0d I/O reads, %0d I/O writes, %0d timeouts (no ack), %0d vector fetches, %0d resets",
                 cyc_count, io_rd, io_wr, timeouts, vec_count, uut.rst_count);
        $display("[tb] mapper: 177346 %06o, 177340 %06o, 177716 %06o, windows 8-15: %o %o %o %o %o %o %o %o",
                 uut.mapper_ctrl, uut.map.win_ctrl, uut.map.az716,
                 uut.map.mapper[8], uut.map.mapper[9], uut.map.mapper[10], uut.map.mapper[11],
                 uut.map.mapper[12], uut.map.mapper[13], uut.map.mapper[14], uut.map.mapper[15]);
        $display("[tb] video: 177230 %06o, pages %o %o %o, palette %0d, 177664 %06o; irq2 ticks %0d",
                 uut.vid.scr_csr, uut.vid.pg[0], uut.vid.pg[1], uut.vid.pg[2], uut.vid.legacy_pal, uut.vid.reg664, irq2_count);
        $display("[tb] az: %0d commands (%0d block reads, %0d writes, %0d errors), csr %06o", az_cmds, az_reads, az_writes, az_errs, uut.ctl.csr);
        if (!$test$plusargs("NOMEMCHECK"))
            $display("[tb] read-after-write: %0d checked, %0d wrong", mem_checks, mem_errs);
        $display("[tb] sdram self-test: done %b, fail %b, late capture %b, phase %0d, passes early %04x late %04x  (expect 1 0 0 7 ffff 0000 against the model)",
                 uut.bist_done, uut.bist_fail, uut.cap_late, uut.sd_phase, uut.sd_ok_early, uut.sd_ok_late);
        sys_debug;
        $display("[tb] debug (CMD 7): flags %02x %02x az %02x, pc %02x%02x key %02x rst %02x, 177340 %02x%02x 177716 %02x%02x, ctrl %02x%02x 177230 %02x%02x, cycles %02x%02x resets %02x",
                 dbgb[1], dbgb[2], dbgb[3], dbgb[7], dbgb[6], dbgb[5], dbgb[4], dbgb[11], dbgb[10], dbgb[9], dbgb[8],
                 dbgb[15], dbgb[14], dbgb[13], dbgb[12], dbgb[19], dbgb[18], dbgb[17]);
        $display("[tb] pages: %0d given out of 1920, %0d wraps", uut.mem.alloc_next - 128, uut.mem.alloc_wraps);
        $display("[tb] blitter: %0d runs, longest %0d clocks (%0d lines; the blanking is 37), %0d ran past the blanking",
                 blit_runs, blit_max, blit_max / 1344, blit_over);
        $display("[tb] i2s: %0d frames, %0d with sound", i2s_frames, i2s_nonzero);
        $display("[tb] hdmi: %0d packets, %0d ecc errors  (acr %0d, avi %0d, ai %0d, gcp %0d, audio %0d, null %0d)",
                 rx_packets, rx_ecc_errs, rx_acr, rx_avi, rx_ai, rx_gcp, rx_audio, rx_null);
        $display("[tb] hdmi frame: %0d x %0d, %0d bad guard bands", rx_w, rx_h_last, rx_bad_gb);
        $finish;
    end

    // the AZ service: whenever the interrupt line is low with the AZ bit
    always begin
        #20000;
        if (az_on && uut.az_int) az_serve;
    end

    function [7:0] hexpair(input [7:0] a, input [7:0] b);
        hexpair = {hexdig(a), hexdig(b)};
    endfunction
    function [3:0] hexdig(input [7:0] c);
        hexdig = (c >= "a") ? c - "a" + 8'd10 : (c >= "A") ? c - "A" + 8'd10 : c - "0";
    endfunction

    //--------------------------------------------------------------------
    // Watching the processor
    //--------------------------------------------------------------------
    integer trace_ms;
    reg     tracing = 1'b0;
    initial begin
        if (!$value$plusargs("TRACE_MS=%d", trace_ms)) trace_ms = 0;
        if (trace_ms > 0) #(trace_ms * 64'd1000000);
        tracing = 1'b1;
    end

    integer cyc_count = 0, io_rd = 0, io_wr = 0, timeouts = 0, vec_count = 0, irq2_count = 0;
    reg     first_seen = 1'b0;
    reg     sync_d = 1'b0, stb_d = 1'b0, acked = 1'b0, irq2_d = 1'b0, iako_d = 1'b0, cyc_new = 1'b0;
    reg [15:0] cyc_adr;

    always @(posedge uut.clk) begin
        sync_d <= uut.b_sync;
        stb_d  <= uut.b_stb;
        irq2_d <= uut.irq2;
        iako_d <= uut.cpu1.cpu_iacko;
        if (uut.irq2 && !irq2_d) irq2_count = irq2_count + 1;
        if (uut.cpu1.cpu_iacko && !iako_d) vec_count = vec_count + 1;
        // the wrapper latches the address one clock after sync rises
        cyc_new <= uut.b_sync && !sync_d;
        if (uut.b_sync && !sync_d) begin
            cyc_count = cyc_count + 1;
            acked = 1'b0;
        end
        if (cyc_new) begin
            cyc_adr = uut.b_adr;
            if (!first_seen) begin
                first_seen = 1'b1;
                $display("[tb] %0t CPU first cycle at %06o", $time, uut.b_adr);
            end
            if ($test$plusargs("CPUTRACE") && tracing)
                $display("[cpu] %0t %06o %s", $time, uut.b_adr, uut.b_we ? "wr" : "rd");
        end
        if (uut.b_stb && uut.cpu1.cpu_ack) begin
            if (!acked && $test$plusargs("CPUTRACE") && tracing)
                $display("[cpu] %0t   %s %06o", $time, uut.b_we ? "<=" : "=>", uut.b_we ? uut.b_dout : uut.cpu1.cpu_din);
            acked = 1'b1;
        end
        if (!uut.b_sync && sync_d) begin
            if (!acked) begin
                timeouts = timeouts + 1;
                if (timeouts <= 10) $display("[tb] %0t no acknowledge at %06o (%s)", $time, cyc_adr, uut.b_we ? "wr" : "rd");
            end
        end
        if (uut.b_stb && !stb_d && uut.is_io) begin
            if (uut.b_we) begin
                io_wr = io_wr + 1;
                if ($test$plusargs("IOTRACE") && tracing) $display("[io]  %0t out %06o <= %06o", $time, uut.b_adr, uut.b_dout);
            end else begin
                io_rd = io_rd + 1;
                if ($test$plusargs("IOTRACE") && tracing) $display("[io]  %0t in  %06o", $time, uut.b_adr);
            end
        end
    end

    // +RSTTRACE: the processor's reset chain
    always @(uut.cpu1.cpu_dclo or uut.cpu1.cpu_aclo or uut.cpu_init or uut.cpu_rst_req or uut.mist_rst)
        if ($test$plusargs("RSTTRACE"))
            $display("[rst] %0t req=%b mist=%b dclo=%b aclo=%b init=%b", $time,
                     uut.cpu_rst_req, uut.mist_rst, uut.cpu1.cpu_dclo, uut.cpu1.cpu_aclo, uut.cpu_init);

    // +CORETRACE: inside the VM1, a line every 200 us from 69 ms
    initial if ($test$plusargs("CORETRACE")) begin
        #69000000;
        forever begin
            #200000;
            $display("[core] %0t reset=%b mjres=%b init_out=%b mj=%03x plr=%09x ir=%06o sync=%b/%b din=%b dout=%b win=%b acok=%b aclo=%b rq13=%b sel=%b halt=%b d=%06o",
                     $time, uut.cpu1.core.core.reset, uut.cpu1.core.core.mjres, uut.cpu1.core.core.init_out,
                     uut.cpu1.core.core.mj, uut.cpu1.core.core.plr, uut.cpu1.core.core.ir,
                     uut.cpu1.core.core.sync_out, uut.cpu1.core.core.sync_ena, uut.cpu1.core.core.din_out, uut.cpu1.core.core.dout_out,
                     uut.cpu1.core.core.qbus_win, uut.cpu1.core.core.acok, uut.cpu1.core.core.aclo, uut.cpu1.core.core.rq[13],
                     uut.cpu1.core.core.pin_sel, uut.cpu1.core.core.rq[0], uut.cpu1.core.core.d);
        end
    end

    // +CYCTRACE=<us>: inside the VM1, every processor clock for 100 us from <us>
    integer cyc_from, cyc_len;
    reg cyc_on = 1'b0;
    initial if ($value$plusargs("CYCTRACE=%d", cyc_from)) begin
        #(cyc_from * 64'd1000);
        cyc_on = 1'b1;
        if (!$value$plusargs("CYCLEN=%d", cyc_len)) cyc_len = 100;
        #(cyc_len * 64'd1000);
        cyc_on = 1'b0;
    end
    always @(posedge uut.clk) if (cyc_on && uut.cpu1.ce_cpu_p)
        $display("[cyc] %0t mj=%03x plm=%09x plr=%09x stb=%b ena=%b sync=%b din=%b dout=%b rply=%b/%b tovf=%b abort=%b mjres=%b sel=%b d=%06o ad=%06o addr=%06o ack=%b cdin=%06o iako=%b",
                 $time, uut.cpu1.core.core.mj, uut.cpu1.core.core.plm, uut.cpu1.core.core.plr,
                 uut.cpu1.core.core.plm_stb, uut.cpu1.core.core.plm_ena_fc,
                 uut.cpu1.core.core.sync_out, uut.cpu1.core.core.din_out, uut.cpu1.core.core.dout_out,
                 uut.cpu1.core.core.pin_rply_in, uut.cpu1.core.core.pin_rply_out,
                 uut.cpu1.core.core.qbus_tovf, uut.cpu1.core.core.abort, uut.cpu1.core.core.mjres,
                 uut.cpu1.core.core.pin_sel, uut.cpu1.core.core.d, uut.cpu1.core.core.pin_ad_in, uut.cpu1.bus_addr,
                 uut.cpu1.cpu_ack, uut.cpu1.cpu_din, uut.cpu1.cpu_iacko);

    // +MEMTRACE: every clock of a memory cycle while the CYCTRACE window is on
    always @(posedge uut.clk) if (cyc_on && (uut.b_sync || uut.b_stb || $test$plusargs("BUSALL")))
        $display("[bus] %0t adr=%06o sync=%b stb=%b we=%b din_out=%b dout_out=%b dly=%b rply=%b is_mem=%b cdout=%06o cdin=%06o ack=%b ce=%b%b", $time, uut.b_adr, uut.b_sync, uut.b_stb, uut.b_we,
                 uut.cpu1.cpu_din_out, uut.cpu1.cpu_dout_out, uut.cpu1.dout_delay, uut.cpu1.core.core.pin_rply_in, uut.is_mem,
                 uut.b_dout, uut.cpu1.cpu_din, uut.cpu1.cpu_ack, uut.cpu1.ce_cpu_p, uut.cpu1.ce_cpu_n);
    always @(posedge uut.clk) if (cyc_on && uut.b_stb && uut.is_mem)
        $display("[mem] %0t adr=%06o we=%b page=%o ok=%b go=%b pend=%b take=%b ack=%b done=%b a_mem=%b cpu_ack=%b v_req=%b who=%0d t=%0d idle=%b",
                 $time, uut.b_adr, uut.b_we, uut.mpage, uut.mem_ok, uut.mem_go, uut.mem_pend, uut.c_take, uut.c_ack, uut.mem_done,
                 uut.a_mem, uut.cpu1.cpu_ack, uut.v_req, uut.mem.who, uut.mem.t, uut.mem.idle);

    // +MAPTRACE: the mapper's control word and the cold resets
    always @(uut.map.mapper_ctrl or uut.cold or uut.map.sel1 or uut.az_reset)
        if ($test$plusargs("MAPTRACE"))
            $display("[map] %0t 177346=%06o cold=%b sel1=%b az_reset=%b", $time, uut.map.mapper_ctrl, uut.cold, uut.map.sel1, uut.az_reset);

    // +SPITRACE
    always @(posedge uut.clk)
        if ($test$plusargs("SPITRACE") && uut.mcu_sys_strobe)
            $display("[spi] %0t sys byte %02x start=%b state=%0d cmd=%02x id=%02x",
                     $time, uut.mcu_dout, uut.mcu_start,
                     uut.sctl1.state, uut.sctl1.command, uut.sctl1.id);

    //--------------------------------------------------------------------
    // Read-after-write check on the SDRAM's processor port.
    //--------------------------------------------------------------------
    // the whole 32 MB space, by the ports' (the space's) addresses
    reg [31:0] shadow [0:8388607];
    reg [3:0]  known  [0:8388607];
    integer    mem_errs = 0, mem_checks = 0;
    integer    si;
    initial for (si = 0; si < 8388608; si = si + 1) known[si] = 4'd0;

    reg        rd_pend_c = 1'b0;
    reg [22:0] rd_wc;
    task note_write(input [22:0] w, input [31:0] d, input [3:0] m);
        begin
            for (si = 0; si < 4; si = si + 1)
                if (m[si]) begin shadow[w][si*8 +: 8] = d[si*8 +: 8]; known[w][si] = 1'b1; end
        end
    endtask
    task check_read(input [22:0] w, input [31:0] d, input [7:0] port);
        begin
            if (known[w] != 4'd0 && !$test$plusargs("NOMEMCHECK")) begin
                mem_checks = mem_checks + 1;
                for (si = 0; si < 4; si = si + 1)
                    if (known[w][si] && d[si*8 +: 8] !== shadow[w][si*8 +: 8]) begin
                        mem_errs = mem_errs + 1;
                        if (mem_errs <= 10)
                            $display("[mem] %0t port %c read %08x at word %06x, lane %0d wrote %02x",
                                     $time, port, d, w, si, shadow[w][si*8 +: 8]);
                    end
            end
        end
    endtask
    always @(posedge uut.clk) begin
        if (uut.c_take) begin
            if (uut.b_we) note_write(uut.mem_word[23:1], {uut.b_dout, uut.b_dout}, uut.mem_word[0] ? {uut.b_wtbt, 2'b00} : {2'b00, uut.b_wtbt});
            else begin rd_pend_c = 1'b1; rd_wc = uut.mem_word[23:1]; end
            if ($test$plusargs("MEMTRACE") && tracing)
                $display("[ram] %0t C %s word %06x", $time, uut.b_we ? "wr" : "rd", uut.mem_word[23:1]);
        end
        if (uut.c_ack && rd_pend_c) begin rd_pend_c = 1'b0; check_read(rd_wc, uut.c_rdata, "C"); end
        if (uut.bl_take && uut.bl_we) note_write(uut.bl_adr, uut.bl_wdata, uut.bl_wmask);
        if (uut.p_take && uut.p_we) note_write(uut.p_adr, uut.p_wdata, uut.p_wmask);
    end

    final if ($test$plusargs("RAMDUMP")) $writememh("sim/out/ram.hex", ram.mem, 0, 1048575);

    //--------------------------------------------------------------------
    // I2S monitor
    //--------------------------------------------------------------------
    reg [15:0] i2s_sr = 16'd0;
    reg [15:0] i2s_l  = 16'd0;
    reg [15:0] i2s_r  = 16'd0;
    integer    wav_fd = 0;
    reg [1023:0] wav_name;
    integer    wav_from = 0;
    initial begin
        if ($value$plusargs("WAV=%s", wav_name)) begin
            wav_fd = $fopen(wav_name, "wb");
            if (!$value$plusargs("WAV_FROM=%d", wav_from)) wav_from = 0;
        end
    end
    final if (wav_fd != 0) $fclose(wav_fd);
    reg        ws_d   = 1'b0;
    integer    i2s_frames = 0, i2s_nonzero = 0;
    always @(posedge HP_BCK) begin
        i2s_sr <= {i2s_sr[14:0], HP_DIN};
        ws_d   <= HP_WS;
        // WS changes one bit clock ahead of a word (I2S), so at the edge
        // that ends a word its last bit is on the wire now, not in the
        // shift register yet: the word is the fifteen shifted bits and
        // this one.  (Until 24 Sep 2026 the register alone was taken:
        // every word came out shifted right by one with the other side's
        // last bit as its sign, and the dumps looked like noise.)
        if (HP_WS && !ws_d) i2s_l <= {i2s_sr[14:0], HP_DIN};
        if (!HP_WS && ws_d) begin
            i2s_r = {i2s_sr[14:0], HP_DIN};
            i2s_frames = i2s_frames + 1;
            if (i2s_l !== 16'd0 || i2s_r !== 16'd0) i2s_nonzero = i2s_nonzero + 1;
            // +WAV=<file>: the output as raw signed 16-bit little-endian stereo, one
            // pair an I2S frame, which is 50625 Hz here (64.8 MHz / 40 / 32), from
            // +WAV_FROM=<ms> on (`sox -t raw -r 50625 -e signed -b 16 -c 2`, tools/pcmscan.py)
            if (wav_fd != 0 && $time >= wav_from * 1000000)
                $fwrite(wav_fd, "%c%c%c%c", i2s_l[7:0], i2s_l[15:8], i2s_r[7:0], i2s_r[15:8]);
        end
    end

    //--------------------------------------------------------------------
    // The HDMI receiver: hdmi_serdes is stubbed, so what leaves the
    // design is three ten-bit TMDS words a pixel clock.  This decodes
    // them as a sink does and rebuilds the picture for `make frames`.
    //--------------------------------------------------------------------
    wire        px_clk = uut.clk;
    wire [9:0]  t0 = uut.tmds_ch0;
    wire [9:0]  t1 = uut.tmds_ch1;
    wire [9:0]  t2 = uut.tmds_ch2;

    localparam [9:0] CTL00 = 10'b1101010100, CTL01 = 10'b0010101011,
                     CTL10 = 10'b0101010100, CTL11 = 10'b1010101011;
    localparam [9:0] VGB_02 = 10'b1011001100, VGB_1 = 10'b0100110011;

    function is_ctl(input [9:0] w);
        is_ctl = (w == CTL00) || (w == CTL01) || (w == CTL10) || (w == CTL11);
    endfunction

    function [1:0] ctl_of(input [9:0] w);
        ctl_of = (w == CTL00) ? 2'b00 : (w == CTL01) ? 2'b01 :
                 (w == CTL10) ? 2'b10 : 2'b11;
    endfunction

    function [7:0] tmds_dec(input [9:0] w);
        reg [7:0] qm, d;
        integer   i;
        begin
            qm = w[9] ? ~w[7:0] : w[7:0];
            d[0] = qm[0];
            for (i = 1; i < 8; i = i + 1)
                d[i] = w[8] ? (qm[i] ^ qm[i-1]) : (qm[i] ~^ qm[i-1]);
            tmds_dec = d;
        end
    endfunction

    function [4:0] terc4_dec(input [9:0] w);
        case (w)
            10'b1010011100: terc4_dec = 5'h00;
            10'b1001100011: terc4_dec = 5'h01;
            10'b1011100100: terc4_dec = 5'h02;
            10'b1011100010: terc4_dec = 5'h03;
            10'b0101110001: terc4_dec = 5'h04;
            10'b0100011110: terc4_dec = 5'h05;
            10'b0110001110: terc4_dec = 5'h06;
            10'b0100111100: terc4_dec = 5'h07;
            10'b1011001100: terc4_dec = 5'h08;
            10'b0100111001: terc4_dec = 5'h09;
            10'b0110011100: terc4_dec = 5'h0a;
            10'b1011000110: terc4_dec = 5'h0b;
            10'b1010001110: terc4_dec = 5'h0c;
            10'b1001110001: terc4_dec = 5'h0d;
            10'b0101100011: terc4_dec = 5'h0e;
            10'b1011000011: terc4_dec = 5'h0f;
            default:        terc4_dec = 5'h10;
        endcase
    endfunction

    function [7:0] ecc_step(input [7:0] ecc, input b);
        ecc_step = (ecc >> 1) ^ ((ecc[0] ^ b) ? 8'b10000011 : 8'd0);
    endfunction

    localparam RX_CTL = 0, RX_VGB = 1, RX_VID = 2,
               RX_DGB = 3, RX_DI  = 4, RX_DGBT = 5;

    integer rx_state   = RX_CTL;
    integer rx_gb      = 0;
    integer rx_frames  = 0;
    integer rx_packets = 0, rx_ecc_errs = 0;
    integer rx_acr = 0, rx_avi = 0, rx_ai = 0, rx_audio = 0, rx_null = 0, rx_gcp = 0;
    integer rx_bad_gb = 0;

    reg        rx_vs = 1'b0, rx_vs_d = 1'b0;
    integer    rx_x = 0, rx_y = 0, rx_w = 0, rx_h_last = 0;

    parameter MAXW = 1024;
    parameter MAXH = 768;
    reg [23:0] fb [0:MAXW*MAXH-1];

    reg [4:0]  pk_cnt = 5'd0;
    reg [23:0] pk_hdr;
    reg [55:0] pk_sub [0:3];
    reg [7:0]  pk_par [0:4];
    reg [7:0]  pk_ecc [0:4];
    integer    gi;

    integer fh, fi, fj, fh_h;
    integer written = 0, ppm_max;
    reg     want_ppm = 0;
    reg [255:0] fname;
    integer ppm_from, ppm_every;
    reg     ppm_armed = 1'b0;
    initial begin
        want_ppm = $test$plusargs("VIDEO_PPM");
        if (!$value$plusargs("PPM_MAX=%d", ppm_max)) ppm_max = 4;
        if (!$value$plusargs("PPM_FROM=%d", ppm_from)) ppm_from = 0;
        if (!$value$plusargs("PPM_EVERY=%d", ppm_every)) ppm_every = 1;
        if (ppm_from > 0) #(ppm_from * 64'd1000000);
        ppm_armed = 1'b1;
    end

    task write_ppm;
        begin
            written = written + 1;
            fh_h = (rx_y > MAXH) ? MAXH : rx_y;
            $sformat(fname, "sim/out/frame_%04d.ppm", rx_frames);
            fh = $fopen(fname, "wb");
            if (fh) begin
                $fwrite(fh, "P6\n%0d %0d\n255\n", rx_w, fh_h);
                for (fj = 0; fj < fh_h; fj = fj + 1)
                    for (fi = 0; fi < rx_w; fi = fi + 1)
                        $fwrite(fh, "%c%c%c",
                                fb[fj*MAXW+fi][23:16],
                                fb[fj*MAXW+fi][15:8],
                                fb[fj*MAXW+fi][7:0]);
                $fclose(fh);
                $display("[hdmi] %0t wrote %0s (%0dx%0d)", $time, fname, rx_w, fh_h);
            end
        end
    endtask

    task finish_packet;
        reg [7:0] ptype;
        begin
            rx_packets = rx_packets + 1;
            for (gi = 0; gi < 5; gi = gi + 1)
                if (pk_par[gi] !== pk_ecc[gi]) rx_ecc_errs = rx_ecc_errs + 1;
            ptype = pk_hdr[7:0];
            case (ptype)
                8'h00: rx_null  = rx_null  + 1;
                8'h01: rx_acr   = rx_acr   + 1;
                8'h02: rx_audio = rx_audio + 1;
                8'h03: rx_gcp   = rx_gcp   + 1;
                8'h82: rx_avi   = rx_avi   + 1;
                8'h84: rx_ai    = rx_ai    + 1;
                default: ;
            endcase
            if ($test$plusargs("HDMIDBG"))
                $display("[hdmi] %0t packet type %02x hdr %06x sub0 %014x",
                         $time, ptype, pk_hdr, pk_sub[0]);
        end
    endtask

    // +NODECODE: skip the TMDS decode until the frames are wanted
    // (+PPM_FROM) - about a third of the run's time on a long boot; the
    // packet and frame counts at the end then cover only the decoded part
    wire decode_on = !$test$plusargs("NODECODE") || ppm_armed;
    always @(posedge px_clk) if (decode_on) begin : rx
        reg [1:0] c0, c1, c2;
        reg [4:0] n0, n1, n2;
        reg [7:0] dr, dg, db;
        c0 = ctl_of(t0); c1 = ctl_of(t1); c2 = ctl_of(t2);

        case (rx_state)
        RX_CTL: begin
            if (is_ctl(t0)) begin
                rx_vs_d = rx_vs;
                rx_vs   = c0[1];
                if (rx_vs && !rx_vs_d) begin
                    if (rx_frames > 0 && want_ppm && ppm_armed &&
                        written < ppm_max && (rx_frames % ppm_every) == 0) write_ppm;
                    rx_frames = rx_frames + 1;
                    rx_h_last = rx_y;
                    rx_x = 0; rx_y = 0;
                end
            end
            if (is_ctl(t1) && c1 == 2'b01) begin
                if (is_ctl(t2) && c2 == 2'b01) rx_state = RX_DGB;
                else                           rx_state = RX_VGB;
                rx_gb = 0;
            end
        end

        RX_VGB: begin
            if (is_ctl(t1) && ctl_of(t1) == 2'b01) begin
            end else begin
                if (t0 !== VGB_02 || t1 !== VGB_1 || t2 !== VGB_02)
                    rx_bad_gb = rx_bad_gb + 1;
                rx_gb = rx_gb + 1;
                if (rx_gb == 2) begin rx_state = RX_VID; rx_x = 0; end
            end
        end

        RX_VID: begin
            if (is_ctl(t0)) begin
                if (rx_x > rx_w) rx_w = rx_x;
                rx_x = 0;
                rx_y = rx_y + 1;
                rx_state = RX_CTL;
            end else begin
                db = tmds_dec(t0); dg = tmds_dec(t1); dr = tmds_dec(t2);
                if (rx_x < MAXW && rx_y < MAXH)
                    fb[rx_y*MAXW+rx_x] = {dr, dg, db};
                rx_x = rx_x + 1;
            end
        end

        RX_DGB: begin
            if (is_ctl(t1) && ctl_of(t1) == 2'b01 &&
                is_ctl(t2) && ctl_of(t2) == 2'b01) begin
            end else begin
                if (t1 !== VGB_1 || t2 !== VGB_1) rx_bad_gb = rx_bad_gb + 1;
                rx_gb = rx_gb + 1;
                if (rx_gb == 2) begin
                    rx_state = RX_DI;
                    pk_cnt = 5'd0;
                    for (gi = 0; gi < 5; gi = gi + 1) pk_par[gi] = 8'd0;
                end
            end
        end

        RX_DI: begin
            n0 = terc4_dec(t0); n1 = terc4_dec(t1); n2 = terc4_dec(t2);
            if (n0[4] || n1[4] || n2[4]) begin
                rx_gb = 0;
                rx_state = RX_DGBT;
            end else begin
                if (pk_cnt < 5'd24) pk_hdr[pk_cnt] = n0[2];
                for (gi = 0; gi < 4; gi = gi + 1) begin
                    pk_sub[gi][{pk_cnt, 1'b0}] = n1[gi];
                    pk_sub[gi][{pk_cnt, 1'b1}] = n2[gi];
                end
                if (pk_cnt >= 5'd28) begin
                    for (gi = 0; gi < 4; gi = gi + 1) begin
                        pk_ecc[gi][{pk_cnt[1:0], 1'b0}] = n1[gi];
                        pk_ecc[gi][{pk_cnt[1:0], 1'b1}] = n2[gi];
                    end
                end
                if (pk_cnt >= 5'd24) pk_ecc[4][pk_cnt[2:0]] = n0[2];
                if (pk_cnt < 5'd28) begin
                    for (gi = 0; gi < 4; gi = gi + 1) begin
                        pk_par[gi] = ecc_step(pk_par[gi], n1[gi]);
                        pk_par[gi] = ecc_step(pk_par[gi], n2[gi]);
                    end
                    if (pk_cnt < 5'd24)
                        pk_par[4] = ecc_step(pk_par[4], n0[2]);
                end
                if (pk_cnt == 5'd31) begin
                    finish_packet;
                    for (gi = 0; gi < 5; gi = gi + 1) pk_par[gi] = 8'd0;
                end
                pk_cnt = pk_cnt + 5'd1;
            end
        end

        RX_DGBT: begin
            rx_gb = rx_gb + 1;
            if (rx_gb == 2) rx_state = RX_CTL;
        end
        endcase
    end

endmodule

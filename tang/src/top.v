`timescale 1ns / 1ps
//========================================================================
// top.v - BK Nano: a БК-0011М with an AZBK controller on a Tang Nano 20K,
// with a BL616 (M0S Dock) beside it for USB, the SD card and the OSD.
//
// One clock.  sys_pll makes 64.8 MHz out of the board's 27, and every
// flop in the design runs on it: the HDMI pixel is one (1024x768 at
// 59.8 Hz, the AZBK's own VGA frame), the К1801ВМ1's clock is sixteen
// (4.05 MHz; eight in turbo), the AY's clock an enable every 38, the
// SDRAM takes the phase-shifted copy on its pad.  The only other clocks
// are the HDMI serial clock, made from this one inside hdmi_serdes.v,
// and the MCU's SPI clock, which mcu_spi.v takes through a handshake.
// bk.sdc names the two and the tool has the rest.  ZS-256 Nano's method
// (../tang-zs256), with this machine in it.
//
// The machine (tang/src/bk/):
//   cpu.v      the К1801ВМ1 (vm1/, Vslav's model in Sorgelig's wrapper)
//              and its bus: enables, reset, SEL1/SEL2, the vector controller
//   azmap.v    the AZBK's memory mapper: sixteen 4 KB windows, 177300-177352,
//              the BK-0011M's 177716 and the SMK's 177130 translated into it
//   sdram.v    the SDRAM behind every window, with the arbiter
//   azvideo.v  the AZBK's display out of that memory, 1024x768, the
//              palette, the layers, the frame interrupts
//   azblit.v   the blitter
//   azsound.v  two AYs, the Covox, the DMA player, the speaker, the mixer
//   azctrl.v   the AZ controller's registers and its MCU
//   azmisc.v   the random number, the version, the serial port's stubs
//   keyboard.v the BK's keyboard registers, filled from the MCU
//   poke.v     the MCU's bytes into the SDRAM, and a word out
// and around it MiSTeryNano's MCU link (src/mister/), UKNC Nano's HDMI
// encoder with audio (src/hdmi/) and an I2S output (i2s_tx.v).
//
// There is no ROM in the bitstream: the firmware loads the AZBK's ROM
// set from the card (mnano/azbk.c, AZ.INI's [ROM] section) into the
// pages 100-177 through poke.v while the processor is held in reset,
// and the controller's cold reset maps page 100 - AZBOOT - into the
// window at 170000, where the processor starts.
//========================================================================
module top(
    input         clk27,
    // buts[0] is S1 and forces a reset; buts[1] is S2, unused.
    input  [ 1:0] buts,
    output [ 5:0] leds,

    output        uart_tx,        // tang-ultima's UART to the on-board BL616
    input         uart_rx,

    output        sdclk,
    inout         sdcmd,          // mosi
    inout         sddat0,         // miso
    inout         sddat1,         // not used
    inout         sddat2,         // not used
    inout         sddat3,         // cs

    output        O_tmds_clk_p,
    output        O_tmds_clk_n,
    output  [2:0] O_tmds_data_p,
    output  [2:0] O_tmds_data_n,

    // I2S to the dock's DAC
    output        HP_BCK,
    output        HP_WS,
    output        HP_DIN,
    output        PA_EN,

    output        O_sdram_clk,
    output        O_sdram_cke,
    output        O_sdram_cs_n,
    output        O_sdram_cas_n,
    output        O_sdram_ras_n,
    output        O_sdram_wen_n,
    output [ 3:0] O_sdram_dqm,
    output [10:0] O_sdram_addr,
    output [ 1:0] O_sdram_ba,
    inout  [31:0] IO_sdram_dq,

    // the MCU link, stock MiSTeryNano wiring: an external BL616 / M0S
    // Dock on 42/41/56/54/51 - 0 miso, 1 mosi, 2 csn, 3 sclk, 4 irqn
    inout  [ 4:0] m0s,

    // pin 48, wired on the board to TP1 = RECONFIG_N: low on SYS command 9
    // reloads the FPGA.  Dormant without that wire (tang-ultima).
    output        reconfig_n,

    // The configuration flash, on the MSPI pins that -use_mspi_as_gpio
    // hands to user logic after configuration (flashwr.v, SYS command
    // 10): tang-ultima's "Save to flash".
    output        mspi_clk,      // 59 MCLK
    output        mspi_cs_n,     // 60 MCS_N
    output        mspi_do,       // 61 MO, into the flash
    input         mspi_di        // 62 MI, out of it
);

assign O_sdram_cke = 1'b1;
assign PA_EN       = 1'b1;

//------------------------------------------------------------------------
// Clock
//------------------------------------------------------------------------
wire clk;          // 64.8 MHz, everything
wire locked;

wire [3:0]  sd_phase;
wire [15:0] sd_ok_early, sd_ok_late;   // the self-test's passes at each of the sixteen phases, by capture
wire [7:0]  sd_last_rd;
sys_pll pll (
    .clkin  (clk27      ),
    .clkout (clk        ),
    .clkoutp(O_sdram_clk),
    .psda   (sd_phase   ),
    .lock   (locked     )
);

//------------------------------------------------------------------------
// Resets.  `init` is the SDRAM's word that the memory exists; the
// MiSTeryNano side then waits 2^23 clocks (130 ms) as upstream does, for
// the MCU to come up.  The machine itself is reset by the OSD's 'R'
// (the MCU sends 3 at power-up and 0 when it has sent its settings and
// loaded the ROMs), by S1, by the AZ's own command 037, by the СБР key,
// and until the memory is there.  Every one of them is a COLD reset of
// the AZ controller too - the STM32's HALT sequence on the real board -
// which maps the start ROM in and clears the mapper's modes.
//------------------------------------------------------------------------
wire init;
reg  [23:0] count_rst = 24'd0;
wire        n_all_rst = init & ~buts[0];
wire        por_done  = count_rst[23];
wire        mist_rst  = ~por_done;

always @(posedge clk or negedge n_all_rst)
    count_rst <= !n_all_rst ? 24'd0 : count_rst + {23'd0, !count_rst[23]};

wire [1:0] system_reset, system_volume;
wire       system_turbo, system_joy, system_cold;
wire       az_reset, key_reset;

reg  [19:0] rst_hold = 20'd0;    // a pulse request held for 16 ms
wire        rst_pulse = az_reset | system_cold | key_reset;
always @(posedge clk) begin
    if (rst_pulse) rst_hold <= 20'hFFFFF;
    else if (rst_hold != 20'd0) rst_hold <= rst_hold - 20'd1;
end
wire cpu_rst_req = mist_rst | system_reset[0] | ~init | (rst_hold != 20'd0);
reg  cpu_rst_d = 1'b1;
always @(posedge clk) cpu_rst_d <= cpu_rst_req;
wire cold = cpu_rst_req && !cpu_rst_d;     // one clock at the start of every reset

//------------------------------------------------------------------------
// The processor and its bus
//------------------------------------------------------------------------
wire        ce_bus, cpu_init;
wire [15:0] b_adr, b_dout;
wire        b_sync, b_stb, b_we, b_wr_stb, b_rd_stb;
wire [1:0]  b_wtbt;
wire        irq2, key_stop, key_down, stop_block;
wire [2:0]  vreq, vack;
wire        sel1_wr, sel2_wr, sel1_start, sel1_bk11;
wire [15:0] port_din;
wire [15:0] pc_dbg;

wire [15:0] d_kbd, d_map, d_vid, d_blt, d_snd, d_ctl, d_msc, d_mem;
wire        a_kbd, a_map, a_vid, a_blt, a_snd, a_ctl, a_msc, a_mem;

cpu cpu1 (
    .clk(clk), .reset_req(cpu_rst_req), .turbo(system_turbo),
    .ce_bus(ce_bus), .init(cpu_init),
    .addr(b_adr), .dout(b_dout), .sync(b_sync), .stb(b_stb), .we(b_we), .wtbt(b_wtbt),
    .wr_stb(b_wr_stb), .rd_stb(b_rd_stb),
    .din(d_kbd | d_map | d_vid | d_blt | d_snd | d_ctl | d_msc | d_mem),
    .ack(a_kbd | a_map | a_vid | a_blt | a_snd | a_ctl | a_msc | a_mem),
    .irq1(key_stop && !stop_block), .irq2(irq2),
    .vreq(vreq), .vack(vack),
    .start_addr(sel1_start ? 8'o360 : sel1_bk11 ? 8'o300 : 8'o200), .key_down(key_down),   // 170000 at a start, then 140000 or 100000 (GID's AZ_716_Out)
    .sel1_wr(sel1_wr), .stop_block(stop_block),
    .port_din(port_din), .sel2_wr(sel2_wr),
    .pc_dbg(pc_dbg)
);

//------------------------------------------------------------------------
// The memory: every address below 177000 through the mapper into the
// SDRAM.  A cycle is one request; the acknowledge is a level from the
// data's arrival (or the write's acceptance) to the strobe's end.  A
// window the mapper does not allow gets no acknowledge, and the
// processor times out through vector 4.
//------------------------------------------------------------------------
wire        is_io  = (b_adr[15:9] == 7'b1111111);   // 177000-177777
wire        is_mem = b_sync && !is_io;
wire [12:0] mpage;
wire        rd_ok, wr_ok, wr_drop;
wire [15:0] map_rdata;

// the processor has taken its start address: the end of a read of 177716
// (cleared at the strobe's start, the word would change under the read)
reg  b_stb_d = 1'b0;
always @(posedge clk) b_stb_d <= b_stb;
wire sel1_rd_end = b_stb_d && !b_stb && !b_we && (b_adr[15:1] == (16'o177716 >> 1));

azmap map (
    .clk(clk), .cold(cold),
    .wr_stb(b_wr_stb), .wr_adr(b_adr), .wr_data(b_dout), .wr_wtbt(b_wtbt),
    .adr(b_adr), .page(mpage), .rd_ok(rd_ok), .wr_ok(wr_ok), .wr_drop(wr_drop),
    .rd_reg({1'b0, b_adr[5:1]}), .rd_data(map_rdata),   // (adr - 177300) >> 1: bit 6 is 177300's own
    .mapper_ctrl(), .sel1_rd(sel1_rd_end),
    .sel1_start(sel1_start), .sel1_bk11(sel1_bk11)
);
wire [15:0] mapper_ctrl = map.mapper_ctrl;
reg  [7:0]  diag = 8'd0;                 // the diagnostic strip's bits, made below

wire        sel_mapr = b_sync && (b_adr[15:6] == (16'o177300 >> 6)) && (b_adr[5:1] <= 5'd21);   // 177300-177352
assign d_map = sel_mapr ? map_rdata : 16'd0;
assign a_map = b_stb && (b_sync && ((b_adr[15:5] == (16'o177300 >> 5)) || (b_adr[15:4] == (16'o177340 >> 4))));   // 177300-177356, writes too

wire [23:0] mem_word = {mpage, b_adr[11:1]};
wire        c_req, c_take, c_ack;
wire [31:0] c_rdata;
reg         mem_pend = 1'b0, mem_done = 1'b0;
reg  [15:0] mem_rdata = 16'd0;
wire        mem_ok = b_we ? wr_ok : rd_ok;
wire        mem_go = is_mem && b_stb && mem_ok;
wire        mem_drop = is_mem && b_stb && b_we && wr_drop;   // answered, not written (ROM)

always @(posedge clk) begin
    if (!b_stb) begin mem_pend <= 1'b0; mem_done <= 1'b0; end
    else if (mem_go && !mem_pend && !mem_done) mem_pend <= 1'b1;
    else if (mem_drop) mem_done <= 1'b1;
    if (c_take) mem_pend <= 1'b0;
    if (c_ack) begin
        mem_done <= 1'b1;
        mem_rdata <= mem_word[0] ? c_rdata[31:16] : c_rdata[15:0];
    end
end
assign c_req = mem_pend;
assign a_mem = mem_done;
assign d_mem = (is_mem && mem_done && !b_we) ? mem_rdata : 16'd0;

wire        v_req, v_take, v_dv;
wire [22:0] v_adr;
wire [31:0] v_rdata;
wire        bl_req, bl_we, bl_take, bl_ack;
wire [22:0] bl_adr;
wire [31:0] bl_wdata, bl_rdata;
wire [3:0]  bl_wmask;
wire        dm_req, dm_take, dm_ack;
wire [22:0] dm_adr;
wire [31:0] dm_rdata;
wire        p_req, p_we, p_take, p_ack;
wire [22:0] p_adr;
wire [31:0] p_wdata, p_rdata;
wire [3:0]  p_wmask;
wire        bist_done, bist_fail, cap_late;
wire [10:0] sd_alloc;
wire [4:0]  sd_wraps;

sdram mem (
    .clk(clk), .lock(locked), .init(init), .clear(cold), .alloc_next(sd_alloc), .alloc_wraps(sd_wraps),
    .v_req(v_req), .v_adr(v_adr), .v_take(v_take), .v_dv(v_dv), .v_rdata(v_rdata),
    .c_req(c_req), .c_we(b_we), .c_adr(mem_word[23:1]),
    .c_wdata({b_dout, b_dout}), .c_wmask(mem_word[0] ? {b_wtbt, 2'b00} : {2'b00, b_wtbt}),
    .c_take(c_take), .c_ack(c_ack), .c_rdata(c_rdata),
    .b_req(bl_req), .b_we(bl_we), .b_adr(bl_adr), .b_wdata(bl_wdata), .b_wmask(bl_wmask),
    .b_take(bl_take), .b_ack(bl_ack), .b_rdata(bl_rdata),
    .d_req(dm_req), .d_adr(dm_adr), .d_take(dm_take), .d_ack(dm_ack), .d_rdata(dm_rdata),
    .p_req(p_req), .p_we(p_we), .p_adr(p_adr), .p_wdata(p_wdata), .p_wmask(p_wmask),
    .p_take(p_take), .p_ack(p_ack), .p_rdata(p_rdata),
    .bist_done(bist_done), .bist_fail(bist_fail), .cap_late(cap_late),
    .phase(sd_phase), .ok_early(sd_ok_early), .ok_late(sd_ok_late), .last_rd(sd_last_rd),
    .SDRAM_A(O_sdram_addr), .SDRAM_BA(O_sdram_ba), .SDRAM_DQ(IO_sdram_dq),
    .SDRAM_nCS(O_sdram_cs_n), .SDRAM_nRAS(O_sdram_ras_n), .SDRAM_nCAS(O_sdram_cas_n),
    .SDRAM_nWE(O_sdram_wen_n), .SDRAM_DQM(O_sdram_dqm)
);

//------------------------------------------------------------------------
// The keyboard, the display, the blitter, the sound, the controller
//------------------------------------------------------------------------
wire [7:0] kbd_code, kbd_flags;
wire       kbd_stb;
wire [1:0] hotkey;

keyboard kbd (
    .clk(clk), .reset(cpu_init),
    .sync(b_sync), .adr(b_adr), .stb(b_stb), .we(b_we), .wtbt(b_wtbt), .din(b_dout),
    .dout(d_kbd), .ack(a_kbd),
    .key_code(kbd_code), .key_flags(kbd_flags), .key_stb(kbd_stb),
    .key_down(key_down), .key_stop(key_stop), .key_reset(key_reset), .hotkey(hotkey),
    .req60(vreq[0]), .ack60(vack[0]), .req274(vreq[1]), .ack274(vack[1])
);

wire       hsync, vsync, visible, frame_end;
wire [7:0] red, green, blue;

azvideo vid (
    .clk(clk),
    .sync(b_sync), .adr(b_adr), .stb(b_stb), .we(b_we), .wtbt(b_wtbt), .din(b_dout),
    .dout(d_vid), .ack(a_vid), .wr_stb(b_wr_stb),
    .mapper_ctrl(mapper_ctrl), .cold(cold), .hotkey(hotkey),
    .v_req(v_req), .v_adr(v_adr), .v_take(v_take), .v_dv(v_dv), .v_rdata(v_rdata),
    .hs(hsync), .vs(vsync), .de(visible), .r(red), .g(green), .b(blue),
    .frame_end(frame_end), .irq2(irq2), .reg664_out(), .scr_csr_out()
);

azblit blt (
    .clk(clk), .cold(cold),
    .sync(b_sync), .adr(b_adr), .stb(b_stb), .we(b_we), .din(b_dout),
    .dout(d_blt), .ack(a_blt), .wr_stb(b_wr_stb),
    .frame_end(frame_end),
    .b_req(bl_req), .b_we(bl_we), .b_adr(bl_adr), .b_wdata(bl_wdata), .b_wmask(bl_wmask),
    .b_take(bl_take), .b_ack(bl_ack), .b_rdata(bl_rdata)
);

wire signed [15:0] snd_l, snd_r;
azsound snd (
    .clk(clk), .reset(cpu_init),
    .sync(b_sync), .adr(b_adr), .stb(b_stb), .we(b_we), .wtbt(b_wtbt), .din(b_dout),
    .dout(d_snd), .ack(a_snd), .wr_stb(b_wr_stb),
    .sel2_wr(sel2_wr), .sel1_wr(sel1_wr), .cpu_dout(b_dout), .cpu_wtbt(b_wtbt),
    .d_req(dm_req), .d_adr(dm_adr), .d_take(dm_take), .d_ack(dm_ack), .d_rdata(dm_rdata),
    .out_l(snd_l), .out_r(snd_r)
);

wire        mcu_sys_strobe, mcu_hid_strobe, mcu_osd_strobe, mcu_sdc_strobe, mcu_az_strobe;
wire        mcu_start;
wire  [7:0] mcu_sys_din, mcu_hid_din, mcu_sdc_din, mcu_az_din;
wire  [7:0] mcu_osd_din = 8'h55;
wire  [7:0] mcu_dout;
wire        hid_int, sdc_int, az_int;
wire  [7:0] int_ack;

azctrl ctl (
    .clk(clk), .cold(cold),
    .sync(b_sync), .adr(b_adr), .stb(b_stb), .we(b_we), .din(b_dout),
    .dout(d_ctl), .ack(a_ctl), .wr_stb(b_wr_stb), .rd_stb(b_rd_stb),
    .virq174(vreq[2]), .vack174(vack[2]), .az_reset(az_reset),
    .mcu_strobe(mcu_az_strobe), .mcu_start(mcu_start), .mcu_din(mcu_dout), .mcu_dout(mcu_az_din),
    .mcu_irq(az_int)
);

azmisc msc (
    .clk(clk),
    .sync(b_sync), .adr(b_adr), .stb(b_stb), .we(b_we), .din(b_dout),
    .dout(d_msc), .ack(a_msc), .wr_stb(b_wr_stb)
);

//------------------------------------------------------------------------
// The joystick on 177714, GID's default bits: up 1, right 2, down 4,
// left 10, A 20, fire 40, alt fire 100, B 200.  MiSTeryNano's byte is
// right, left, down, up, then four buttons.
//------------------------------------------------------------------------
wire [7:0] joystick0, joystick1;
wire [7:0] joy = joystick0 | joystick1;
assign port_din = system_joy ? {8'd0, joy[7], joy[5], joy[4], joy[6], joy[1], joy[2], joy[0], joy[3]} : 16'd0;

//------------------------------------------------------------------------
// The SD card: the MCU's file system reads and writes the card through
// this; no image slot is used by the core itself (the AZ's disks are
// served by the MCU through azctrl.v).
//------------------------------------------------------------------------
wire [8:0] sd_outaddr;
wire [7:0] sd_outbyte;
wire       sd_rbusy;

sd_card #(.CLK_DIV(3'd3)) sd_card (   // sd_rw.v: 3 for a 50-100 MHz clock (2 was the 25-50 value; 19 Sep 2026, the card did not read on the board)
    .rstn(por_done), .clk(clk), .sdclk(sdclk), .sdcmd(sdcmd),
    .sddat({sddat3, sddat2, sddat1, sddat0}),
    .data_strobe(mcu_sdc_strobe), .data_start(mcu_start), .data_in(mcu_dout), .data_out(mcu_sdc_din),
    .image_size(), .image_mounted(),
    .irq(sdc_int), .iack(int_ack[3]),
    .rstart(5'd0), .wstart(5'd0), .rsector(32'd0),
    .rbusy(sd_rbusy), .rdone(), .inbyte(8'd0),
    .outen(), .outaddr(sd_outaddr), .outbyte(sd_outbyte)
);

//------------------------------------------------------------------------
// The MCU link (MiSTeryNano): SPI in, five targets out.
//------------------------------------------------------------------------
wire        spi_io_dout;
wire        int_out_n;

assign m0s[4:0] = { int_out_n, 3'bzzz, spi_io_dout };

wire spi_io_din = m0s[1];
wire spi_io_ss  = m0s[2];
wire spi_io_clk = m0s[3];

mcu_spi msp1 (
    .clk(clk), .reset(mist_rst),
    .spi_io_ss(spi_io_ss), .spi_io_clk(spi_io_clk), .spi_io_din(spi_io_din), .spi_io_dout(spi_io_dout),
    .mcu_sys_strobe(mcu_sys_strobe), .mcu_hid_strobe(mcu_hid_strobe),
    .mcu_osd_strobe(mcu_osd_strobe), .mcu_sdc_strobe(mcu_sdc_strobe), .mcu_az_strobe(mcu_az_strobe),
    .mcu_start(mcu_start),
    .mcu_sys_din(mcu_sys_din), .mcu_hid_din(mcu_hid_din), .mcu_osd_din(mcu_osd_din),
    .mcu_sdc_din(mcu_sdc_din), .mcu_az_din(mcu_az_din),
    .mcu_dout(mcu_dout)
);

// the debug window (CMD 7): what the processor is doing
reg [15:0] sync_count = 16'd0;
reg [7:0]  rst_count = 8'd0;
reg        sync_d = 1'b0;
always @(posedge clk) begin
    sync_d <= b_sync;
    if (cold) rst_count <= rst_count + 8'd1;
    if (b_sync && !sync_d) sync_count <= sync_count + 16'd1;
end
wire [255:0] dbg_bus = {
    16'd0, {sd_wraps, sd_alloc},                                    // 31..28: the page table's wraps and next physical page (used = this - 128)
    diag, sd_last_rd, sd_ok_late,                                   // 27..24: the activity byte (below), the last self-test read's low byte (F0), the late capture's passes
    8'd0, {4'd0, sd_phase}, sd_ok_early,                            // 23..20: the SDRAM clock phase chosen, the early capture's passes
    sync_count, rst_count, 8'd0,                                    // 19..16: the cycle count, the reset count
    mapper_ctrl, vid.scr_csr, // 15..12
    map.win_ctrl, map.az716,                                        // 11..8
    pc_dbg, {7'd0, key_down}, {6'd0, cpu_rst_req, cpu_init},        // 7..4
    {5'd0, ctl.pending, ctl.csr[7], ctl.csr[15]},                   // 3
    {5'd0, cap_late, bist_fail, bist_done},                         // 2
    {6'd0, init, por_done},                                         // 1
    8'hA5 };                                                        // 0

wire        sys_reconfig;
wire        flash_stb, flash_first;
wire [7:0]  flash_din, flash_dout;
wire        cl_stb, cl_first;
wire [7:0]  cl_din, cl_dout;
wire        cl_active, cl_tx;
wire        poke_stb, peek_stb, peek_ready;
wire [23:0] poke_adr;
wire [7:0]  poke_data;
wire [31:0] peek_data;

sysctrl sctl1 (
    .clk(clk), .reset(mist_rst),
    .data_in_strobe(mcu_sys_strobe), .data_in_start(mcu_start), .data_in(mcu_dout), .data_out(mcu_sys_din),
    .int_out_n(int_out_n),
    .int_in({3'b000, az_int, sdc_int, 1'b0, hid_int, 1'b0}),
    .int_ack(int_ack),
    .buttons(2'b00), .leds(), .color(),
    .system_reset(system_reset), .system_volume(system_volume), .system_turbo(system_turbo),
    .system_joy(system_joy), .system_cold(system_cold),
    .poke_stb(poke_stb), .poke_adr(poke_adr), .poke_data(poke_data),
    .peek_stb(peek_stb), .peek_data(peek_data), .peek_ready(peek_ready),
    .dbg(dbg_bus),
    .reconfig(sys_reconfig),
    .flash_stb(flash_stb), .flash_first(flash_first),
    .flash_din(flash_din), .flash_dout(flash_dout),
    .cl_stb(cl_stb), .cl_first(cl_first), .cl_din(cl_din), .cl_dout(cl_dout)
);

// The activity byte (the debug window's byte 27; until 23 Sep 2026 a
// strip of squares in the picture's corner, taken out once the machine
// booted - the OSD's Debug page carries it):
//   0 the memory is initialised          4 an SPI byte from the MCU in the last second
//   1 its self-test did not fail         5 the SD card was read in the last second
//   2 the processor started a bus cycle  6 the processor is not held in reset
//     in the last 50 ms                  7 a ROM byte (SYS CMD 6) arrived in the last second
//   3 an I/O register was written in the last second
reg [25:0] hold_cyc = 26'd0, hold_io = 26'd0, hold_spi = 26'd0, hold_sd = 26'd0, hold_poke = 26'd0;
always @(posedge clk) begin
    hold_cyc  <= b_sync            ? 26'd3240000  : (hold_cyc  != 0 ? hold_cyc  - 1 : 0);   // 50 ms
    hold_io   <= (b_wr_stb && is_io) ? 26'd64800000 : (hold_io   != 0 ? hold_io   - 1 : 0);   // 1 s
    hold_spi  <= mcu_sys_strobe    ? 26'd64800000 : (hold_spi  != 0 ? hold_spi  - 1 : 0);
    hold_sd   <= sd_rbusy          ? 26'd64800000 : (hold_sd   != 0 ? hold_sd   - 1 : 0);
    hold_poke <= poke_stb          ? 26'd64800000 : (hold_poke != 0 ? hold_poke - 1 : 0);
    diag <= {hold_poke != 0, !cpu_rst_req, hold_sd != 0, hold_spi != 0, hold_io != 0, hold_cyc != 0, !bist_fail, init};
end


poke pk (
    .clk(clk), .reset(mist_rst),
    .stb(poke_stb), .adr(poke_adr), .data(poke_data),
    .peek_stb(peek_stb), .peek_adr(poke_adr), .peek_data(peek_data), .peek_ready(peek_ready),
    .p_req(p_req), .p_we(p_we), .p_adr(p_adr), .p_wdata(p_wdata), .p_wmask(p_wmask),
    .p_take(p_take), .p_ack(p_ack), .p_rdata(p_rdata)
);

//------------------------------------------------------------------------
// tang-ultima: the configuration flash (SYS command 10), the UART to the
// board's own BL616 (SYS command 11), and RECONFIG_N (SYS command 9,
// dormant).  The same three blocks as in the siblings.
//------------------------------------------------------------------------
flashwr fwr1(
    .clk(clk), .reset(mist_rst),
    .stb(flash_stb), .first(flash_first),
    .din(flash_din), .dout(flash_dout),
    .mspi_clk(mspi_clk), .mspi_cs_n(mspi_cs_n),
    .mspi_do(mspi_do),   .mspi_di(mspi_di)
);

coreload #(.CLK_HZ(64800000), .BAUD(2000000)) cl1(
    .clk(clk), .reset(mist_rst),
    .stb(cl_stb), .first(cl_first), .din(cl_din), .dout(cl_dout),
    .active(cl_active), .tx(cl_tx), .rx(uart_rx)
);
assign uart_tx = cl_tx;   // idles high

reg [7:0] reconfig_cnt = 8'd0;
always @(posedge clk) begin
    if(sys_reconfig)            reconfig_cnt <= 8'hff;
    else if(reconfig_cnt != 0)  reconfig_cnt <= reconfig_cnt - 8'd1;
end
assign reconfig_n = (reconfig_cnt == 8'd0);

wire [5:0] mouse_bits;
hid hd1 (
    .clk(clk), .reset(mist_rst),
    .data_in_strobe(mcu_hid_strobe), .data_in_start(mcu_start), .data_in(mcu_dout), .data_out(mcu_hid_din),
    .db9_port(6'd0), .irq(hid_int), .iack(int_ack[1]),
    .mouse(mouse_bits), .keyboard(kbd_code), .keyboard_flags(kbd_flags), .keyboard_stb(kbd_stb),
    .joystick0(joystick0), .joystick1(joystick1),
    .mouse_rep_tgl(), .mouse_rep_dx(), .mouse_rep_dy()
);

//------------------------------------------------------------------------
// The OSD over the picture, then the encoder.
//------------------------------------------------------------------------
wire [5:0] r_out, g_out, b_out;

osd_u8g2 osd1 (
    .clk(clk), .pclk(clk), .reset(mist_rst),
    .data_in_strobe(mcu_osd_strobe), .data_in_start(mcu_start), .data_in(mcu_dout),
    .hs(hsync), .vs(vsync),
    .r_in(red[7:2]), .g_in(green[7:2]), .b_in(blue[7:2]),
    .r_out(r_out), .g_out(g_out), .b_out(b_out)
);

reg        I_rgb_vs = 1'b0, I_rgb_hs = 1'b0, I_rgb_de = 1'b0;
reg  [7:0] I_rgb_r = 8'd0, I_rgb_g = 8'd0, I_rgb_b = 8'd0;

always @(posedge clk) begin
    I_rgb_vs <= vsync;
    I_rgb_hs <= hsync;
    I_rgb_de <= visible;
    I_rgb_r  <= {r_out, 2'd0};
    I_rgb_g  <= {g_out, 2'd0};
    I_rgb_b  <= {b_out, 2'd0};
end

wire [9:0]  tmds_ch0, tmds_ch1, tmds_ch2;
wire [15:0] audio_l, audio_r;

hdmi_tx hdmi1 (
    .I_rst_n(1'b1), .I_rgb_clk(clk),
    .I_rgb_vs(I_rgb_vs), .I_rgb_hs(I_rgb_hs), .I_rgb_de(I_rgb_de),
    .I_rgb_r(I_rgb_r), .I_rgb_g(I_rgb_g), .I_rgb_b(I_rgb_b),
    .I_audio_l(audio_l), .I_audio_r(audio_r),
    .O_tmds_ch0(tmds_ch0), .O_tmds_ch1(tmds_ch1), .O_tmds_ch2(tmds_ch2),
    .O_audio_ovf(), .O_audio_dropc(), .O_audio_pktc()
);

hdmi_serdes hdmi_ser (
    .clk_pixel(clk), .ref_locked(locked),
    .tmds_ch0(tmds_ch0), .tmds_ch1(tmds_ch1), .tmds_ch2(tmds_ch2),
    .O_tmds_clk_p(O_tmds_clk_p), .O_tmds_clk_n(O_tmds_clk_n),
    .O_tmds_data_p(O_tmds_data_p), .O_tmds_data_n(O_tmds_data_n)
);

//------------------------------------------------------------------------
// Sound: azsound.v's mix, and the OSD's volume divides it down.
//------------------------------------------------------------------------
reg signed [15:0] vol_l = 16'sd0, vol_r = 16'sd0;
always @(posedge clk)
    case (system_volume)
        2'b00: begin vol_l <= 16'sd0;        vol_r <= 16'sd0;        end
        2'b01: begin vol_l <= snd_l >>> 2;   vol_r <= snd_r >>> 2;   end
        2'b10: begin vol_l <= snd_l >>> 1;   vol_r <= snd_r >>> 1;   end
        2'b11: begin vol_l <= snd_l;         vol_r <= snd_r;         end
    endcase

assign audio_l = vol_l;
assign audio_r = vol_r;

i2s_tx i2s (
    .clk(clk), .reset(mist_rst),
    .sample_l(vol_l), .sample_r(vol_r),
    .bck(HP_BCK), .ws(HP_WS), .din(HP_DIN)
);

//------------------------------------------------------------------------
// LEDs, active low on the board: lit is the signal true.
//------------------------------------------------------------------------
assign leds[0] = ~por_done;
assign leds[1] = ~ctl.pending;
assign leds[2] = ~(sd_rbusy | cap_late);
assign leds[3] = ~(bist_fail);
assign leds[4] = ~cpu_rst_req;
assign leds[5] = ~init;

endmodule

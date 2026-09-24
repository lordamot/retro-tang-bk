`timescale 1ns / 1ps
//========================================================================
// cpu.v - the К1801ВМ1 and the bus around it.
//
// The processor is Vslav's 1801VM1 model in Sorgelig's simplified
// synchronous wrapper (vm1/, from the MiSTer BK0011M core, GPL v2), and
// this file is the glue that core keeps in its top module: the clock
// enables, the reset sequencer, the data-in mux, the acknowledge, the
// processor's own two external registers - SEL1 (177716) and SEL2
// (177714), which the core answers itself and whose data come from
// outside - and the vector interrupt controller.
//
// Clocking: 64.8 MHz, and the processor takes a positive enable every
// sixteen clocks and a negative one eight clocks later - 4.05 MHz, the
// BK-0011M's 4 MHz within a percent - or every eight in turbo.  The
// wrapper needs every external signal synchronous to `clk`, which they
// are, and the acknowledge registered on the bus enable, which it is.
//
// The bus as the peripherals see it: `sync` with `addr` for the whole
// cycle, `stb` (a level) with `we` and the byte lanes `wtbt` while data
// moves, `din` the OR of every device's word (each drives zeros when not
// addressed), `ack` the OR of their acknowledges (levels); `wr_stb` and
// `rd_stb` are one-clock pulses on the first clock of the strobe, for
// side effects.  A cycle nobody acknowledges times out inside the
// processor after 64 of its clocks and traps through vector 4, which is
// the BK's behaviour for a hole in the memory map.
//========================================================================
module cpu (
    input             clk,
    input             reset_req,    // level: hold the processor in reset
    input             turbo,        // 8 MHz instead of 4

    output            ce_bus,       // one clock per processor clock
    output            init,         // INIT: the RESET instruction, and the reset itself

    // the bus
    output [15:0]     addr,
    output [15:0]     dout,
    output            sync,
    output            stb,
    output            we,
    output [1:0]      wtbt,
    output            wr_stb,
    output            rd_stb,
    input  [15:0]     din,
    input             ack,

    // interrupts
    input             irq1,         // the СТОП key
    input             irq2,         // the frame timer
    input  [2:0]      vreq,         // vector requests: 60, 274, 174
    output [2:0]      vack,

    // SEL1 (177716): the read side is assembled here
    input  [7:0]      start_addr,   // bits 15:8 of the word read
    input             key_down,
    output            sel1_wr,      // a write to 177716: dout and wtbt are valid
    output            stop_block,   // bit 12 of the last plain write: СТОП masked

    // SEL2 (177714): the read side comes from outside
    input  [15:0]     port_din,
    output            sel2_wr,

    output [15:0]     pc_dbg        // the last address fetched with sync, for the debug window
);

//------------------------------------------------------------------------
// The enables
//------------------------------------------------------------------------
reg  ce_cpu_p = 1'b0, ce_cpu_n = 1'b0, ce_bus_2 = 1'b0;
reg  [4:0] cpu_div = 5'd0;
reg  turbo_r = 1'b0;

always @(posedge clk) begin
    cpu_div <= cpu_div + 5'd1;
    if (cpu_div == (turbo_r ? 5'd7 : 5'd15)) begin
        cpu_div <= 5'd0;
        if (!sync) turbo_r <= turbo;     // change speed only between cycles
    end
    ce_cpu_p <= (cpu_div == 5'd0);
    ce_cpu_n <= (cpu_div == (turbo_r ? 5'd4 : 5'd8));
    ce_bus_2 <= ce_cpu_p;
end
assign ce_bus = ce_cpu_p;

//------------------------------------------------------------------------
// Reset: DCLO for 5 ms, ACLO for 70 ms after the request drops
//------------------------------------------------------------------------
wire cpu_dclo, cpu_aclo;
vm1_reset #(.DCLO_WIDTH(324000), .ACLO_WIDTH(4536000)) rst (
    .clk(clk), .reset(reset_req), .dclo(cpu_dclo), .aclo(cpu_aclo));

//------------------------------------------------------------------------
// The processor
//------------------------------------------------------------------------
wire [15:0] cpu_dout;
wire        cpu_din_out, cpu_dout_out, cpu_iacko, cpu_virq;
wire [2:1]  cpu_psel;
wire        bus_sync, bus_we;
wire [1:0]  bus_wtbt;
wire [15:0] bus_addr;
reg         cpu_ack = 1'b0;
reg  [15:0] cpu_din = 16'd0;
reg  [2:0]  dout_delay = 3'd0;

// the DOUT strobe reaches the slaves two bus clocks late, as the BK's
// write timing has it (MiSTer: dout_delay[2] for the BK-0011M)
wire cpu_dout_in = dout_delay[2] & cpu_dout_out;
wire bus_stb = cpu_dout_in | cpu_din_out;

vm1_se core (
    .pin_clk(clk),
    .pin_ce_p(ce_cpu_p),
    .pin_ce_n(ce_cpu_n),
    .pin_ce_timer(ce_cpu_p),
    .pin_init(init),
    .pin_dclo(cpu_dclo),
    .pin_aclo(cpu_aclo),
    .pin_irq({1'b0, irq2, irq1}),
    .pin_virq(cpu_virq),
    .pin_iako(cpu_iacko),
    .pin_dmr(1'b0),
    .pin_dmgo(),
    .pin_sack(1'b0),
    .pin_addr(bus_addr),
    .pin_dout(cpu_dout),
    .pin_din(cpu_din),
    .pin_sync(bus_sync),
    .pin_we(bus_we),
    .pin_din_stb_out(cpu_din_out),
    .pin_dout_stb_out(cpu_dout_out),
    .pin_din_stb_in(cpu_din_out),
    .pin_dout_stb_in(cpu_dout_in),
    .pin_wtbt(bus_wtbt),
    .pin_rply(cpu_ack),
    .pin_bsy(),
    .pin_sel(cpu_psel)
);

assign addr = bus_addr;
assign dout = cpu_dout;
assign sync = bus_sync;
assign stb  = bus_stb;
assign we   = bus_we;
assign wtbt = bus_wtbt;

reg stb_d = 1'b0;
always @(posedge clk) stb_d <= bus_stb;
assign wr_stb = bus_stb && !stb_d && bus_we;
assign rd_stb = bus_stb && !stb_d && !bus_we;

//------------------------------------------------------------------------
// The processor's own registers: 177700-177716 the core answers itself
// (its data echoed back), SEL1 and SEL2 with outside data.
//------------------------------------------------------------------------
wire        sysreg_sel  = cpu_psel[1];
wire        port_sel    = cpu_psel[2];
wire [15:0] cpureg_data = (bus_sync && !cpu_psel && (bus_addr[15:4] == (16'o177700 >> 4))) ? cpu_dout : 16'd0;
wire [15:0] sysreg_data = sysreg_sel ? {start_addr, 1'b1, ~key_down, 3'b000, super_flg, 2'b00} : 16'd0;
wire [15:0] port_data   = port_sel ? port_din : 16'd0;
wire        sysreg_write = bus_stb & sysreg_sel & bus_we;
wire        port_write   = bus_stb & port_sel & bus_we;

reg  sysreg_write_d = 1'b0, port_write_d = 1'b0;
always @(posedge clk) begin
    sysreg_write_d <= sysreg_write;
    port_write_d   <= port_write;
end
assign sel1_wr = sysreg_write && !sysreg_write_d;
assign sel2_wr = port_write && !port_write_d;

// bit 2 of SEL1: set by a write, cleared by a read
reg  super_flg = 1'b0;
wire sysreg_acc = bus_stb & sysreg_sel;
reg  sysreg_acc_d = 1'b0;
always @(posedge clk) begin
    sysreg_acc_d <= sysreg_acc;
    if (sysreg_acc && !sysreg_acc_d) super_flg <= bus_we;
end

// bit 12 of a plain SEL1 write (bit 11 clear) masks the СТОП key
reg stop_block_r = 1'b0;
assign stop_block = stop_block_r;
always @(posedge clk)
    if (sel1_wr && !cpu_dout[11] && bus_wtbt[1]) stop_block_r <= cpu_dout[12];

//------------------------------------------------------------------------
// Vector interrupts: 60 and 274 from the keyboard, 174 from the AZ
//------------------------------------------------------------------------
wire [15:0] ivec_o;
wire        ivec_sel  = cpu_iacko & !bus_we;
wire [15:0] ivec_data = ivec_sel ? ivec_o : 16'd0;
wire        ivec_ack;

vic_wb #(3) vic (
    .clk_sys(clk),
    .ce(ce_bus),
    .wb_rst_i(init),
    .wb_irq_o(cpu_virq),
    .wb_dat_o(ivec_o),
    .wb_stb_i(ivec_sel & bus_stb),
    .wb_ack_o(ivec_ack),
    .ivec({16'o000174, 16'o000274, 16'o000060}),
    .ireq({vreq[2], vreq[1], vreq[0]}),
    .iack({vack[2], vack[1], vack[0]})
);

//------------------------------------------------------------------------
// Data in and the acknowledge
//------------------------------------------------------------------------
always @(posedge clk) begin
    if (ce_bus_2) begin
        dout_delay <= {dout_delay[1:0], cpu_dout_out};
        cpu_ack    <= ack | ivec_ack;
    end
    cpu_din <= cpureg_data | sysreg_data | port_data | ivec_data | din;
end

// the debug window: the last address a cycle started at
reg [15:0] pc_r = 16'd0;
reg        sync_d = 1'b0;
always @(posedge clk) begin
    sync_d <= bus_sync;
    if (bus_sync && !sync_d) pc_r <= bus_addr;
end
assign pc_dbg = pc_r;

endmodule

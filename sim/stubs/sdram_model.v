//========================================================================
// A functional SDRAM model, enough to run the machine in simulation.
//========================================================================
// The Tang Nano 20K's GW2AR carries an SDRAM die on the same package;
// tang/src/zs256/sdram.v drives it as an MT48LC-style part, 32 bits
// wide here (PK8000 Nano's model was 16).  Without a model
// the machine has no memory at all and nothing runs, so this exists to
// make simulation mean something.
//
// It is FUNCTIONAL, not a datasheet model: it tracks the open row per
// bank and serves reads and writes, but it does not check tRCD, tRP,
// tRFC or refresh intervals.  A timing violation that a real part would
// punish will pass here silently.  Do not use it to prove the controller
// is correct - use it to run the processors.
//
// One protocol rule it does enforce (5 Sep 2026): an ACTIVE to a bank
// whose row is still open is refused - the old row stays open, the event
// is counted and reported at the end ("ACTIVEs on a bank with a row
// still open", must be 0), and a READ or WRITE with A[10] set closes its
// row (auto-precharge), which the model had ignored along with everything
// else about rows.  Until then it silently opened the new row on every
// ACTIVE, and a controller that never precharged (pk8000's sdram.v with
// its A10 bit on A8) booted BASIC here and aliased all 64 KB into one
// row on the board.  See CMD_ACTIVE below.
//
// What sdram.v actually issues, read out of its state machine:
//   ACTIVE with the row on A, then READ or WRITE with A[10] set
//   (auto-precharge) and the column in A[7:0].  CAS latency 2, read
//   burst of 4, single-word writes (NO_WRITE_BURST).
//========================================================================
`timescale 1ns / 1ps

module sdram_model #(
    parameter ROW_BITS  = 11,
    parameter COL_BITS  = 8,
    parameter BANKS     = 4,
    parameter BURST     = 4,
    parameter CAS       = 2
) (
    input                   clk,
    input                   cke,
    input                   cs_n,
    input                   ras_n,
    input                   cas_n,
    input                   we_n,
    input  [1:0]            ba,
    input  [ROW_BITS-1:0]   a,
    input  [3:0]            dqm,
    inout  [31:0]           dq
);
    localparam WORDS = (1 << (ROW_BITS + COL_BITS)) * BANKS;

    reg [31:0] mem [0:WORDS-1];

    // Commands, as {cs_n, ras_n, cas_n, we_n}
    localparam CMD_NOP          = 4'b0111;
    localparam CMD_ACTIVE       = 4'b0011;
    localparam CMD_READ         = 4'b0101;
    localparam CMD_WRITE        = 4'b0100;
    localparam CMD_PRECHARGE    = 4'b0010;
    localparam CMD_AUTO_REFRESH = 4'b0001;
    localparam CMD_LOAD_MODE    = 4'b0000;

    wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};

    reg [ROW_BITS-1:0] open_row [0:BANKS-1];
    reg                row_open [0:BANKS-1];
    integer            open_bank_acts = 0;   // ACTIVEs refused, see CMD_ACTIVE

    // Read pipeline: CAS latency stages, then BURST words out.
    reg [31:0]         rd_pipe   [0:CAS];
    reg                rd_valid  [0:CAS];
    reg [COL_BITS-1:0] burst_col;
    reg [1:0]          burst_bank;
    integer            burst_left;

    reg [31:0] dq_out;
    reg        dq_oe;
    assign dq = dq_oe ? dq_out : 32'hZZZZZZZZ;

    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'h00000000;
        for (i = 0; i < BANKS; i = i + 1) begin
            open_row[i] = 0;
            row_open[i] = 1'b0;
        end
        for (i = 0; i <= CAS; i = i + 1) begin
            rd_pipe[i]  = 32'h00000000;
            rd_valid[i] = 1'b0;
        end
        burst_left = 0;
        burst_col  = 0;
        burst_bank = 0;
        dq_out     = 32'h00000000;
        dq_oe      = 1'b0;
    end

    function integer flat;
        input [1:0]          bk;
        input [ROW_BITS-1:0] rw;
        input [COL_BITS-1:0] cl;
        begin
            flat = ((bk * (1 << ROW_BITS)) + rw) * (1 << COL_BITS) + cl;
        end
    endfunction

    // Optional preload, so a test can start with memory in a known state.
    parameter PRELOAD_HEX = "";
    parameter PRELOAD_AT  = 0;
    initial if (PRELOAD_HEX != "") begin
        $display("[sdram] preloading %0s at word %0d", PRELOAD_HEX, PRELOAD_AT);
        $readmemh(PRELOAD_HEX, mem, PRELOAD_AT);
    end

    always @(posedge clk) if (cke) begin
        // Advance the CAS pipeline first, so this cycle's command lands
        // at the far end of it.
        for (i = CAS; i > 0; i = i - 1) begin
            rd_pipe[i]  <= rd_pipe[i-1];
            rd_valid[i] <= rd_valid[i-1];
        end
        rd_pipe[0]  <= 32'h00000000;
        rd_valid[0] <= 1'b0;

        // Continue an in-flight read burst.
        if (burst_left > 0) begin
            rd_pipe[0]  <= mem[flat(burst_bank, open_row[burst_bank], burst_col)];
            rd_valid[0] <= 1'b1;
            // Sequential burst, wrapping inside the burst-length boundary.
            burst_col   <= (burst_col & ~(BURST-1)) |
                           ((burst_col + 1) & (BURST-1));
            burst_left  <= burst_left - 1;
        end

        case (cmd)
            CMD_ACTIVE: begin
                // An ACTIVE to a bank whose row is still open is illegal
                // on the part, and what a real one does is not specified.
                // This model keeps the OLD row, which is what the board
                // looked like on 5 Sep 2026 when sdram.v's column word had
                // its 1 on A8 instead of A10 and nothing ever precharged:
                // every row's traffic landed in one row, zeros read back
                // as zeros and the stack came back zeroed by the ROM's
                // fill of other rows.  Counted, and the first few said.
                if (row_open[ba]) begin
                    open_bank_acts <= open_bank_acts + 1;
                    if (open_bank_acts < 4)
                        $display("[sdram] %0t ACTIVE on bank %0d row %0h with row %0h still open - no precharge; the old row stays",
                                 $time, ba, a, open_row[ba]);
                end else begin
                    open_row[ba] <= a;
                    row_open[ba] <= 1'b1;
                end
            end

            CMD_PRECHARGE: begin
                if (a[10]) for (i = 0; i < BANKS; i = i + 1) row_open[i] <= 1'b0;
                else       row_open[ba] <= 1'b0;
            end

            CMD_READ: begin
                if (!row_open[ba])
                    $display("[sdram] %0t READ from bank %0d with no open row",
                             $time, ba);
                if ($test$plusargs("SDRAMTRACE"))
                    $display("[sdram] %0t RD b%0d r%0d c%0d => %08x",
                             $time, ba, open_row[ba], a[COL_BITS-1:0],
                             mem[flat(ba, open_row[ba], a[COL_BITS-1:0])]);
                rd_pipe[0]  <= mem[flat(ba, open_row[ba], a[COL_BITS-1:0])];
                rd_valid[0] <= 1'b1;
                if (a[10]) row_open[ba] <= 1'b0;   // auto-precharge: the row closes (open_row stays for the burst)
                burst_bank  <= ba;
                burst_col   <= (a[COL_BITS-1:0] & ~(BURST-1)) |
                               ((a[COL_BITS-1:0] + 1) & (BURST-1));
                burst_left  <= BURST - 1;
            end

            CMD_WRITE: begin
                if (!row_open[ba])
                    $display("[sdram] %0t WRITE to bank %0d with no open row",
                             $time, ba);
                if ($test$plusargs("SDRAMTRACE"))
                    $display("[sdram] %0t WR b%0d r%0d c%0d <= %08x dqm %b",
                             $time, ba, open_row[ba], a[COL_BITS-1:0],
                             dq, dqm);
                if (!dqm[0]) mem[flat(ba, open_row[ba], a[COL_BITS-1:0])][ 7:0]  <= dq[ 7:0];
                if (!dqm[1]) mem[flat(ba, open_row[ba], a[COL_BITS-1:0])][15:8]  <= dq[15:8];
                if (!dqm[2]) mem[flat(ba, open_row[ba], a[COL_BITS-1:0])][23:16] <= dq[23:16];
                if (!dqm[3]) mem[flat(ba, open_row[ba], a[COL_BITS-1:0])][31:24] <= dq[31:24];
                if (a[10]) row_open[ba] <= 1'b0;   // auto-precharge
                burst_left <= 0;   // NO_WRITE_BURST
            end

            default: ;   // NOP, AUTO_REFRESH, LOAD_MODE, INHIBIT
        endcase
    end

    // Drive DQ when the pipeline has data at the far end.
    //
    // The stage is CAS-1, not CAS, and the off-by-one matters: stage 0 is
    // loaded by the non-blocking assignment at the edge that carries the
    // READ command, so it only becomes visible after that edge.  Driving
    // from stage CAS would put the word on the bus one clock after the
    // controller reads it - which is exactly the failure this model had:
    // every read came back as zero, the PPU's vectors stayed zero, and
    // the machine sat in a trap loop for ever.  With CL=2 the controller
    // samples at the second edge after the command, so the word has to be
    // on the bus from the first.
    // +SDRAM_LATE drives from stage CAS instead - the word a clock later
    // than the arithmetic in sdram.v expects, to exercise the controller's
    // self-test and its move to the later capture (4 Sep 2026).
    reg late = 1'b0;
    initial late = $test$plusargs("SDRAM_LATE");
    always @(*) begin
        dq_oe  = late ? rd_valid[CAS] : rd_valid[CAS-1];
        dq_out = late ? rd_pipe[CAS]  : rd_pipe[CAS-1];
    end
    final $display("[sdram] ACTIVEs on a bank with a row still open: %0d (must be 0)", open_bank_acts);

endmodule

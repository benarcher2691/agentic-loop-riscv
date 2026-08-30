`timescale 1ns/1ps
`default_nettype none
// Standalone C-program runner: instantiates the real Processor (+ Decoder/ALU)
// against a behavioural memory that loads build/cprog.hex, and a UART sink that
// prints bytes the program stores to 0x400008. Ends when the CPU EBREAK-halts.
// Reuses the shipped RTL unchanged — this is a bench, not part of the SoC.
module csim;
  reg clk = 0, resetn = 0;
  always #5 clk = ~clk;
  initial begin resetn = 0; repeat(4) @(posedge clk); resetn = 1; end

  wire [31:0] mem_addr, mem_wdata;
  wire        mem_rstrb;
  wire [3:0]  mem_wmask;
  reg  [31:0] mem_rdata;

  Processor cpu(.clk(clk), .resetn(resetn), .mem_addr(mem_addr),
                .mem_rdata(mem_rdata), .mem_rstrb(mem_rstrb),
                .mem_wdata(mem_wdata), .mem_wmask(mem_wmask));

  reg [31:0] MEM [0:1535];               // 6 KB, same size as the real Memory
  integer i;
  initial begin
    for (i = 0; i < 1536; i = i + 1) MEM[i] = 32'd0;
    $readmemh("../build/cprog.hex", MEM);
  end

  wire        io   = mem_addr[22];
  wire [10:0] word = mem_addr[12:2];

  // UART input model: +instr=<chars> feeds those bytes, then one trailing
  // newline (0x0A), to reads of 0x400020. No +instr -> empty queue -> avail
  // always 0, exactly as before this feature. $value$plusargs %s stores the
  // string right-justified (LAST character in the lowest byte), so the queue
  // is rebuilt by scanning from the highest non-zero byte downwards.
  reg [8*64:1] instr_arg;
  reg [7:0]    inq [0:64];
  integer      inq_len, inq_head, k, top;
  initial begin
    inq_len = 0; inq_head = 0;
    if ($value$plusargs("instr=%s", instr_arg)) begin
      top = -1;
      for (k = 0; k < 64; k = k + 1)
        if (instr_arg[8*k+1 +: 8] != 8'h00) top = k;
      for (k = top; k >= 0; k = k - 1) begin
        inq[inq_len] = instr_arg[8*k+1 +: 8];
        inq_len = inq_len + 1;
      end
      inq[inq_len] = 8'h0A;                          // the typed Enter
      inq_len = inq_len + 1;
    end
  end

  // synchronous RAM read (holds mem_rdata while the strobe is low — the
  // Processor relies on this, exactly like the real Memory)
  always @(posedge clk) if (mem_rstrb & ~io) mem_rdata <= MEM[word];
  // IO reads: status word (0x400010) reports never-busy; 0x400020 is the UART
  // input word (below); everything else reads 0
  always @(posedge clk) if (mem_rstrb & io) begin
    if (mem_addr[5:2] == 4'b1000) begin
      if (inq_head < inq_len) begin
        mem_rdata <= {23'd0, 1'b1, inq[inq_head]};   // avail=1, byte
        inq_head  = inq_head + 1;                    // the read pops the queue
      end else
        mem_rdata <= {23'd0, 1'b0, 8'd0};            // empty: avail=0
    end else
      mem_rdata <= 32'd0;
  end

  // RAM byte-writes
  always @(posedge clk) if (~io) begin
    if (mem_wmask[0]) MEM[word][ 7: 0] <= mem_wdata[ 7: 0];
    if (mem_wmask[1]) MEM[word][15: 8] <= mem_wdata[15: 8];
    if (mem_wmask[2]) MEM[word][23:16] <= mem_wdata[23:16];
    if (mem_wmask[3]) MEM[word][31:24] <= mem_wdata[31:24];
  end
  // UART sink: a full-word store to 0x400008 transmits the low byte
  always @(posedge clk)
    if (io & (mem_addr[5:2] == 4'b0010) & (mem_wmask == 4'b1111))
      $write("%c", mem_wdata[7:0]);

  // EBREAK halts the core: PC and state freeze. Detect a stall and finish.
  reg [31:0] lastpc = 32'hFFFF; integer stuck = 0;
  always @(posedge clk) if (resetn) begin
    if (cpu.PC === lastpc) stuck = stuck + 1; else stuck = 0;
    lastpc <= cpu.PC;
    if (stuck > 8) begin $display("\n[csim] halted at PC=0x%0h", cpu.PC); $finish; end
  end
  initial begin #2000000; $display("\n[csim] TIMEOUT"); $finish; end
endmodule
`default_nettype wire

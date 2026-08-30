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

  // synchronous RAM read (holds mem_rdata while the strobe is low — the
  // Processor relies on this, exactly like the real Memory)
  always @(posedge clk) if (mem_rstrb & ~io) mem_rdata <= MEM[word];
  // IO reads: status word (0x400010) reports never-busy; others read 0
  always @(posedge clk) if (mem_rstrb & io)  mem_rdata <= 32'd0;

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

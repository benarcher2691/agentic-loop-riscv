`timescale 1ns/1ps
// RTL vs post-synthesis co-simulation: both SOCs get the same clock; their
// port outputs must agree on every cycle.
module equiv_tb;
  reg CLK = 0; reg RXD = 1;
  wire TXD_r, TXD_s; wire [4:0] LEDS_r, LEDS_s;
  SOC       rtl (.CLK(CLK), .RXD(RXD), .TXD(TXD_r), .LEDS(LEDS_r));
  SOC_synth             syn (.CLK(CLK), .RXD(RXD), .TXD(TXD_s), .LEDS(LEDS_s));
  always #41.667 CLK = ~CLK;
  integer cyc = 0, mism = 0, changes = 0; reg [4:0] last = 5'bx;
  always @(posedge CLK) begin
    cyc = cyc + 1;
    if (LEDS_r !== LEDS_s || TXD_r !== TXD_s) begin
      mism = mism + 1;
      if (mism <= 5) $display("MISMATCH cycle %0d: rtl LEDS=%b TXD=%b  synth LEDS=%b TXD=%b", cyc, LEDS_r, TXD_r, LEDS_s, TXD_s);
    end
    if (LEDS_r !== last) begin changes = changes + 1; last = LEDS_r; end
    if (cyc == 4000) begin
      $display("cycles=%0d led_changes(rtl)=%0d mismatches=%0d final rtl=%b synth=%b", cyc, changes, mism, LEDS_r, LEDS_s);
      if (mism == 0) $display("PASS"); else $display("FAIL");
      $finish;
    end
  end
endmodule

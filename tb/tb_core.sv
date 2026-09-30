`timescale 1ns/1ps
// Usage: vvp build/sim +hex=build/basic.hex [+vcd]
module tb_core;
  logic clk = 0;
  logic rst = 1;
  always #5 clk = ~clk;

  logic        uart_valid, halt;
  logic [7:0]  uart_data;
  logic [31:0] halt_code;
  logic [31:0] cycles, instret, branches, mispredicts, stalls;

  soc_top dut (
    .clk(clk), .rst(rst),
    .uart_valid(uart_valid), .uart_data(uart_data),
    .halt(halt), .halt_code(halt_code),
    .perf_cycles(cycles), .perf_instret(instret), .perf_branches(branches),
    .perf_mispredicts(mispredicts), .perf_stalls(stalls)
  );

  string hexfile;
  initial begin
    if (!$value$plusargs("hex=%s", hexfile)) begin
      $display("usage: vvp sim +hex=<file.hex> [+vcd]");
      $finish;
    end
    $readmemh(hexfile, dut.imem);
    if ($test$plusargs("vcd")) begin
      $dumpfile("build/sim.vcd");
      $dumpvars(0, tb_core);
    end
    repeat (4) @(posedge clk);
    rst <= 0;
  end

  // UART console
  always @(posedge clk) if (uart_valid) $write("%c", uart_data);

  // Finish / timeout
  integer ticks = 0;
  always @(posedge clk) begin
    ticks <= ticks + 1;
    if (halt) begin
      $display("----------------------------------------");
      if (halt_code == 0) $display("RESULT: PASS");
      else                $display("RESULT: FAIL (failing test id = %0d)", halt_code);
      $display("cycles=%0d  instret=%0d  CPI=%0.3f", cycles, instret, cycles * 1.0 / instret);
      $display("stalls(load-use)=%0d  branches=%0d  mispredicts=%0d  accuracy=%0.1f%%",
               stalls, branches, mispredicts,
               branches ? 100.0 * (branches - mispredicts) / branches : 0.0);
      $finish;
    end
    if (ticks > 200000) begin
      $display("RESULT: FAIL (timeout)");
      $finish;
    end
  end
endmodule

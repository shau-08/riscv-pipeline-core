// Minimal SoC: core + 4 KiB instruction ROM + 4 KiB data RAM + tiny MMIO.
//
//   0x0000_0000 - 0x0000_0FFF : data RAM (aliased across 4 KiB)
//   0x1000_0000               : UART TX   (write a byte)
//   0x1000_0004               : HALT      (write exit code; 0 == pass)
module soc_top #(
  parameter INIT_FILE = ""
)(
  input  logic        clk,
  input  logic        rst,
  output logic        uart_valid,
  output logic [7:0]  uart_data,
  output logic        halt,
  output logic [31:0] halt_code,
  output logic [31:0] perf_cycles,
  output logic [31:0] perf_instret,
  output logic [31:0] perf_branches,
  output logic [31:0] perf_mispredicts,
  output logic [31:0] perf_stalls
);
  logic [31:0] imem [0:1023];
  logic [31:0] dmem [0:1023];
  integer i;
  initial begin
    for (i = 0; i < 1024; i = i + 1) dmem[i] = 32'b0;
    if (INIT_FILE != "") $readmemh(INIT_FILE, imem);
  end

  logic [31:0] imem_addr, imem_rdata;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_wstrb;
  logic        dmem_re;

  core u_core (
    .clk(clk), .rst(rst),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata),
    .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_wstrb(dmem_wstrb),
    .dmem_re(dmem_re), .dmem_rdata(dmem_rdata),
    .perf_cycles(perf_cycles), .perf_instret(perf_instret),
    .perf_branches(perf_branches), .perf_mispredicts(perf_mispredicts),
    .perf_stalls(perf_stalls)
  );

  assign imem_rdata = imem[imem_addr[11:2]];

  wire is_ram  = (dmem_addr[31:28] == 4'h0);
  wire is_mmio = (dmem_addr[31:28] == 4'h1);
  wire wr      = |dmem_wstrb;

  assign dmem_rdata = is_ram ? dmem[dmem_addr[11:2]] : 32'b0;

  always_ff @(posedge clk) begin
    if (wr && is_ram) begin
      if (dmem_wstrb[0]) dmem[dmem_addr[11:2]][7:0]   <= dmem_wdata[7:0];
      if (dmem_wstrb[1]) dmem[dmem_addr[11:2]][15:8]  <= dmem_wdata[15:8];
      if (dmem_wstrb[2]) dmem[dmem_addr[11:2]][23:16] <= dmem_wdata[23:16];
      if (dmem_wstrb[3]) dmem[dmem_addr[11:2]][31:24] <= dmem_wdata[31:24];
    end
  end

  assign uart_valid = wr && is_mmio && (dmem_addr[3:2] == 2'd0);
  assign uart_data  = dmem_wdata[7:0];
  assign halt       = wr && is_mmio && (dmem_addr[3:2] == 2'd1);
  assign halt_code  = dmem_wdata;
endmodule

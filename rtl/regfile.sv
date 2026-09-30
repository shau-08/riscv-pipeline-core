// 32x32 register file, 2 read ports, 1 write port.
// Write happens on the clock edge; reads have an internal bypass so an
// instruction in ID sees a value being written by WB in the same cycle.
module regfile (
  input  logic        clk,
  input  logic        we,
  input  logic [4:0]  waddr,
  input  logic [31:0] wdata,
  input  logic [4:0]  raddr1,
  input  logic [4:0]  raddr2,
  output logic [31:0] rdata1,
  output logic [31:0] rdata2
);
  logic [31:0] regs [0:31];
  integer i;
  initial for (i = 0; i < 32; i = i + 1) regs[i] = 32'b0;

  always_ff @(posedge clk)
    if (we && waddr != 5'd0) regs[waddr] <= wdata;

  assign rdata1 = (raddr1 == 5'd0)           ? 32'b0 :
                  (we && waddr == raddr1)    ? wdata : regs[raddr1];
  assign rdata2 = (raddr2 == 5'd0)           ? 32'b0 :
                  (we && waddr == raddr2)    ? wdata : regs[raddr2];
endmodule

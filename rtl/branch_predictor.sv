// Bimodal branch predictor: table of 2-bit saturating counters indexed by PC.
//   00 strongly not-taken | 01 weakly not-taken | 10 weakly taken | 11 strongly taken
// Lookup happens in ID (combinational), update happens when the branch resolves in EX.
module branch_predictor #(
  parameter INDEX_BITS = 6
)(
  input  logic        clk,
  input  logic        rst,
  input  logic [31:0] lookup_pc,
  output logic        predict_taken,
  input  logic        update_en,
  input  logic [31:0] update_pc,
  input  logic        update_taken
);
  localparam N = 1 << INDEX_BITS;
  logic [1:0] bht [0:N-1];
  integer i;

  wire [INDEX_BITS-1:0] lidx = lookup_pc[INDEX_BITS+1:2];
  wire [INDEX_BITS-1:0] uidx = update_pc[INDEX_BITS+1:2];

  assign predict_taken = bht[lidx][1];

  always_ff @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < N; i = i + 1) bht[i] <= 2'b01;
    end else if (update_en) begin
      if (update_taken && bht[uidx] != 2'b11) bht[uidx] <= bht[uidx] + 2'b01;
      else if (!update_taken && bht[uidx] != 2'b00) bht[uidx] <= bht[uidx] - 2'b01;
    end
  end
endmodule

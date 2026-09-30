// RV32M multiply/divide unit. Purely combinational and behavioural: great for
// learning the corner-case rules, NOT timing-friendly. A real design would use
// a multi-cycle divider and a pipelined multiplier (see README ideas).
module mdu (
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic [2:0]  funct3,
  output logic [31:0] y
);
  wire signed [63:0] p_ss = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
  wire signed [63:0] p_su = $signed({{32{a[31]}}, a}) * $signed({32'b0, b});
  wire        [63:0] p_uu = {32'b0, a} * {32'b0, b};

  wire a_min_b_m1 = (a == 32'h8000_0000) && (b == 32'hFFFF_FFFF);

  // GOTCHA: if a signed '/' or '%' appears inside a ?: chain that also has
  // unsigned operands, the WHOLE expression is evaluated as unsigned. Compute
  // the signed results in their own signed wires first.
  wire signed [31:0] sa    = a;
  wire signed [31:0] sb    = b;
  wire signed [31:0] s_div = sa / sb;     // don't-care when b == 0 (masked below)
  wire signed [31:0] s_rem = sa % sb;

  always_comb begin
    case (funct3)
      3'b000: y = p_ss[31:0];                     // MUL
      3'b001: y = p_ss[63:32];                    // MULH
      3'b010: y = p_su[63:32];                    // MULHSU
      3'b011: y = p_uu[63:32];                    // MULHU
      3'b100: y = (b == 0)      ? 32'hFFFF_FFFF : // DIV  (div by 0 -> -1)
                  a_min_b_m1    ? a :             //      (overflow  -> a)
                  s_div;
      3'b101: y = (b == 0)      ? 32'hFFFF_FFFF : a / b;  // DIVU
      3'b110: y = (b == 0)      ? a :             // REM  (rem by 0 -> a)
                  a_min_b_m1    ? 32'b0 :         //      (overflow  -> 0)
                  s_rem;
      3'b111: y = (b == 0)      ? a : a % b;      // REMU
    endcase
  end
endmodule

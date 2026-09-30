// Shared constants. `include this INSIDE a module body.
localparam [6:0] OP_LUI    = 7'b0110111;
localparam [6:0] OP_AUIPC  = 7'b0010111;
localparam [6:0] OP_JAL    = 7'b1101111;
localparam [6:0] OP_JALR   = 7'b1100111;
localparam [6:0] OP_BRANCH = 7'b1100011;
localparam [6:0] OP_LOAD   = 7'b0000011;
localparam [6:0] OP_STORE  = 7'b0100011;
localparam [6:0] OP_IMM    = 7'b0010011;
localparam [6:0] OP_REG    = 7'b0110011;

localparam [3:0] ALU_ADD  = 4'd0;
localparam [3:0] ALU_SUB  = 4'd1;
localparam [3:0] ALU_SLL  = 4'd2;
localparam [3:0] ALU_SLT  = 4'd3;
localparam [3:0] ALU_SLTU = 4'd4;
localparam [3:0] ALU_XOR  = 4'd5;
localparam [3:0] ALU_SRL  = 4'd6;
localparam [3:0] ALU_SRA  = 4'd7;
localparam [3:0] ALU_OR   = 4'd8;
localparam [3:0] ALU_AND  = 4'd9;

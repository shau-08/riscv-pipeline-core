// 5-stage pipelined RV32IM core: IF -> ID -> EX -> MEM -> WB
//
// Hazard strategy
//   * Data hazards : forwarding into EX from EX/MEM and MEM/WB,
//                    regfile write-through bypass for WB->ID.
//   * Load-use     : 1-cycle stall (freeze PC + IF/ID, bubble into ID/EX).
//   * Control      : JAL and predicted-taken branches redirect from ID
//                    (1-cycle penalty). Branch mispredictions and JALR
//                    redirect from EX (2-cycle penalty).
module core (
  input  logic        clk,
  input  logic        rst,
  // instruction memory (combinational read)
  output logic [31:0] imem_addr,
  input  logic [31:0] imem_rdata,
  // data memory (combinational read, byte-strobed write on clk edge)
  output logic [31:0] dmem_addr,
  output logic [31:0] dmem_wdata,
  output logic [3:0]  dmem_wstrb,
  output logic        dmem_re,
  input  logic [31:0] dmem_rdata,
  // performance counters
  output logic [31:0] perf_cycles,
  output logic [31:0] perf_instret,
  output logic [31:0] perf_branches,
  output logic [31:0] perf_mispredicts,
  output logic [31:0] perf_stalls
);
  `include "rv_defs.vh"
  localparam [31:0] NOP = 32'h0000_0013;   // addi x0, x0, 0

  // ------------------------------------------------------------------
  // Global control wires (declared up-front, driven further down)
  // ------------------------------------------------------------------
  logic        stall;
  logic        ex_redirect;
  logic [31:0] ex_target;
  logic        id_redirect;
  logic [31:0] id_target;

  // ==================================================================
  // IF stage
  // ==================================================================
  logic [31:0] pc;
  assign imem_addr = pc;

  always_ff @(posedge clk) begin
    if (rst)              pc <= 32'b0;
    else if (ex_redirect) pc <= ex_target;
    else if (stall)       pc <= pc;
    else if (id_redirect) pc <= id_target;
    else                  pc <= pc + 32'd4;
  end

  // IF/ID pipeline register
  logic [31:0] ifid_pc, ifid_instr;
  logic        ifid_valid;

  always_ff @(posedge clk) begin
    if (rst || ex_redirect || id_redirect) begin   // id_redirect already excludes stall
      ifid_pc    <= 32'b0;
      ifid_instr <= NOP;
      ifid_valid <= 1'b0;
    end else if (!stall) begin
      ifid_pc    <= pc;
      ifid_instr <= imem_rdata;
      ifid_valid <= 1'b1;
    end
  end

  // ==================================================================
  // ID stage
  // ==================================================================
  wire [6:0] id_opcode = ifid_instr[6:0];
  wire [4:0] id_rd     = ifid_instr[11:7];
  wire [2:0] id_f3     = ifid_instr[14:12];
  wire [4:0] id_rs1    = ifid_instr[19:15];
  wire [4:0] id_rs2    = ifid_instr[24:20];
  wire [6:0] id_f7     = ifid_instr[31:25];

  wire [31:0] imm_i = {{20{ifid_instr[31]}}, ifid_instr[31:20]};
  wire [31:0] imm_s = {{20{ifid_instr[31]}}, ifid_instr[31:25], ifid_instr[11:7]};
  wire [31:0] imm_b = {{19{ifid_instr[31]}}, ifid_instr[31], ifid_instr[7],
                       ifid_instr[30:25], ifid_instr[11:8], 1'b0};
  wire [31:0] imm_u = {ifid_instr[31:12], 12'b0};
  wire [31:0] imm_j = {{11{ifid_instr[31]}}, ifid_instr[31], ifid_instr[19:12],
                       ifid_instr[20], ifid_instr[30:21], 1'b0};

  function automatic [3:0] alu_from_f3(input [2:0] f3, input alt_sub, input alt_sra);
    case (f3)
      3'b000: alu_from_f3 = alt_sub ? ALU_SUB : ALU_ADD;
      3'b001: alu_from_f3 = ALU_SLL;
      3'b010: alu_from_f3 = ALU_SLT;
      3'b011: alu_from_f3 = ALU_SLTU;
      3'b100: alu_from_f3 = ALU_XOR;
      3'b101: alu_from_f3 = alt_sra ? ALU_SRA : ALU_SRL;
      3'b110: alu_from_f3 = ALU_OR;
      3'b111: alu_from_f3 = ALU_AND;
    endcase
  endfunction

  // Decoded control signals
  logic        id_reg_write, id_mem_read, id_mem_write;
  logic        id_is_branch, id_is_jal, id_is_jalr, id_is_m;
  logic        id_use_imm, id_use_pc, id_zero_a;
  logic        id_uses_rs1, id_uses_rs2;
  logic [3:0]  id_alu_func;
  logic [31:0] id_imm;

  always_comb begin
    id_reg_write = 0; id_mem_read = 0; id_mem_write = 0;
    id_is_branch = 0; id_is_jal = 0;   id_is_jalr = 0;  id_is_m = 0;
    id_use_imm = 0;   id_use_pc = 0;   id_zero_a = 0;
    id_uses_rs1 = 1;  id_uses_rs2 = 0;
    id_alu_func = ALU_ADD;
    id_imm = 32'b0;
    case (id_opcode)
      OP_LUI:    begin id_reg_write = 1; id_use_imm = 1; id_zero_a = 1; id_uses_rs1 = 0; id_imm = imm_u; end
      OP_AUIPC:  begin id_reg_write = 1; id_use_imm = 1; id_use_pc = 1; id_uses_rs1 = 0; id_imm = imm_u; end
      OP_JAL:    begin id_reg_write = 1; id_is_jal = 1;  id_uses_rs1 = 0; id_imm = imm_j; end
      OP_JALR:   begin id_reg_write = 1; id_is_jalr = 1; id_use_imm = 1; id_imm = imm_i; end
      OP_BRANCH: begin id_is_branch = 1; id_uses_rs2 = 1; id_imm = imm_b; end
      OP_LOAD:   begin id_reg_write = 1; id_mem_read = 1; id_use_imm = 1; id_imm = imm_i; end
      OP_STORE:  begin id_mem_write = 1; id_use_imm = 1; id_uses_rs2 = 1; id_imm = imm_s; end
      OP_IMM:    begin id_reg_write = 1; id_use_imm = 1; id_imm = imm_i;
                       id_alu_func = alu_from_f3(id_f3, 1'b0, id_f7[5]); end
      OP_REG:    begin id_reg_write = 1; id_uses_rs2 = 1;
                       if (id_f7 == 7'b0000001) id_is_m = 1;
                       else id_alu_func = alu_from_f3(id_f3, id_f7[5], id_f7[5]); end
      default:   begin id_uses_rs1 = 0; end   // unknown opcode -> behaves as NOP
    endcase
  end

  // Register file (written from WB)
  logic        wb_we;
  logic [4:0]  wb_rd;
  logic [31:0] wb_wdata;
  logic [31:0] id_rs1_val, id_rs2_val;

  regfile u_rf (
    .clk(clk), .we(wb_we), .waddr(wb_rd), .wdata(wb_wdata),
    .raddr1(id_rs1), .raddr2(id_rs2), .rdata1(id_rs1_val), .rdata2(id_rs2_val)
  );

  // Load-use hazard detection (instruction in EX is a load whose rd is needed now)
  logic        idex_valid, idex_mem_read;
  logic [4:0]  idex_rd;

  assign stall = ifid_valid && idex_valid && idex_mem_read && (idex_rd != 5'd0) &&
                 ((id_uses_rs1 && idex_rd == id_rs1) ||
                  (id_uses_rs2 && idex_rd == id_rs2));

  // Branch prediction (lookup in ID, update from EX)
  logic        ex_branch_taken;
  logic        idex_is_branch;
  logic [31:0] idex_pc;
  logic        bp_taken;

  branch_predictor u_bp (
    .clk(clk), .rst(rst),
    .lookup_pc(ifid_pc), .predict_taken(bp_taken),
    .update_en(idex_valid && idex_is_branch),
    .update_pc(idex_pc), .update_taken(ex_branch_taken)
  );

`ifdef NO_BP
  wire id_pred_taken = 1'b0;                       // static not-taken baseline
`else
  wire id_pred_taken = id_is_branch & bp_taken;
`endif

  assign id_redirect = ifid_valid && !stall && !ex_redirect &&
                       (id_is_jal || id_pred_taken);
  assign id_target   = ifid_pc + id_imm;

  // ID/EX pipeline register
  logic [31:0] idex_rs1_val, idex_rs2_val, idex_imm;
  logic [4:0]  idex_rs1, idex_rs2;
  logic [2:0]  idex_f3;
  logic [3:0]  idex_alu_func;
  logic        idex_reg_write, idex_mem_write;
  logic        idex_is_jal, idex_is_jalr, idex_is_m;
  logic        idex_use_imm, idex_use_pc, idex_zero_a, idex_pred_taken;

  always_ff @(posedge clk) begin
    if (rst || ex_redirect || stall) begin
      // insert a bubble
      idex_valid <= 0; idex_reg_write <= 0; idex_mem_read <= 0; idex_mem_write <= 0;
      idex_is_branch <= 0; idex_is_jal <= 0; idex_is_jalr <= 0; idex_is_m <= 0;
      idex_rd <= 0; idex_rs1 <= 0; idex_rs2 <= 0; idex_pred_taken <= 0;
    end else begin
      idex_valid      <= ifid_valid;
      idex_pc         <= ifid_pc;
      idex_rs1_val    <= id_rs1_val;
      idex_rs2_val    <= id_rs2_val;
      idex_imm        <= id_imm;
      idex_rs1        <= id_rs1;
      idex_rs2        <= id_rs2;
      idex_rd         <= id_rd;
      idex_f3         <= id_f3;
      idex_alu_func   <= id_alu_func;
      idex_reg_write  <= id_reg_write;
      idex_mem_read   <= id_mem_read;
      idex_mem_write  <= id_mem_write;
      idex_is_branch  <= id_is_branch;
      idex_is_jal     <= id_is_jal;
      idex_is_jalr    <= id_is_jalr;
      idex_is_m       <= id_is_m;
      idex_use_imm    <= id_use_imm;
      idex_use_pc     <= id_use_pc;
      idex_zero_a     <= id_zero_a;
      idex_pred_taken <= id_pred_taken;
    end
  end

  // ==================================================================
  // EX stage
  // ==================================================================
  logic        exmem_reg_write, memwb_reg_write;
  logic [4:0]  exmem_rd, memwb_rd;
  logic [31:0] exmem_result, memwb_wdata;

  // Forwarding muxes: youngest producer wins (EX/MEM, then MEM/WB, else regfile)
  logic [31:0] fwd_a, fwd_b;
  always_comb begin
    fwd_a = idex_rs1_val;
    if (exmem_reg_write && exmem_rd != 5'd0 && exmem_rd == idex_rs1)
      fwd_a = exmem_result;
    else if (memwb_reg_write && memwb_rd != 5'd0 && memwb_rd == idex_rs1)
      fwd_a = memwb_wdata;

    fwd_b = idex_rs2_val;
    if (exmem_reg_write && exmem_rd != 5'd0 && exmem_rd == idex_rs2)
      fwd_b = exmem_result;
    else if (memwb_reg_write && memwb_rd != 5'd0 && memwb_rd == idex_rs2)
      fwd_b = memwb_wdata;
  end

  wire [31:0] alu_a = idex_zero_a ? 32'b0 : idex_use_pc ? idex_pc : fwd_a;
  wire [31:0] alu_b = idex_use_imm ? idex_imm : fwd_b;
  logic [31:0] alu_y, mdu_y;

  alu u_alu (.a(alu_a), .b(alu_b), .func(idex_alu_func), .y(alu_y));
  mdu u_mdu (.a(fwd_a), .b(fwd_b), .funct3(idex_f3), .y(mdu_y));

  wire [31:0] ex_result = (idex_is_jal || idex_is_jalr) ? idex_pc + 32'd4 :
                          idex_is_m                     ? mdu_y : alu_y;

  // Branch resolution
  logic cond;
  always_comb begin
    case (idex_f3)
      3'b000:  cond = (fwd_a == fwd_b);                    // BEQ
      3'b001:  cond = (fwd_a != fwd_b);                    // BNE
      3'b100:  cond = ($signed(fwd_a) <  $signed(fwd_b));  // BLT
      3'b101:  cond = ($signed(fwd_a) >= $signed(fwd_b));  // BGE
      3'b110:  cond = (fwd_a <  fwd_b);                    // BLTU
      3'b111:  cond = (fwd_a >= fwd_b);                    // BGEU
      default: cond = 1'b0;
    endcase
  end

  assign ex_branch_taken = idex_is_branch && cond;
  wire   ex_mispredict   = idex_valid && idex_is_branch && (ex_branch_taken != idex_pred_taken);
  assign ex_redirect     = idex_valid && (ex_mispredict || idex_is_jalr);
  assign ex_target       = idex_is_jalr      ? (alu_y & 32'hFFFF_FFFE) :
                           ex_branch_taken   ? (idex_pc + idex_imm)    :
                                               (idex_pc + 32'd4);

  // EX/MEM pipeline register
  logic        exmem_valid, exmem_mem_read, exmem_mem_write;
  logic [31:0] exmem_store_data;
  logic [2:0]  exmem_f3;

  always_ff @(posedge clk) begin
    if (rst) begin
      exmem_valid <= 0; exmem_reg_write <= 0; exmem_mem_read <= 0; exmem_mem_write <= 0;
      exmem_rd <= 0;
    end else begin
      exmem_valid      <= idex_valid;
      exmem_result     <= ex_result;
      exmem_store_data <= fwd_b;
      exmem_rd         <= idex_rd;
      exmem_f3         <= idex_f3;
      exmem_reg_write  <= idex_reg_write;
      exmem_mem_read   <= idex_mem_read;
      exmem_mem_write  <= idex_mem_write;
    end
  end

  // ==================================================================
  // MEM stage
  // ==================================================================
  wire [1:0] byte_off = exmem_result[1:0];

  assign dmem_addr = exmem_result;
  assign dmem_re   = exmem_valid && exmem_mem_read;

  // Store: replicate data across lanes, pick byte strobes
  logic [3:0] strb;
  always_comb begin
    case (exmem_f3[1:0])
      2'b00:   begin dmem_wdata = {4{exmem_store_data[7:0]}};  strb = 4'b0001 << byte_off; end
      2'b01:   begin dmem_wdata = {2{exmem_store_data[15:0]}}; strb = byte_off[1] ? 4'b1100 : 4'b0011; end
      default: begin dmem_wdata = exmem_store_data;            strb = 4'b1111; end
    endcase
  end
  assign dmem_wstrb = (exmem_valid && exmem_mem_write) ? strb : 4'b0000;

  // Load: shift the addressed byte/half down and sign/zero extend
  wire [31:0] shifted = dmem_rdata >> {byte_off, 3'b000};
  logic [31:0] load_data;
  always_comb begin
    case (exmem_f3)
      3'b000:  load_data = {{24{shifted[7]}},  shifted[7:0]};    // LB
      3'b001:  load_data = {{16{shifted[15]}}, shifted[15:0]};   // LH
      3'b100:  load_data = {24'b0, shifted[7:0]};                // LBU
      3'b101:  load_data = {16'b0, shifted[15:0]};               // LHU
      default: load_data = dmem_rdata;                           // LW
    endcase
  end

  // MEM/WB pipeline register
  logic memwb_valid;
  always_ff @(posedge clk) begin
    if (rst) begin
      memwb_valid <= 0; memwb_reg_write <= 0; memwb_rd <= 0;
    end else begin
      memwb_valid     <= exmem_valid;
      memwb_wdata     <= exmem_mem_read ? load_data : exmem_result;
      memwb_rd        <= exmem_rd;
      memwb_reg_write <= exmem_reg_write;
    end
  end

  // ==================================================================
  // WB stage
  // ==================================================================
  assign wb_we    = memwb_valid && memwb_reg_write;
  assign wb_rd    = memwb_rd;
  assign wb_wdata = memwb_wdata;

  // ==================================================================
  // Performance counters
  // ==================================================================
  always_ff @(posedge clk) begin
    if (rst) begin
      perf_cycles <= 0; perf_instret <= 0; perf_branches <= 0;
      perf_mispredicts <= 0; perf_stalls <= 0;
    end else begin
      perf_cycles      <= perf_cycles + 1;
      if (memwb_valid)                          perf_instret     <= perf_instret + 1;
      if (idex_valid && idex_is_branch)         perf_branches    <= perf_branches + 1;
      if (ex_mispredict)                        perf_mispredicts <= perf_mispredicts + 1;
      if (stall)                                perf_stalls      <= perf_stalls + 1;
    end
  end
endmodule

# basic.s - self-checking test of forwarding, load-use, memory ops, branches,
# JAL/JALR and the M extension.
#   x20 = MMIO base (0x10000000), x30 = current test id, x31 = expected value
#   `chk rs, expected, id` jumps to `fail` if rs != expected.
_start:
    lui   x20, 0x10000

# ---- 1. back-to-back ALU forwarding (EX/MEM and MEM/WB paths) ----------
    addi  x1, x0, 5
    addi  x2, x1, 3            # needs x1 from EX/MEM           -> 8
    add   x3, x2, x1           # x2 from EX/MEM, x1 from MEM/WB -> 13
    chk   x3, 13, 1

# ---- 2. load-use hazard (1 stall) ---------------------------------------
    addi  x5, x0, 123
    sw    x5, 16(x0)
    lw    x6, 16(x0)
    addi  x7, x6, 1            # consumes load result immediately
    chk   x7, 124, 2

# ---- 3. store-data forwarding ------------------------------------------
    addi  x8, x0, 77
    sw    x8, 20(x0)           # x8 forwarded into the store
    lw    x9, 20(x0)
    chk   x9, 77, 3

# ---- 4. byte / halfword loads and stores --------------------------------
    li    x5, 0x80FF7F01
    sw    x5, 24(x0)
    lb    x6, 24(x0)
    chk   x6, 1, 4
    lb    x6, 25(x0)
    chk   x6, 127, 5
    lb    x6, 26(x0)           # 0xFF sign-extended
    chk   x6, -1, 6
    lbu   x6, 26(x0)
    chk   x6, 255, 7
    lh    x6, 26(x0)           # 0x80FF sign-extended
    chk   x6, 0xFFFF80FF, 8
    lhu   x6, 26(x0)
    chk   x6, 0x80FF, 9
    lh    x6, 24(x0)
    chk   x6, 0x7F01, 10
    addi  x7, x0, 0xAB
    sb    x7, 25(x0)
    lw    x6, 24(x0)
    chk   x6, 0x80FFAB01, 11
    addi  x7, x0, 0x234
    sh    x7, 26(x0)
    lw    x6, 24(x0)
    chk   x6, 0x0234AB01, 12

# ---- 5. loop: sum 1..10 (branch predictor warms up) ---------------------
    addi  x5, x0, 0
    addi  x6, x0, 1
    addi  x7, x0, 11
loop:
    add   x5, x5, x6
    addi  x6, x6, 1
    bne   x6, x7, loop
    chk   x5, 55, 13

# ---- 6. every branch type, taken and not taken --------------------------
    addi  x30, x0, 14
    addi  x5, x0, -1
    addi  x6, x0, 1
    blt   x5, x6, b1           # signed: -1 < 1  -> taken
    j     fail                 # wrong-path instruction, must be flushed
b1: bltu  x5, x6, fail         # unsigned: 0xFFFFFFFF < 1 -> not taken
    bge   x5, x6, fail         # signed: -1 >= 1 -> not taken
    bgeu  x5, x6, b2           # unsigned -> taken
    j     fail
b2: beq   x5, x6, fail         # not taken
    bne   x5, x6, b3           # taken
    j     fail
b3:

# ---- 7. JAL / JALR (call + return, link-register forwarding) ------------
    addi  x30, x0, 15
    addi  x5, x0, 0
    jal   x1, sub1
    addi  x5, x5, 100          # runs after return
    chk   x5, 142, 15
    j     t8
sub1:
    addi  x5, x5, 42
    jalr  x0, x1, 0            # ret
t8:

# ---- 8. RV32M, including the spec's corner cases -----------------------
    li    x5, 7
    li    x6, -3
    mul   x7, x5, x6
    chk   x7, -21, 16
    div   x7, x5, x6           # 7 / -3 = -2 (round toward zero)
    chk   x7, -2, 17
    rem   x7, x5, x6           # 7 - (-2 * -3) = 1
    chk   x7, 1, 18
    li    x5, 100
    li    x6, 7
    divu  x7, x5, x6
    chk   x7, 14, 19
    remu  x7, x5, x6
    chk   x7, 2, 20
    li    x5, 0x40000000
    li    x6, 4
    mulh  x7, x5, x6           # (2^30 * 4) >> 32 = 1
    chk   x7, 1, 21
    li    x5, -1
    li    x6, -1
    mulhu x7, x5, x6           # (2^32-1)^2 >> 32 = 0xFFFFFFFE
    chk   x7, 0xFFFFFFFE, 22
    mulhsu x7, x5, x6          # -1 * (2^32-1) >> 32 = -1
    chk   x7, -1, 23
    li    x5, 5
    div   x7, x5, x0           # divide by zero -> -1
    chk   x7, -1, 24
    rem   x7, x5, x0           # remainder by zero -> dividend
    chk   x7, 5, 25
    divu  x7, x5, x0
    chk   x7, 0xFFFFFFFF, 26
    li    x5, 0x80000000
    li    x6, -1
    div   x7, x5, x6           # overflow -> dividend
    chk   x7, 0x80000000, 27
    rem   x7, x5, x6           # overflow -> 0
    chk   x7, 0, 28

# ---- 9. shifts, LUI/AUIPC -----------------------------------------------
    li    x5, 0x80000010
    srai  x6, x5, 4
    chk   x6, 0xF8000001, 29
    srli  x6, x5, 4
    chk   x6, 0x08000001, 30
    slli  x6, x5, 1
    chk   x6, 0x20, 31
    auipc x6, 1                # x6 = pc + 0x1000
    auipc x7, 0                # x7 = (pc + 4)
    sub   x6, x6, x7           # 0x1000 - 4 = 0xFFC
    chk   x6, 0xFFC, 32

# ---- done ---------------------------------------------------------------
    addi  x5, x0, 80           # 'P'
    sb    x5, 0(x20)
    addi  x5, x0, 65           # 'A'
    sb    x5, 0(x20)
    addi  x5, x0, 83           # 'S'
    sb    x5, 0(x20)
    sb    x5, 0(x20)           # 'S'
    addi  x5, x0, 10           # '\n'
    sb    x5, 0(x20)
    sw    x0, 4(x20)           # HALT, code 0 = pass
done:
    j     done

fail:
    sw    x30, 4(x20)          # HALT with failing test id
hang:
    j     hang

# sort.s - branch-heavy workload: LCG fill, bubble sort, verify, fibonacci.
# Good for comparing predictor on/off (make bp_compare).
_start:
    lui   x20, 0x10000
    addi  x9, x0, 256          # array base (in data RAM)
    addi  x5, x0, 1            # LCG seed
    addi  x6, x0, 0            # i
    addi  x7, x0, 16           # N
    addi  x8, x0, 0            # checksum of input
    addi  x11, x0, 73
init:
    mul   x5, x5, x11
    addi  x5, x5, 41
    andi  x5, x5, 255
    slli  x12, x6, 2
    add   x12, x12, x9
    sw    x5, 0(x12)
    add   x8, x8, x5
    addi  x6, x6, 1
    blt   x6, x7, init

# ---- bubble sort ---------------------------------------------------------
    addi  x13, x0, 0           # outer i
outer:
    addi  x14, x0, 0           # inner j
    sub   x15, x7, x13
    addi  x15, x15, -1         # limit = N-1-i
inner:
    slli  x12, x14, 2
    add   x12, x12, x9
    lw    x16, 0(x12)          # a[j]
    lw    x17, 4(x12)          # a[j+1]   (load-use with the bge below)
    bge   x17, x16, noswap
    sw    x17, 0(x12)
    sw    x16, 4(x12)
noswap:
    addi  x14, x14, 1
    blt   x14, x15, inner
    addi  x13, x13, 1
    addi  x18, x7, -1
    blt   x13, x18, outer

# ---- verify sortedness and checksum --------------------------------------
    addi  x30, x0, 1
    addi  x14, x0, 0
    addi  x19, x0, 0
    addi  x15, x7, -1
ver:
    slli  x12, x14, 2
    add   x12, x12, x9
    lw    x16, 0(x12)
    lw    x17, 4(x12)
    add   x19, x19, x16
    blt   x17, x16, fail       # out of order
    addi  x14, x14, 1
    blt   x14, x15, ver
    add   x19, x19, x17        # last element
    addi  x30, x0, 2
    bne   x19, x8, fail        # checksum must be unchanged

# ---- fibonacci(20) = 6765 -------------------------------------------------
    addi  x5, x0, 0
    addi  x6, x0, 1
    addi  x7, x0, 20
fib:
    add   x8, x5, x6
    mv    x5, x6
    mv    x6, x8
    addi  x7, x7, -1
    bnez  x7, fib
    chk   x5, 6765, 3

    addi  x5, x0, 80
    sb    x5, 0(x20)
    addi  x5, x0, 65
    sb    x5, 0(x20)
    addi  x5, x0, 83
    sb    x5, 0(x20)
    sb    x5, 0(x20)
    addi  x5, x0, 10
    sb    x5, 0(x20)
    sw    x0, 4(x20)
done:
    j     done

fail:
    sw    x30, 4(x20)
hang:
    j     hang

# 5-Stage Pipelined RISC-V (RV32IM) Core

A small, readable SystemVerilog implementation of a classic 5-stage RISC-V
pipeline, built as a **learning reference**: every hazard mechanism is a few
lines you can read, break on purpose, and watch fail in simulation.

```
   IF          ID            EX              MEM           WB
 +------+   +---------+   +---------+   +----------+   +--------+
 | PC   |-->| decode  |-->| ALU/MDU |-->| load/    |-->| regfile|
 | imem |   | regfile |   | branch  |   | store    |   | write  |
 +------+   | BHT look|   | resolve |   +----------+   +--------+
    ^       +---------+   +---------+        |
    |  ID redirect (JAL / predicted-taken)   |
    +------- EX redirect (mispredict / JALR) +-- forwarding: EX/MEM, MEM/WB --> EX
```

## Quick start

```bash
sudo apt install iverilog gtkwave   # or: brew install icarus-verilog gtkwave
make test          # assemble + run both self-checking programs
make bp_compare    # branch predictor vs static not-taken on the sort workload
make wave          # writes build/sim.vcd - open in GTKWave
```

Verilator also works for the RTL; `tb/tb_core.sv` is written for Icarus, so for
Verilator you'd port the testbench to C++ (a good exercise).

## What is implemented

| Feature | Where | Notes |
|---|---|---|
| RV32I (except FENCE/ECALL/EBREAK) | `rtl/core.sv`, `rtl/alu.sv` | unknown opcodes behave as NOPs |
| RV32M | `rtl/mdu.sv` | combinational; spec corner cases (div-by-0, overflow) handled |
| ALU forwarding | `core.sv` EX stage | EX/MEM and MEM/WB -> EX, youngest producer wins |
| Regfile write-through | `rtl/regfile.sv` | covers the WB -> ID case |
| Load-use stall | `core.sv` `stall` | 1 bubble; also covers store-data and branch operands |
| Branch prediction | `rtl/branch_predictor.sv` | 64-entry bimodal, 2-bit counters, looked up in ID |
| Control hazards | `core.sv` | JAL / predicted-taken: 1-cycle penalty. Mispredict / JALR: 2 cycles |
| Byte/half loads & stores | `core.sv` MEM stage | lane replicate + byte strobes; sign/zero extension |
| Perf counters | `core.sv` | cycles, instret, stalls, branches, mispredicts |
| Tiny SoC | `rtl/soc_top.sv` | 4 KiB ROM, 4 KiB RAM, UART TX @ `0x1000_0000`, HALT @ `0x1000_0004` |

## Verifying it

`sw/tests/basic.s` is a self-checking program covering: back-to-back forwarding,
load-use, store-data forwarding, LB/LH/LBU/LHU/SB/SH, all six branch types
(taken and not taken, with wrong-path instructions that must be flushed),
JAL/JALR, every M-extension instruction incl. corner cases, shifts, AUIPC.
`sw/tests/sort.s` runs an LCG fill, bubble sort, checksum verify and Fibonacci.

The bundled assembler (`sw/asm.py`) needs no RISC-V toolchain. The `chk rs, imm, id`
pseudo-instruction branches to `fail` if `rs != imm`; the failing test id
becomes the simulation's exit code.

**Do the tests actually catch bugs?** Mutation-testing the RTL says yes. Each of
these single-line breakages is detected (try them yourself):
- removing the load-use stall
- removing MEM/WB forwarding
- not flushing on mispredict
- making BLT compare unsigned

### Measured on this repo (Icarus Verilog, these exact programs)

| Workload | Cycles | Instr | CPI | Branch accuracy |
|---|---|---|---|---|
| basic | 246 | 217 | 1.134 | 87.2% |
| sort, 2-bit predictor | 1902 | 1464 | 1.299 | 79.3% |
| sort, static not-taken | 2022 | 1464 | 1.381 | 32.8% |

These are simulation numbers for tiny programs, not benchmarks; re-run and
report your own if you change the design.

## Gotchas worth understanding (I hit the first one while writing this)

1. **Signed division inside `?:`**. If any operand of a `?:` chain is unsigned,
   the whole expression is evaluated unsigned, silently turning `7 / -3`
   into an unsigned divide. Fix: compute signed results in their own
   `signed` wires (see `rtl/mdu.sv`).
2. **Bubbles must clear control bits**, not just a valid flag, or a flushed
   instruction can still write a register or memory.
3. **Flush priority**: EX redirect beats ID redirect beats stall. A stalled
   instruction must not redirect the PC (`id_redirect` is gated by `!stall`).
4. **Forwarding from a load in EX/MEM is wrong** (data isn't ready) - that's
   exactly why the load-use stall exists.

## Exercises / extension ideas

Beginner
- Add a `make wave` session and trace one forwarded instruction by hand.
- Turn off each hazard mechanism in turn (`NO_BP` macro exists) and see which test fails.
- Add `ECALL`/`EBREAK` that halt the simulation.

Intermediate
- Add a BTB so predicted-taken branches redirect from IF (0-cycle penalty).
- Replace the combinational MDU with a multi-cycle divider and stall the pipeline.
- Try gshare (XOR global history into the BHT index) and compare on `sort.s`.
- Make data memory synchronous-read (like FPGA block RAM) and fix the pipeline.
- Port the testbench to Verilator + C++ and write a cycle-accurate ISS for lockstep checking.
- Add the riscv-tests / riscv-arch-test suites (needs a RISC-V GCC toolchain).

Advanced
- **Custom instruction / accelerator**: add a custom-0 opcode and a functional
  unit, e.g. a sparsity-aware MAC (skip zero operands, count skips in a CSR),
  then write a small int8 dot-product kernel and measure cycles with and
  without it. This is the natural bridge to ML-accelerator work.
- Add CSRs (`mcycle`, `minstret`), traps, and a machine-mode timer.
- Add I/D caches (direct-mapped first) with a simple AXI4-Lite or valid/ready backing interface.
- Synthesis flow: run Yosys, then OpenROAD with the SkyWater 130 nm PDK (ORFS has
  ready-made configs), or implement on an FPGA board. Report *your own* timing
  and area numbers.

## Layout

```
rtl/   rv_defs.vh  regfile.sv  alu.sv  mdu.sv  branch_predictor.sv  core.sv  soc_top.sv
tb/    tb_core.sv
sw/    asm.py  tests/{basic,sort}.s
Makefile
```

Note: Icarus prints "constant selects in always_* processes" notices; they are
harmless. The RTL is written to be synthesizable apart from the behavioural MDU
(`/` and `%` are not timing-friendly) and the `$readmemh`/`initial` blocks.

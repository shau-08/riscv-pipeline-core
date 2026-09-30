#!/usr/bin/env python3
"""Tiny two-pass RV32IM assembler for the test programs in this repo.

Supports: all RV32I user-level integer instructions except fence/ecall/ebreak,
the RV32M extension, labels, ABI register names, and the pseudo-instructions
  nop  mv  li  j  ret  beqz  bnez  chk
`chk rs, imm, id` is a test helper: it sets x30=id, x31=imm and branches to the
label `fail` if rs != imm.

Usage: asm.py prog.s -o prog.hex [-l]     (-l prints a listing)
"""
import argparse
import re
import sys

ABI = (["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1"]
       + [f"a{i}" for i in range(8)] + [f"s{i}" for i in range(2, 12)]
       + [f"t{i}" for i in range(3, 7)])
REGS = {f"x{i}": i for i in range(32)}
REGS.update({n: i for i, n in enumerate(ABI)})
REGS["fp"] = 8

R_TYPE = {"add": (0, 0x00), "sub": (0, 0x20), "sll": (1, 0), "slt": (2, 0),
          "sltu": (3, 0), "xor": (4, 0), "srl": (5, 0), "sra": (5, 0x20),
          "or": (6, 0), "and": (7, 0),
          "mul": (0, 1), "mulh": (1, 1), "mulhsu": (2, 1), "mulhu": (3, 1),
          "div": (4, 1), "divu": (5, 1), "rem": (6, 1), "remu": (7, 1)}
I_ALU = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SHIFT_I = {"slli": (1, 0), "srli": (5, 0), "srai": (5, 0x20)}
LOADS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
STORES = {"sb": 0, "sh": 1, "sw": 2}
BRANCH = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}


def reg(s):
    s = s.strip()
    if s not in REGS:
        raise ValueError(f"bad register '{s}'")
    return REGS[s]


def num(s):
    s = s.strip()
    if len(s) >= 3 and s[0] == "'" and s[-1] == "'":
        return ord(s[1:-1].encode().decode("unicode_escape"))
    return int(s, 0)


def expand(mn, ops):
    """Expand pseudo-instructions into real ones (size known in pass 1)."""
    if mn == "nop":
        return [("addi", ["x0", "x0", "0"])]
    if mn == "mv":
        return [("addi", [ops[0], ops[1], "0"])]
    if mn == "j":
        return [("jal", ["x0", ops[0]])]
    if mn == "ret":
        return [("jalr", ["x0", "x1", "0"])]
    if mn == "beqz":
        return [("beq", [ops[0], "x0", ops[1]])]
    if mn == "bnez":
        return [("bne", [ops[0], "x0", ops[1]])]
    if mn == "li":
        v = num(ops[1]) & 0xFFFFFFFF
        sv = v - (1 << 32) if v & 0x80000000 else v
        if -2048 <= sv < 2048:
            return [("addi", [ops[0], "x0", str(sv)])]
        lo = ((v & 0xFFF) ^ 0x800) - 0x800
        hi = ((v - lo) >> 12) & 0xFFFFF
        out = [("lui", [ops[0], str(hi)])]
        if lo:
            out.append(("addi", [ops[0], ops[0], str(lo)]))
        return out
    if mn == "chk":
        return (expand("li", ["x30", ops[2]]) + expand("li", ["x31", ops[1]])
                + [("bne", [ops[0], "x31", "fail"])])
    return [(mn, ops)]


def enc_r(op, f3, f7, rd, rs1, rs2):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_i(op, f3, rd, rs1, imm):
    if not -2048 <= imm < 2048:
        raise ValueError(f"I-imm out of range: {imm}")
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_s(op, f3, rs1, rs2, imm):
    if not -2048 <= imm < 2048:
        raise ValueError(f"S-imm out of range: {imm}")
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op


def enc_b(op, f3, rs1, rs2, off):
    if off % 2 or not -4096 <= off < 4096:
        raise ValueError(f"branch offset out of range: {off}")
    off &= 0x1FFF
    return (((off >> 12) & 1) << 31) | (((off >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) \
        | (f3 << 12) | (((off >> 1) & 0xF) << 8) | (((off >> 11) & 1) << 7) | op


def enc_u(op, rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op


def enc_j(op, rd, off):
    if off % 2 or not -(1 << 20) <= off < (1 << 20):
        raise ValueError(f"jal offset out of range: {off}")
    off &= 0x1FFFFF
    return (((off >> 20) & 1) << 31) | (((off >> 1) & 0x3FF) << 21) | (((off >> 11) & 1) << 20) \
        | (((off >> 12) & 0xFF) << 12) | (rd << 7) | op


def assemble(lines):
    labels, items = {}, []          # items: (lineno, mn, ops)
    for ln, raw in enumerate(lines, 1):
        line = re.split(r"#|//", raw)[0].strip()
        while ":" in line:
            name, line = line.split(":", 1)
            labels[name.strip()] = 4 * len(items)
            line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        mn = parts[0].lower()
        ops = [o.strip() for o in parts[1].split(",")] if len(parts) > 1 else []
        for real in expand(mn, ops):
            items.append((ln, real[0], real[1]))

    words, listing = [], []
    for idx, (ln, mn, ops) in enumerate(items):
        pc = 4 * idx

        def target(s):
            return labels[s] - pc if s in labels else num(s)
        try:
            if mn in R_TYPE:
                f3, f7 = R_TYPE[mn]
                w = enc_r(0x33, f3, f7, reg(ops[0]), reg(ops[1]), reg(ops[2]))
            elif mn in I_ALU:
                w = enc_i(0x13, I_ALU[mn], reg(ops[0]), reg(ops[1]), num(ops[2]))
            elif mn in SHIFT_I:
                f3, f7 = SHIFT_I[mn]
                sh = num(ops[2])
                assert 0 <= sh < 32
                w = enc_r(0x13, f3, f7, reg(ops[0]), reg(ops[1]), sh)
            elif mn in LOADS:
                m = re.fullmatch(r"(.*)\((.*)\)", ops[1])
                w = enc_i(0x03, LOADS[mn], reg(ops[0]), reg(m.group(2)), num(m.group(1) or "0"))
            elif mn in STORES:
                m = re.fullmatch(r"(.*)\((.*)\)", ops[1])
                w = enc_s(0x23, STORES[mn], reg(m.group(2)), reg(ops[0]), num(m.group(1) or "0"))
            elif mn in BRANCH:
                w = enc_b(0x63, BRANCH[mn], reg(ops[0]), reg(ops[1]), target(ops[2]))
            elif mn == "lui":
                w = enc_u(0x37, reg(ops[0]), num(ops[1]))
            elif mn == "auipc":
                w = enc_u(0x17, reg(ops[0]), num(ops[1]))
            elif mn == "jal":
                w = enc_j(0x6F, reg(ops[0]), target(ops[1]))
            elif mn == "jalr":
                w = enc_i(0x67, 0, reg(ops[0]), reg(ops[1]), num(ops[2]))
            else:
                raise ValueError(f"unknown mnemonic '{mn}'")
        except (ValueError, KeyError, AssertionError, AttributeError) as e:
            sys.exit(f"line {ln}: {mn} {', '.join(ops)}: {e}")
        words.append(w)
        listing.append(f"{pc:04x}: {w:08x}   {mn} {', '.join(ops)}")
    return words, listing


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("-l", "--listing", action="store_true")
    ap.add_argument("--depth", type=int, default=1024)
    a = ap.parse_args()
    words, listing = assemble(open(a.src).read().splitlines())
    if len(words) > a.depth:
        sys.exit(f"program too large: {len(words)} > {a.depth} words")
    words += [0x00000013] * (a.depth - len(words))        # pad with NOPs
    with open(a.out, "w") as f:
        f.write("\n".join(f"{w:08x}" for w in words) + "\n")
    if a.listing:
        print("\n".join(listing))


if __name__ == "__main__":
    main()

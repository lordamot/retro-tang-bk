#!/usr/bin/env python3
"""pdp11dis.py - a small PDP-11 disassembler for reading the AZ's ROMs.

  tools/pdp11dis.py FILE [BASE] [START] [COUNT]

FILE is a raw binary, BASE its load address (octal, default 170000),
START the first address to show (octal, default BASE) and COUNT the
number of instructions (default 64).  Covers the К1801ВМ1's set (no
FPU, no EIS beyond what the BK has), enough to follow a ROM.
"""
import sys

REG = ['R0', 'R1', 'R2', 'R3', 'R4', 'R5', 'SP', 'PC']

BR = {0o0004: 'BR', 0o0010: 'BNE', 0o0014: 'BEQ', 0o0020: 'BGE', 0o0024: 'BLT',
      0o0030: 'BGT', 0o0034: 'BLE', 0o1000: 'BPL', 0o1004: 'BMI', 0o1010: 'BHI',
      0o1014: 'BLOS', 0o1020: 'BVC', 0o1024: 'BVS', 0o1030: 'BCC', 0o1034: 'BCS'}
ONE = {0o0050: 'CLR', 0o0051: 'COM', 0o0052: 'INC', 0o0053: 'DEC', 0o0054: 'NEG',
       0o0055: 'ADC', 0o0056: 'SBC', 0o0057: 'TST', 0o0060: 'ROR', 0o0061: 'ROL',
       0o0062: 'ASR', 0o0063: 'ASL', 0o0064: 'MARK', 0o0065: 'MFPI', 0o0066: 'MTPI',
       0o0067: 'SXT', 0o1050: 'CLRB', 0o1051: 'COMB', 0o1052: 'INCB', 0o1053: 'DECB',
       0o1054: 'NEGB', 0o1055: 'ADCB', 0o1056: 'SBCB', 0o1057: 'TSTB', 0o1060: 'RORB',
       0o1061: 'ROLB', 0o1062: 'ASRB', 0o1063: 'ASLB', 0o1064: 'MTPS', 0o1067: 'MFPS',
       0o0003: 'SWAB', 0o0001: 'JMP'}
TWO = {0o01: 'MOV', 0o02: 'CMP', 0o03: 'BIT', 0o04: 'BIC', 0o05: 'BIS', 0o06: 'ADD',
       0o11: 'MOVB', 0o12: 'CMPB', 0o13: 'BITB', 0o14: 'BICB', 0o15: 'BISB', 0o16: 'SUB'}
ZERO = {0o000000: 'HALT', 0o000001: 'WAIT', 0o000002: 'RTI', 0o000003: 'BPT',
        0o000004: 'IOT', 0o000005: 'RESET', 0o000006: 'RTT', 0o000240: 'NOP',
        0o000257: 'CCC', 0o000277: 'SCC', 0o000241: 'CLC', 0o000242: 'CLV',
        0o000244: 'CLZ', 0o000250: 'CLN', 0o000261: 'SEC', 0o000262: 'SEV',
        0o000264: 'SEZ', 0o000270: 'SEN'}


def operand(mode, reg, words, pc):
    """returns (text, words consumed)"""
    r = REG[reg]
    if mode == 0: return r, 0
    if mode == 1: return '(%s)' % r, 0
    if mode == 2:
        if reg == 7: return '#%o' % words[0], 1
        return '(%s)+' % r, 0
    if mode == 3:
        if reg == 7: return '@#%o' % words[0], 1
        return '@(%s)+' % r, 0
    if mode == 4: return '-(%s)' % r, 0
    if mode == 5: return '@-(%s)' % r, 0
    if mode == 6:
        if reg == 7: return '%o' % ((pc + 2 + words[0]) & 0xffff), 1
        return '%o(%s)' % (words[0], r), 1
    if mode == 7:
        if reg == 7: return '@%o' % ((pc + 2 + words[0]) & 0xffff), 1
        return '@%o(%s)' % (words[0], r), 1


def dis(mem, addr):
    """one instruction at addr: (text, length in words)"""
    w = mem(addr)
    if w in ZERO: return ZERO[w], 1
    op = w >> 12
    if (w & 0o170000) in (0o170000,):
        return '.WORD %o' % w, 1
    if (w >> 9) in TWO or ((w >> 12) & 7) in TWO and (w >> 12) != 0:
        opc = (w >> 12) & 0o17
        if opc in TWO:
            sm, sr, dm, dr = (w >> 9) & 7, (w >> 6) & 7, (w >> 3) & 7, w & 7
            n = 1
            s, k = operand(sm, sr, [mem(addr + 2)], addr + 2 * n)
            n += k
            d, k = operand(dm, dr, [mem(addr + 2 * n)], addr + 2 * n)
            n += k
            return '%s %s,%s' % (TWO[opc], s, d), n
    hi = w >> 6
    if hi in BR:
        off = w & 0xff
        if off >= 128: off -= 256
        return '%s %o' % (BR[hi], (addr + 2 + 2 * off) & 0xffff), 1
    if hi == 0o0004 or (w & 0o177000) == 0o004000:
        d, k = operand((w >> 3) & 7, w & 7, [mem(addr + 2)], addr + 2)
        return 'JSR %s,%s' % (REG[(w >> 6) & 7], d), 1 + k
    if (w & 0o177770) == 0o000200: return 'RTS %s' % REG[w & 7], 1
    if (w & 0o177000) == 0o077000:
        return 'SOB %s,%o' % (REG[(w >> 6) & 7], (addr + 2 - 2 * (w & 0o77)) & 0xffff), 1
    if (w & 0o177400) == 0o104000: return 'EMT %o' % (w & 0o377), 1
    if (w & 0o177400) == 0o104400: return 'TRAP %o' % (w & 0o377), 1
    if (w & 0o177000) == 0o070000:
        d, k = operand((w >> 3) & 7, w & 7, [mem(addr + 2)], addr + 2)
        return 'MUL %s,%s' % (d, REG[(w >> 6) & 7]), 1 + k
    if (w & 0o177000) == 0o071000:
        d, k = operand((w >> 3) & 7, w & 7, [mem(addr + 2)], addr + 2)
        return 'DIV %s,%s' % (d, REG[(w >> 6) & 7]), 1 + k
    if (w & 0o177000) == 0o072000:
        d, k = operand((w >> 3) & 7, w & 7, [mem(addr + 2)], addr + 2)
        return 'ASH %s,%s' % (d, REG[(w >> 6) & 7]), 1 + k
    if (w & 0o177000) == 0o073000:
        d, k = operand((w >> 3) & 7, w & 7, [mem(addr + 2)], addr + 2)
        return 'ASHC %s,%s' % (d, REG[(w >> 6) & 7]), 1 + k
    if (w & 0o177000) == 0o074000:
        d, k = operand((w >> 3) & 7, w & 7, [mem(addr + 2)], addr + 2)
        return 'XOR %s,%s' % (REG[(w >> 6) & 7], d), 1 + k
    if hi in ONE:
        d, k = operand((w >> 3) & 7, w & 7, [mem(addr + 2)], addr + 2)
        return '%s %s' % (ONE[hi], d), 1 + k
    return '.WORD %o' % w, 1


def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    data = open(sys.argv[1], 'rb').read()
    base = int(sys.argv[2], 8) if len(sys.argv) > 2 else 0o170000
    start = int(sys.argv[3], 8) if len(sys.argv) > 3 else base
    count = int(sys.argv[4]) if len(sys.argv) > 4 else 64

    def mem(a):
        o = a - base
        if o < 0 or o + 1 >= len(data): return 0
        return data[o] | (data[o + 1] << 8)

    a = start
    for _ in range(count):
        if a - base >= len(data): break
        text, n = dis(mem, a)
        words = ' '.join('%06o' % mem(a + 2 * i) for i in range(n))
        print('%06o: %-22s %s' % (a, words, text))
        a += 2 * n


if __name__ == '__main__':
    main()

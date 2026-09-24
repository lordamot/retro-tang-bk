#!/usr/bin/env python3
"""binlink.py - MACRO-11 object file -> a headerless ANDOS program.

    binlink.py IN.obj OUT.bin [--base 1000]

ANDOS keeps a program's load address in its directory entry (tools/
andosput.py writes it there) and starts the program at that address, so
the file is the bytes from the base up, nothing else.  One absolute
module: the TXT records are laid into an image, the RLD records applied
(macro11 leaves every PC-relative operand as the target address plus a
"displaced internal relocation" entry, so a copy of the TXT records
alone makes `MOV VAR,R1` fetch from the wrong place), and the transfer
address .END names must be the base, because that is where ANDOS jumps.
Adapted from UKNC Nano's tools/savlink.py, which links RT-11 .SAVs the
same way; globals, libraries and a second section are errors here too.
"""

import argparse
import struct

T_GSD, T_ENDGSD, T_TXT, T_RLD, T_ISD, T_ENDMOD = 1, 2, 3, 4, 5, 6
RLD_SIZE = {1: 4, 2: 6, 3: 4, 4: 6, 5: 8, 6: 8, 7: 8, 8: 4, 9: 4,
            0o10: 6, 0o12: 2, 0o13: 6, 0o14: 8, 0o15: 8}


def records(blob):
    i, n = 0, len(blob)
    while i < n:
        while i < n and blob[i] == 0:
            i += 1
        if i >= n:
            return
        if blob[i] != 1 or blob[i + 1] != 0:
            raise SystemExit(f"bad record framing at {i}")
        length = blob[i + 2] | blob[i + 3] << 8
        yield blob[i + 4], bytes(blob[i + 6:i + length])
        i += length + 1


def link(obj, out, base):
    blob = open(obj, "rb").read()
    mem = bytearray(base)
    transfer = None
    high = 0
    txt_addr = None
    for t, p in records(blob):
        if t == T_GSD:
            for j in range(0, len(p) - 7, 8):
                if p[j + 5] == 3:                       # transfer address
                    transfer = p[j + 6] | p[j + 7] << 8
        elif t == T_TXT and len(p) > 2:
            addr = p[0] | p[1] << 8
            data = p[2:]
            if addr < base:
                raise SystemExit(f"{obj}: text below {base:o} at {addr:o}")
            end = addr + len(data)
            if end > len(mem):
                mem.extend(b"\0" * (end - len(mem)))
            mem[addr:end] = data
            high = max(high, end)
            txt_addr = addr
        elif t == T_RLD:
            j = 0
            while j < len(p):
                et = p[j] & 0o177
                byte_mode = p[j] & 0o200
                if et in (1, 3):
                    at = txt_addr + p[j + 1] - 4
                    value = p[j + 2] | p[j + 3] << 8
                    if et == 3:
                        value = (value - (at + 2)) & 0xFFFF
                    if byte_mode:
                        mem[at] = value & 0xFF
                    else:
                        struct.pack_into("<H", mem, at, value)
                elif et in (7, 8, 9, 0o12):
                    pass                                  # location counter, limits
                else:
                    raise SystemExit(f"{obj}: RLD entry type {et} (a global or a "
                                     f"relocatable section) - not a single .ASECT")
                j += RLD_SIZE.get(et, 4)
        elif t == T_ENDMOD:
            break
    if transfer is None:
        raise SystemExit(f"{obj}: no transfer address (.END START)")
    if transfer != base:
        raise SystemExit(f"{obj}: transfer address {transfer:o} is not the base "
                         f"{base:o} - ANDOS starts a program where it loads it")
    open(out, "wb").write(mem[base:high])
    print(f"{out}: {high - base} bytes at {base:o}, high {high - 1:o}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("obj")
    ap.add_argument("out")
    ap.add_argument("--base", type=lambda s: int(s, 8), default=0o1000,
                    help="load address, octal (default 1000)")
    a = ap.parse_args()
    link(a.obj, a.out, a.base)


if __name__ == "__main__":
    main()

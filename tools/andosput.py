#!/usr/bin/env python3
"""andosput.py - put files onto an ANDOS disk image.

    andosput.py IMAGE.IMG [--base BASE.IMG] [NAME=]FILE[@ADDR] ...
    andosput.py IMAGE.IMG --list

An ANDOS disk is a FAT12 volume (800 KB: 512-byte sectors, 4 a cluster,
two FATs of two sectors, 112 root entries), and the only ANDOS thing
about it is that a program's load address lives in the directory entry's
time field (bytes 22-23), where DOS keeps the modification time: DAVE and
AY_TEST both carry 1000 there, ANDOS.SYS 177777.  Typing the name at the
A> line loads the file at that address and jumps to it.  So a file goes
in with its name (NAME=, or the file's own) uppercased to 8.3 - a BK
program carries no extension: DAVE, AY_TEST - the load address ADDR
(octal, default 1000) in that field, a chain of clusters from the FAT and both
FAT copies updated; a file of the same name is replaced.  --base copies
the base image first (WRKANDOS2.IMG, the AZBK package's ANDOS, boots).
The root directory only, no subdirectories: that is all the tests need.
"""

import argparse
import os
import struct
import sys


class Fat12:
    def __init__(self, data):
        self.d = bytearray(data)
        (self.bps, self.spc, self.rsv, self.nf, self.nroot, self.tot, _,
         self.spf) = struct.unpack_from("<HBHBHHBH", self.d, 11)
        if self.bps != 512 or self.nf not in (1, 2):
            raise SystemExit("not a FAT12 floppy image")
        self.fat = self.rsv * self.bps
        self.root = (self.rsv + self.nf * self.spf) * self.bps
        self.data = self.root + self.nroot * 32
        self.nclus = (self.tot * self.bps - self.data) // (self.spc * self.bps)

    def get(self, c):
        o = self.fat + c * 3 // 2
        v = struct.unpack_from("<H", self.d, o)[0]
        return (v >> 4) if c & 1 else (v & 0xFFF)

    def set(self, c, v):
        for f in range(self.nf):
            o = self.fat + f * self.spf * self.bps + c * 3 // 2
            w = struct.unpack_from("<H", self.d, o)[0]
            w = (w & 0x000F) | (v << 4) if c & 1 else (w & 0xF000) | (v & 0xFFF)
            struct.pack_into("<H", self.d, o, w)

    def entries(self):
        for i in range(self.nroot):
            o = self.root + 32 * i
            e = self.d[o:o + 32]
            if e[0] == 0:
                return
            yield o, e

    def free_entry(self):
        for i in range(self.nroot):
            o = self.root + 32 * i
            if self.d[o] in (0, 0xE5):
                return o
        raise SystemExit("root directory full")

    def free_chain(self, c):
        while 2 <= c < 0xFF8:
            n = self.get(c)
            self.set(c, 0)
            c = n

    def alloc(self, n):
        free = [c for c in range(2, 2 + self.nclus) if self.get(c) == 0]
        if len(free) < n:
            raise SystemExit(f"disk full: {n} clusters wanted, {len(free)} free")
        return free[:n]

    def put(self, path, addr, name=None):
        name = (name or os.path.basename(path)).upper()
        stem, _, ext = name.partition(".")
        if len(stem) > 8 or len(ext) > 3 or not stem:
            raise SystemExit(f"{name}: not an 8.3 name")
        key = stem.ljust(8).encode() + ext.ljust(3).encode()
        blob = open(path, "rb").read()
        # replace a file of the same name
        slot = None
        for o, e in self.entries():
            if e[:11] == key and e[0] != 0xE5 and not e[11] & 0x08:
                self.free_chain(struct.unpack_from("<H", e, 26)[0])
                slot = o
                break
        if slot is None:
            slot = self.free_entry()
        csize = self.spc * self.bps
        n = (len(blob) + csize - 1) // csize
        chain = self.alloc(n) if n else []
        for i, c in enumerate(chain):
            self.set(c, chain[i + 1] if i + 1 < n else 0xFFF)
            o = self.data + (c - 2) * csize
            piece = blob[i * csize:(i + 1) * csize]
            self.d[o:o + csize] = piece + b"\0" * (csize - len(piece))
        e = bytearray(32)
        e[:11] = key
        e[11] = 0x00
        struct.pack_into("<H", e, 22, addr)                   # ANDOS: the load address
        struct.pack_into("<H", e, 24, (46 << 9) | (9 << 5) | 24)   # 24 Sep 2026
        struct.pack_into("<H", e, 26, chain[0] if chain else 0)
        struct.pack_into("<I", e, 28, len(blob))
        self.d[slot:slot + 32] = e
        print(f"{name:12s} {len(blob):6d} bytes at {addr:o}, {n} clusters")

    def list(self):
        for o, e in self.entries():
            if e[0] == 0xE5 or e[11] & 0x08:
                continue
            name = e[:8].decode("cp866", "replace").rstrip()
            ext = e[8:11].decode("cp866", "replace").rstrip()
            addr, clu, size = struct.unpack_from("<HxxHI", e, 22)
            print(f"{name + ('.' + ext if ext else ''):13s} {size:7d}  load {addr:06o}  cluster {clu}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("image")
    ap.add_argument("files", nargs="*", help="[NAME=]FILE[@ADDR] (ADDR octal)")
    ap.add_argument("--base", help="copy this image first")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    src = a.base if a.base else a.image
    fs = Fat12(open(src, "rb").read())
    if a.list:
        fs.list()
        return
    for f in a.files:
        name, eq, rest = f.partition("=")
        if not eq:
            name, rest = None, f
        path, _, addr = rest.partition("@")
        fs.put(path, int(addr, 8) if addr else 0o1000, name)
    open(a.image, "wb").write(fs.d)


if __name__ == "__main__":
    main()

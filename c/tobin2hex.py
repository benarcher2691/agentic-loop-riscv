#!/usr/bin/env python3
"""Pack a flat binary into little-endian 32-bit words, one 8-hex-digit word per
line, for $readmemh into a `reg [31:0]` array. Usage: tobin2hex.py in.bin out.hex"""
import sys
data = open(sys.argv[1], "rb").read()
data += b"\x00" * (-len(data) % 4)
with open(sys.argv[2], "w") as f:
    words = [int.from_bytes(data[i:i+4], "little") for i in range(0, len(data), 4)]
    words += [0] * (1536 - len(words))          # pad to the 6 KB word array
    for w in words:
        f.write("%08x\n" % w)

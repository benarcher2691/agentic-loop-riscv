#!/usr/bin/env python3
"""Pack a flat binary into little-endian 32-bit words, one 8-hex-digit word per
line, for $readmemh / monitor upload.
  tobin2hex.py in.bin out.hex [pad_words]
With pad_words, zero-fill up to that many words (for loading a whole RAM array in
sim). Without it, emit only the real program words (for uploading to 0x400)."""
import sys
data = open(sys.argv[1], "rb").read()
data += b"\x00" * (-len(data) % 4)
words = [int.from_bytes(data[i:i+4], "little") for i in range(0, len(data), 4)]
if len(sys.argv) > 3:
    words += [0] * (int(sys.argv[3]) - len(words))
with open(sys.argv[2], "w") as f:
    for w in words:
        f.write("%08x\n" % w)

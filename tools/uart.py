#!/usr/bin/env python3
"""Print whatever the iCEstick sends on its UART (FTDI channel B). Stdlib only.
Usage: python3 tools/uart.py [/dev/cu.usbserial-XXXXX] [baud]"""
import glob, os, sys, termios

ports = sorted(glob.glob("/dev/cu.usbserial-*"))
port = sys.argv[1] if len(sys.argv) > 1 else (ports[-1] if ports else None)  # channel B is the higher one
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
if not port:
    sys.exit("no /dev/cu.usbserial-* device found — is the iCEstick plugged in?")
fd = os.open(port, os.O_RDONLY | os.O_NOCTTY)
a = termios.tcgetattr(fd)
a[0] = 0                                             # iflag: raw
a[1] = 0                                             # oflag: raw
a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL  # cflag: 8N1, no flow control
a[3] = 0                                             # lflag: raw
a[4] = a[5] = getattr(termios, f"B{baud}")
a[6][termios.VMIN] = 1
a[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, a)
print(f"reading {port} @ {baud} 8N1 — Ctrl-C to stop", file=sys.stderr)
try:
    while True:
        sys.stdout.write(os.read(fd, 256).decode("ascii", "replace"))
        sys.stdout.flush()
except KeyboardInterrupt:
    pass

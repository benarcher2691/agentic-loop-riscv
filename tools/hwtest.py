#!/usr/bin/env python3
"""Hardware smoke test (human-run): flash a bitstream and expect the UART banner.

    python3 tools/hwtest.py [build/SOC.bin] [--expect 'Loop RISC-V'] [--timeout 5]

Opens the UART (FTDI channel B) *before* programming, runs `iceprog`, and passes if the
expected text arrives within the timeout. Stdlib only. Exit 0 = PASS, 1 = FAIL."""
import argparse, glob, os, subprocess, sys, termios, threading, time

p = argparse.ArgumentParser()
p.add_argument("bitstream", nargs="?", default="build/SOC.bin")
p.add_argument("--expect", default="Loop RISC-V")
p.add_argument("--timeout", type=float, default=5.0)
p.add_argument("--baud", type=int, default=115200)
a = p.parse_args()

ports = sorted(glob.glob("/dev/cu.usbserial-*"))
if not ports:
    sys.exit("FAIL: no /dev/cu.usbserial-* device — is the iCEstick plugged in?")
port = ports[-1]  # channel B = the higher-numbered port
fd = os.open(port, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
t = termios.tcgetattr(fd)
t[0] = t[1] = t[3] = 0
t[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
t[4] = t[5] = getattr(termios, f"B{a.baud}")
termios.tcsetattr(fd, termios.TCSANOW, t)
termios.tcflush(fd, termios.TCIFLUSH)

got = bytearray()
stop = False
def reader():
    while not stop:
        try:
            got.extend(os.read(fd, 256))
        except BlockingIOError:
            time.sleep(0.01)
th = threading.Thread(target=reader, daemon=True); th.start()

print(f"listening on {port}; programming {a.bitstream} ...", file=sys.stderr)
r = subprocess.run(["iceprog", a.bitstream], capture_output=True, text=True)
if r.returncode != 0 or "VERIFY OK" not in r.stdout + r.stderr:
    print(r.stdout[-400:], r.stderr[-400:], file=sys.stderr)
    sys.exit("FAIL: iceprog did not verify")

deadline = time.time() + a.timeout
while time.time() < deadline and a.expect.encode() not in got:
    time.sleep(0.05)
stop = True
text = got.decode("ascii", "replace")
if a.expect in text:
    print(f"PASS: received {text.strip()!r} within {a.timeout}s"); sys.exit(0)
print(f"FAIL: expected {a.expect!r}, got {text!r} after {a.timeout}s"); sys.exit(1)

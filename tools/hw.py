#!/usr/bin/env python3
"""Host side of the iCEstick RISC-V UART monitor (protocol V/W/R/G). Stdlib only.

The resident program is a serial monitor speaking, over FTDI channel B @115200 8N1:
  V              -> replies the 4 bytes "RV32"
  W addr len d.. -> writes len bytes to addr (RAM or IO 0x400000+), replies 'K'
  R addr len     -> replies len bytes read from addr
  G addr         -> calls addr (routine returns with ret), replies 'K'
All multi-byte values are little-endian 32-bit.

Usage:
  python3 tools/hw.py id                       # V: print the identity string
  python3 tools/hw.py check                    # run build/hwprogs-*.{prog,expect}.hex
  python3 tools/hw.py peek ADDR [N]            # R: read N words (default 1), hex
  python3 tools/hw.py poke ADDR WORD [WORD...]  # W: write words
  python3 tools/hw.py runc PROG.hex            # upload a C program to 0x400, run it, print its output
  python3 tools/hw.py runi PROG.hex            # same, but relay your keyboard <-> the program (interactive input)
  python3 tools/hw.py run ADDR                  # G: call a routine
Options: --port /dev/cu.usbserial-XXXX  --timeout 2.0
Exit 0 = OK / all HWCHECKS passed, non-zero = failure.
"""
import glob, os, re, select, sys, termios, time

class Monitor:
    def __init__(self, port=None, baud=115200, timeout=2.0):
        ports = sorted(glob.glob("/dev/cu.usbserial-*"))
        self.port = port or (ports[-1] if ports else None)   # channel B = higher-numbered
        if not self.port:
            raise SystemExit("no /dev/cu.usbserial-* device — is the iCEstick plugged in?")
        self.timeout = timeout
        self.fd = os.open(self.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        a = termios.tcgetattr(self.fd)
        a[0] = a[1] = a[3] = 0
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        a[4] = a[5] = getattr(termios, f"B{baud}")
        termios.tcsetattr(self.fd, termios.TCSANOW, a)
        termios.tcflush(self.fd, termios.TCIOFLUSH)

    def _w(self, data: bytes):
        os.write(self.fd, data)

    def _r(self, n: int) -> bytes:
        out = bytearray(); deadline = time.time() + self.timeout
        while len(out) < n:
            r, _, _ = select.select([self.fd], [], [], max(0, deadline - time.time()))
            if not r:
                raise TimeoutError(f"timeout after {self.timeout}s: got {len(out)}/{n} bytes ({bytes(out)!r})")
            out.extend(os.read(self.fd, n - len(out)))
        return bytes(out)

    @staticmethod
    def _le32(v: int) -> bytes:
        return (v & 0xFFFFFFFF).to_bytes(4, "little")

    def identify(self) -> bytes:
        termios.tcflush(self.fd, termios.TCIFLUSH)
        self._w(b"V"); return self._r(4)

    def write_bytes(self, addr: int, data: bytes):
        self._w(b"W" + self._le32(addr) + self._le32(len(data)) + data)
        k = self._r(1)
        if k != b"K": raise IOError(f"W to 0x{addr:x} not acked: {k!r}")

    def write_words(self, addr: int, words):
        self.write_bytes(addr, b"".join(self._le32(w) for w in words))

    def read_bytes(self, addr: int, n: int) -> bytes:
        self._w(b"R" + self._le32(addr) + self._le32(n)); return self._r(n)

    def read_words(self, addr: int, n: int):
        b = self.read_bytes(addr, n * 4)
        return [int.from_bytes(b[i:i+4], "little") for i in range(0, len(b), 4)]

    def run(self, addr: int):
        self._w(b"G" + self._le32(addr))
        k = self._r(1)
        if k != b"K": raise IOError(f"G 0x{addr:x} not acked: {k!r}")

    def run_interactive(self, addr: int, end=0x4B, idle_timeout=30.0):
        """G addr, then relay: your keystrokes -> the board's UART, the board's
        output -> your terminal, until the monitor's 'K' ack. Puts stdin in raw
        mode so the program's own echo is what you see."""
        import time
        self._w(b"G" + self._le32(addr))
        infd = sys.stdin.fileno()
        raw = sys.stdin.isatty()
        if raw:
            import termios, tty
            saved = termios.tcgetattr(infd); tty.setcbreak(infd)
        try:
            last = time.time()
            while time.time() - last < idle_timeout:
                r, _, _ = select.select([self.fd, infd], [], [], 0.2)
                if self.fd in r:
                    for ch in os.read(self.fd, 256):
                        if ch == end: return
                        sys.stdout.write(chr(ch)); sys.stdout.flush(); last = time.time()
                if infd in r:
                    b = os.read(infd, 16)
                    if b in (b"\x03", b"\x04"): return   # Ctrl-C / Ctrl-D
                    self._w(b.replace(b"\n", b"\r\n") if False else b); last = time.time()
            sys.stderr.write("\n[hw] idle timeout\n")
        finally:
            if raw:
                import termios
                termios.tcsetattr(infd, termios.TCSANOW, saved)

    def run_capture(self, addr: int, end=0x4B, timeout=5.0):
        """G addr, then read the program's UART output up to the monitor's 'K'
        ack. (A program whose output contains a raw 0x4B byte would end early —
        fine for text demos.) Returns the captured bytes before 'K'."""
        self._w(b"G" + self._le32(addr))
        out = bytearray(); deadline = __import__("time").time() + timeout
        while __import__("time").time() < deadline:
            r, _, _ = select.select([self.fd], [], [], max(0, deadline - __import__("time").time()))
            if not r: continue
            b = os.read(self.fd, 256)
            for ch in b:
                if ch == end:
                    return bytes(out)
                out.append(ch)
        raise TimeoutError(f"G 0x{addr:x}: no 'K' ack within {timeout}s (got {bytes(out)!r})")

MAX_HEX_BYTES = 1 << 20   # 1 MB cap — these are tiny build-generated dumps

def load_hex(path):
    """Parse a contiguous $writememh dump into a list of 32-bit words.
    Raises ValueError on anything unexpected: an unparseable token, or an
    @address directive (this loader assumes a dense dump from index 0 — a
    sparse one would silently collapse to a wrong offset, so refuse it)."""
    if os.path.getsize(path) > MAX_HEX_BYTES:
        raise ValueError(f"{path}: larger than {MAX_HEX_BYTES} bytes — refusing")
    words = []
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.split("//")[0].strip()
            for tok in line.split():
                if tok.startswith("@"):
                    raise ValueError(f"{path}:{lineno}: @address directive unsupported "
                                     "(loader assumes a dense dump from index 0)")
                if not re.fullmatch(r"[0-9a-fA-F]{1,8}", tok):
                    raise ValueError(f"{path}:{lineno}: not a hex word: {tok!r}")
                words.append(int(tok, 16))
    return words

PROG_ADDR, RESULT_ADDR = 0x400, 0x800

def cmd_check(m):
    progs = sorted(glob.glob("build/hwprogs-*.prog.hex"))
    if not progs:
        print("no build/hwprogs-*.prog.hex — run `make sim` first", file=sys.stderr); return 1
    ident = m.identify()
    if ident != b"RV32":
        print(f"FAIL: identity {ident!r} != b'RV32' (is the monitor bitstream flashed?)"); return 1
    passed = failed = 0
    for pf in progs:
        name = pf[len("build/hwprogs-"):-len(".prog.hex")]
        prog = load_hex(pf); expect = load_hex(f"build/hwprogs-{name}.expect.hex")
        try:
            m.write_words(PROG_ADDR, prog)
            m.run(PROG_ADDR)
            got = m.read_words(RESULT_ADDR, len(expect))
        except (TimeoutError, IOError) as e:
            print(f"FAIL {name}: {e}"); failed += 1; continue
        if got == expect:
            print(f"ok   {name}: {len(expect)} words"); passed += 1
        else:
            failed += 1
            diff = next((i for i in range(len(expect)) if i >= len(got) or got[i] != expect[i]), 0)
            print(f"FAIL {name}: word {diff} got 0x{(got[diff] if diff < len(got) else 0):08x} "
                  f"expected 0x{expect[diff]:08x}")
    print(f"HWCHECKS: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1

def main():
    args = sys.argv[1:]; port = None; timeout = 2.0
    while "--port" in args: i = args.index("--port"); port = args[i+1]; del args[i:i+2]
    while "--timeout" in args: i = args.index("--timeout"); timeout = float(args[i+1]); del args[i:i+2]
    if not args: print(__doc__); return 2
    m = Monitor(port=port, timeout=timeout)
    cmd = args[0]
    if cmd == "id":
        print(m.identify().decode("ascii", "replace")); return 0
    if cmd == "check":
        return cmd_check(m)
    if cmd == "peek":
        addr = int(args[1], 0); n = int(args[2], 0) if len(args) > 2 else 1
        for i, w in enumerate(m.read_words(addr, n)): print(f"0x{addr+4*i:08x}: 0x{w:08x}")
        return 0
    if cmd == "poke":
        addr = int(args[1], 0); m.write_words(addr, [int(x, 0) for x in args[2:]]); print("K"); return 0
    if cmd == "run":
        m.run(int(args[1], 0)); print("K"); return 0
    if cmd == "runi":
        words = load_hex(args[1]); m.write_words(0x400, words); m.run_interactive(0x400); print(); return 0
    if cmd == "runc":
        words = load_hex(args[1]); m.write_words(0x400, words)
        out = m.run_capture(0x400, timeout=float(args[2]) if len(args) > 2 else 5.0)
        sys.stdout.write(out.decode("ascii", "replace")); sys.stdout.flush(); return 0
    print(f"unknown command {cmd!r}\n{__doc__}"); return 2

if __name__ == "__main__":
    sys.exit(main())

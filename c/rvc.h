// Tiny freestanding runtime for the Loop RISC-V SoC (no libc). UART TX only.
#ifndef RVC_H
#define RVC_H
#define IO_BASE      0x00400000u
#define UART_TX      (IO_BASE + 0x08)   // full-word store: low byte is transmitted
#define UART_STATUS  (IO_BASE + 0x10)   // bit 9 = transmitter busy
#define LEDS         (IO_BASE + 0x04)   // low 5 bits drive D1..D5
static inline void mmio_w(unsigned a, unsigned v){ *(volatile unsigned*)a = v; }
static inline unsigned mmio_r(unsigned a){ return *(volatile unsigned*)a; }
void putch(char c);          // blocking, waits for the transmitter
void puts_(const char* s);   // string, no trailing newline
void put_uint(unsigned v);   // decimal
void put_hex(unsigned v);    // 8-digit hex
void leds(unsigned v);
#endif

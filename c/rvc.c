#include "rvc.h"
void putch(char c){
  while (mmio_r(UART_STATUS) & (1u<<9)) { }   // wait while busy
  mmio_w(UART_TX, (unsigned char)c);
}
void puts_(const char* s){ while (*s) putch(*s++); }
void put_uint(unsigned v){
  char b[10]; int n = 0;
  if (v == 0) { putch('0'); return; }
  while (v) { b[n++] = '0' + (v % 10); v /= 10; }
  while (n) putch(b[--n]);
}
void put_hex(unsigned v){
  putch('0'); putch('x');
  for (int i = 28; i >= 0; i -= 4) putch("0123456789abcdef"[(v>>i)&0xF]);
}
void leds(unsigned v){ mmio_w(LEDS, v & 0x1F); }

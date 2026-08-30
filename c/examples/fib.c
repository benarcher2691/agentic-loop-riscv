#include "../rvc.h"
// Fibonacci without hardware multiply (the core is RV32I: no M extension).
int main(void){
  unsigned a = 0, b = 1;
  puts_("fib: ");
  for (int i = 0; i < 15; i++){
    put_uint(a); putch(' ');
    unsigned t = a + b; a = b; b = t;
  }
  putch('\n');
  return 0;
}

#include "../rvc.h"
// Primes below 50 by trial division (uses only add/sub/compare — no mul/div,
// so nothing links in libgcc's soft-multiply). Lights an LED per prime found.
static int is_prime(unsigned n){
  if (n < 2) return 0;
  for (unsigned d = 2; d*d <= n; d++){          // d*d: small, stays in range
    unsigned m = n;
    while (m >= d) m -= d;                       // m = n % d, the slow honest way
    if (m == 0) return 0;
  }
  return 1;
}
int main(void){
  puts_("primes<50: ");
  unsigned count = 0;
  for (unsigned n = 2; n < 50; n++)
    if (is_prime(n)){ put_uint(n); putch(' '); leds(++count); }
  putch('\n');
  return 0;
}

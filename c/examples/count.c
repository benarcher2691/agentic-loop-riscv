#include "../rvc.h"
// Prints the first n primes, n typed at the prompt (UART input, Phase 6).
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
  puts_("primes? ");
  unsigned n = get_uint();
  putch('\n');
  unsigned count = 0;
  for (unsigned v = 2; count < n; v++)
    if (is_prime(v)){ put_uint(v); putch(' '); count++; }
  putch('\n');
  return 0;
}

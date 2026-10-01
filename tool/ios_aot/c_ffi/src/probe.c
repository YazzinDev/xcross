#include <stdint.h>

typedef struct { int64_t integer; double fraction; } ProbePair;

ProbePair probe_pair(int64_t integer, double fraction) {
  return (ProbePair){integer, fraction};
}

double probe_sum_pair(ProbePair value) {
  return value.integer + value.fraction;
}

int64_t probe_callback(int64_t value, int64_t (*callback)(int64_t)) {
  return callback(value);
}

int64_t probe_product(void) {
#ifdef NDEBUG
  return 1;
#else
  return 0;
#endif
}

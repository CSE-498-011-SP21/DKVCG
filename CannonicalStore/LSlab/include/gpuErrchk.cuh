#include <cstdio>

#ifndef GPUERRCHK_CU
#define GPUERRCHK_CU

#define gpuErrchk(ans)                                                         \
  { gpuAssert_slab((ans), __FILE__, __LINE__); }

inline void gpuAssert_slab(cudaError_t code, const char *file, int line,
                      bool abort = true) {
  if (code != cudaSuccess) {
    fprintf(stderr, "GPUassert: %s %s %d\n", cudaGetErrorString(code), file,
            line);
    if (abort)
      exit(code);
  }
}

#endif
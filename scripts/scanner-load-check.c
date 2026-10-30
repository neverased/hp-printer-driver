#include <dlfcn.h>
#include <stdio.h>

#if !defined(__arm64__)
#error "The scanner dependency check must be built for arm64 only."
#endif

int main(int argc, char **argv) {
    int failed = 0;
    for (int i = 1; i < argc; i++) {
        if (dlopen_preflight(argv[i])) {
            printf("PASS ARM64 dependencies: %s\n", argv[i]);
        } else {
            fprintf(stderr, "FAIL ARM64 dependencies: %s\n%s\n", argv[i], dlerror());
            failed = 1;
        }
    }
    return failed;
}

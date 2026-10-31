/*
 * Copyright (c) 2026 Nicolas Christe
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

// A C target needs a source file; this target only exports include/swift_support.h.

// Embedded Swift platform layer (swift/EmbeddedPlatform.h). The toolchain's
// shims are empty for riscv32, so the hooks the runtime links against are
// here, on ESP-IDF's libc (posix_memalign and free are its heap). Weak, so an
// app can provide its own. Not defined: the _swift_mutex_* and _swift_tls_*
// families. The toolchain's single-threaded version has no real lock, which
// FreeRTOS preemption breaks; an app using Mutex gets a link error instead.
//
// Heap allocation is not safe in an ISR, so Swift code that allocates (class
// instances, Array, String) must not run there.

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#define SWIFT_ALLOC_ZERO_MEMORY 0x01

__attribute__((weak)) void *_swift_allocate(size_t alignment, size_t size, unsigned long flags) {
    void *ptr = NULL;
    if (posix_memalign(&ptr, alignment, size) != 0) {
        return NULL;
    }
    if (flags & SWIFT_ALLOC_ZERO_MEMORY) {
        memset(ptr, 0, size);
    }
    return ptr;
}

__attribute__((weak)) void _swift_deallocate(void *ptr, size_t alignment, size_t size, unsigned long flags) {
    (void)alignment;
    (void)size;
    (void)flags;
    free(ptr);
}

__attribute__((weak)) void _swift_generateRandom(void *buffer, size_t nbytes) {
    arc4random_buf(buffer, nbytes);
}

__attribute__((weak)) void _swift_generateRandomHashSeed(void *buffer, size_t nbytes) {
    arc4random_buf(buffer, nbytes);
}

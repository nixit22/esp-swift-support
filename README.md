# SwiftSupport

Header-only ESP-IDF component that wires [Embedded Swift](https://github.com/apple/swift-embedded-examples) into the ESP-IDF CMake build system. Every other Swift component in this repo depends on it. Requires ESP-IDF **5.5+** and a Swift toolchain (`swiftc` in `PATH`).

## Usage

Add `SwiftSupport` to `PRIV_REQUIRES` and call `swift_configure()` after `idf_component_register()`:

```cmake
idf_component_register(
    SRCS "MyFile.swift" "helper.c"
    PRIV_INCLUDE_DIRS "."
    REQUIRES SwiftPlatform          # any component whose Swift API callers import
    PRIV_REQUIRES SwiftSupport
)

swift_configure(MODULE_NAME MyModule)   # MODULE_NAME optional, defaults to component name
```

Use the `SWIFT_NAME` macro from `swift_support.h` to expose C functions to Swift with idiomatic names:

```c
#include <swift_support.h>

SWIFT_NAME("myFunction(_:)")
void my_c_function(int value);
```

See [`CLAUDE.md`](CLAUDE.md) for how `swift_configure()` and the build hooks work internally.

## License

MIT License — Copyright (c) 2026 Nicolas Christe

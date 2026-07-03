# SwiftSupport

An ESP-IDF component that enables [Embedded Swift](https://github.com/apple/swift-embedded-examples) compilation for ESP32 targets using ESP-IDF 6.0+.

## Overview

`SwiftSupport` is a foundational, header-only component that wires the Swift compiler into the ESP-IDF CMake build system. It must be added as a dependency to any component that contains Swift source files.

It provides:

- **Swift language enablement** — detects `swiftc`, enables CMake Swift support, and enforces whole-module compilation mode required by Embedded Swift.
- **`swift_configure()` macro** — configures a component target with the correct Embedded Swift compiler flags (target triple, RISC-V arch flags, size optimisation, PIC/PIE disabled, module emission, etc.).
- **RISC-V flag extraction** — automatically reads `-march`/`-mabi` from the ESP-IDF toolchain and strips Espressif-specific ISA extensions unsupported by the Swift compiler.
- **`MACRO=VALUE` definition guard** — overrides `target_compile_definitions()` to wrap `MACRO=VALUE` items in `$<COMPILE_LANGUAGE:C,CXX,ASM>` generator expressions, since the Embedded Swift driver rejects the `=VALUE` form.
- **`SWIFT_NAME` macro** — `include/swift_support.h` exports the `__attribute__((swift_name(...)))` macro for use in C headers, allowing C symbols to be renamed for Swift callers.

## Requirements

- ESP-IDF **6.0** or later
- [Embedded Swift toolchain](https://www.swift.org/download/) (`swiftc` in `PATH` or pointed to by `CMAKE_Swift_COMPILER`)

## Usage

### 1. Add the repo to your project

Clone `swift-esp` alongside your project and point `EXTRA_COMPONENT_DIRS` at the repo root in your app's `CMakeLists.txt`:

```cmake
set(EXTRA_COMPONENT_DIRS
    "${CMAKE_CURRENT_LIST_DIR}/../swift-esp"
)
```

ESP-IDF discovers all components (`SwiftSupport`, `SwiftPlatform`, `SwiftGPIO`, `SwiftI2C`) automatically. No `idf_component.yml` entry is needed.

### 2. Configure the build

Add `SwiftSupport` as a `PRIV_REQUIRES` dependency in your component's `CMakeLists.txt`, then call `swift_configure()` after `idf_component_register()`:

```cmake
idf_component_register(
    SRCS
        MyFile.swift
        helper.c
    PRIV_INCLUDE_DIRS "."
    PRIV_REQUIRES SwiftSupport
)

swift_configure(
    MODULE_NAME MyModule   # optional, defaults to component name
)
```

### `swift_configure()` arguments

| Argument | Required | Description |
|---|---|---|
| `MODULE_NAME` | No | Swift module name. Defaults to the component name. |
| `MODULE_MAP` | No | Path (relative to the component directory) to a `module.modulemap` file. Defaults to `module.modulemap` if it exists. |

### Exposing C APIs to Swift

Use the `SWIFT_NAME` macro from `swift_support.h` to give C functions Swift-friendly names:

```c
#include <swift_support.h>

SWIFT_NAME("myFunction(_:)")
void my_c_function(int value);
```

## Test App

This repository includes a minimal ESP-IDF test application at `test-app/`.

It validates that the component is discoverable and can be consumed by a normal IDF app.

Build it with ESP-IDF:

```bash
cd test-app
idf.py set-target esp32c6
idf.py build
```

## Acknowledgements

This component is largely inspired by [espressif/esp-swift](https://github.com/espressif/esp-swift), the official Espressif component for Embedded Swift on ESP-IDF. The main design difference is that `SwiftSupport` uses a `module.modulemap` file to expose C APIs to Swift instead of a bridging header, which avoids the need for a dummy C source file and integrates more cleanly with the standard CMake `idf_component_register()` workflow.

## License

MIT License — Copyright (c) 2026 Nicolas Christe

# SwiftSupport

Builds Swift packages for ESP-IDF with [SwiftPM](https://www.swift.org/package-manager/) and
[Embedded Swift](https://github.com/apple/swift-embedded-examples), and holds the `SWIFT_NAME()`
header that the C glue of the other esp-swift packages includes. Every other esp-swift package
depends on it. Requires ESP-IDF **5.5+**, CMake 3.19+ and an Embedded Swift toolchain.

It is two things in one folder:

- a SwiftPM package (`Package.swift`, `Sources/SwiftSupport`): the `swift_support.h` header;
- an IDF component (`CMakeLists.txt`, `project_include.cmake`, `cmake/swift_build.py`) that defines
  `swift_package()`, and `cmake/swiftpm_components.cmake`, which the app's top-level
  `CMakeLists.txt` includes (see below).

## Setting up an app

The app is an ESP-IDF project that is also a Swift package.

`Package.swift` (the app's Swift code is in `Sources/App`; do not name a file `main.swift`):

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "App",
    products: [.library(name: "App", type: .static, targets: ["App"])],
    dependencies: [
        .package(url: "https://github.com/nixit22/esp-swift-support.git", from: "0.1.0"),
        .package(url: "https://github.com/nixit22/esp-swift-gpio.git", from: "0.1.0"),
    ],
    targets: [
        .target(name: "App", dependencies: [.product(name: "GPIO", package: "esp-swift-gpio")]),
    ],
    swiftLanguageModes: [.v5]
)
```

Top-level `CMakeLists.txt`. SwiftPM has to resolve the packages first: esp-swift-support, and any
package whose root `CMakeLists.txt` calls `idf_component_register()` (for example
esp-swift-matter's IDF side), are IDF components inside SwiftPM checkouts. The app only runs
`swift package resolve`; `cmake/swiftpm_components.cmake`, from the esp-swift-support checkout
that `resolve` just made, adds those packages to `EXTRA_COMPONENT_DIRS`:

```cmake
cmake_minimum_required(VERSION 3.19)

# SwiftPM works in <build>/swift-build, the folder swift_package() builds in. Any `swift` can
# resolve (run in this folder, so that swiftly's `swift` uses its .swift-version);
# swift_package() picks the Embedded Swift toolchain later.
find_program(SWIFT_PROGRAM swift REQUIRED)
set(SWIFTPM_SCRATCH "${CMAKE_BINARY_DIR}/swift-build")
# ESP-IDF's PATH has its GCC/binutils toolchains (riscv32-esp-elf, esp32ulp-elf...,
# with a plain `ld`), which SwiftPM would use to link the package manifest for the
# host: take them out of PATH for SwiftPM.
string(REPLACE ":" ";" SWIFTPM_PATH "$ENV{PATH}")
list(FILTER SWIFTPM_PATH EXCLUDE REGEX "-elf")
list(JOIN SWIFTPM_PATH ":" SWIFTPM_PATH)
set(SWIFTPM_ENV "${CMAKE_COMMAND}" -E env "PATH=${SWIFTPM_PATH}")
execute_process(
    COMMAND ${SWIFTPM_ENV} "${SWIFT_PROGRAM}" package
        --package-path "${CMAKE_CURRENT_LIST_DIR}" --scratch-path "${SWIFTPM_SCRATCH}" resolve
    WORKING_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}"
    COMMAND_ERROR_IS_FATAL ANY)
include("${SWIFTPM_SCRATCH}/checkouts/esp-swift-support/cmake/swiftpm_components.cmake")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(my_app)
```

`main/CMakeLists.txt`, with an empty `main/swift_flags.c` (its compile command gives SwiftPM the
C flags of ESP-IDF). The component has no `REQUIRES`, so all ESP-IDF include folders are used:

```cmake
idf_component_register(SRCS "swift_flags.c")

swift_package(
    PACKAGE_DIR "${CMAKE_CURRENT_LIST_DIR}/.."
    PRODUCT App
)
```

## The Swift toolchain

`swift_package()` uses, in this order: its `SWIFT_BIN` argument; `$ESP_SWIFT_BIN` (a toolchain's
`usr/bin`); the toolchain [swiftly](https://github.com/swiftlang/swiftly) selects for the app (the
version in the app's `.swift-version` file, for example `main-snapshot-2026-09-21`); else the
directory of the `swift` in `PATH` (for example in CI). It needs `usr/lib/swift/embedded`, and
`llvm-ar` (else ESP-IDF's `ar` is used).

## Writing a package for ESP-IDF

A package with C or C++ glue, as esp-swift-gpio does:

- a C target `ESP_GPIO` with `include/ESP_GPIO.h`: SwiftPM generates the module map from the header
  named like the target. Do not name a target like an ESP-IDF header ignoring case
  (`ESP_Matter.h` would shadow `esp_matter.h` on macOS);
- a Swift target `GPIO` that depends on it and re-exports it (`@_exported import ESP_GPIO`);
- dependencies on the other packages by URL. `swiftSettings`/`unsafeFlags` are not needed: the
  flags come from the toolset below;
- `#include <swift_support.h>` for `SWIFT_NAME()`.

ESP-IDF's headers are available to the C/C++ targets; ESP-IDF components that are not part of
ESP-IDF (registry components) must be declared by the app's, or an IDF-side component's,
`idf_component.yml` (see esp-swift-matter).

## What swift_package() does

On every build, `cmake/swift_build.py`:

1. reads the C flags of `swift_flags.c` from `compile_commands.json` (include folders, defines,
   `-march`/`-mabi`) and the enabled `CONFIG_*` options from `config/sdkconfig.json`;
2. writes a SwiftPM toolset file: Embedded Swift compiler options, `-D CONFIG_*` Swift conditions
   (and `LOG_<LEVEL>_ENABLED`, from `CONFIG_LOG_MAXIMUM_LEVEL`), the C and C++ flags, and an ELF
   archiver;
3. runs `swift build --triple riscv32-none-none-eabi --build-system native` in
   `<build>/swift-build`;
4. copies the library, which CMake links with `--whole-archive` into the firmware.

See [`CLAUDE.md`](CLAUDE.md) for details.

## License

MIT License — Copyright (c) 2026 Nicolas Christe

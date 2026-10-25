# SwiftSupport

Builds Swift packages for ESP-IDF with SwiftPM (Embedded Swift, RISC-V) and exports the
`SWIFT_NAME()` macro. Swift module name of the SwiftPM target: **`SwiftSupport`** (C only).

## Files

| File | Role |
|---|---|
| `Package.swift` | SwiftPM package: the C target `SwiftSupport` |
| `Sources/SwiftSupport/include/swift_support.h` | Exports the `SWIFT_NAME()` attribute macro |
| `Sources/SwiftSupport/swift_support.c` | Empty: a C target needs a source file |
| `CMakeLists.txt` | `idf_component_register()` with nothing: the IDF side exists for `project_include.cmake` |
| `project_include.cmake` | Defines `swift_package()` (runs before any component's `CMakeLists.txt`) |
| `cmake/swiftpm_components.cmake` | Bootstrap include for the app's top-level `CMakeLists.txt` (fills `EXTRA_COMPONENT_DIRS`) |
| `cmake/swift_build.py` | Writes the SwiftPM toolset file and runs `swift build` |

## Key behaviours

**`swift_package(PACKAGE_DIR PRODUCT [SWIFT_BIN] [FLAGS_SOURCE])`** is called by an app's `main`
component (no `REQUIRES`, with an empty `swift_flags.c`). It adds the custom target
`swift_package_<PRODUCT>`, which runs `swift_build.py`, strips `.swift_modhash` with `objcopy`, and
makes the component depend on and `--whole-archive`-link `lib<PRODUCT>.a`. ESP-IDF no longer
compiles any Swift: `enable_language(Swift)`, `swift_configure()`, the CXX-linker and
`target_compile_definitions` workarounds of the previous versions are gone.

**`swift_build.py`** is a port of espswift's `internal build-package`:
- the C flags come from the `swift_flags.c` entry of `compile_commands.json` (response files
  expanded, `_xesp*` removed from `-march`); the C++ flags are those plus `-fno-exceptions
  -fno-rtti` and the C++ compiler's own include folders; `-fno-blocks` is added because newlib's
  `unistd.h` has a parameter named `__block`;
- the Swift options are `-enable-experimental-feature Embedded -wmo -Osize -g -Xfrontend
  -function-sections -Xfrontend -enable-single-module-llvm-emission` (the last one so that `@used`/`@section` globals compile), plus `-D CONFIG_<name>` for every enabled `sdkconfig.json` option and
  `-D LOG_<LEVEL>_ENABLED` computed from the integer `CONFIG_LOG_MAXIMUM_LEVEL` (`Logger` in
  esp-swift-platform uses `#if LOG_INFO_ENABLED`);
- clang gets GCC's integer types (`-U`/`-D` of `__UINT32_TYPE__`, `__INT32_TYPE__`, ... taken from
  `<gcc> -dM -E`): GCC's `uint32_t` is `long unsigned int` and clang's `unsigned int`, so the C++ glue's symbols
  would mangle differently from those of GCC-built libraries (esp_matter) and fail to link;
- `PATH` is stripped of the `*-elf` entries (ESP-IDF's GCC/binutils, with a plain `ld`) while
  SwiftPM runs: it links the package manifest for the host with the first `ld` it finds;
- `--build-system native` because Swift Build (default since Swift 6.4) links C targets with
  Apple's linker, which cannot link ESP32 code.

**Toolchain selection** (`swift_package()`): `SWIFT_BIN`, `$ESP_SWIFT_BIN`, swiftly
(`swiftly run sh -c "command -v swift" +<version from .swift-version>` in the package folder: the
explicit selector keeps the result independent of the working directory; swiftly's `swift` proxy is
never called by the build), else the `swift` in `PATH`.

**Bootstrap** (in the app's top-level `CMakeLists.txt`, see the README): this component lives in a
SwiftPM checkout, so SwiftPM must resolve before ESP-IDF scans components. The app runs `swift
package resolve` and `show-dependencies --format json` with `--scratch-path <build>/swift-build` (the
folder `swift_build.py` builds in). Only the `resolve` (with `*-elf` removed from `PATH`) is in the app;
the rest is `cmake/swiftpm_components.cmake`, which the app includes from the checkout `resolve`
made (`<build>/swift-build/checkouts/esp-swift-support/cmake/`; its header has the snippet): it adds
every package folder whose `CMakeLists.txt` calls `idf_component_register()` to
`EXTRA_COMPONENT_DIRS`. `resolve` keeps pinned revisions: use
`swift package update` to follow a branch.

**C and C++ targets** get their module map from SwiftPM: the umbrella header must be
`include/<TargetName>.h`. Avoid target names that are an ESP-IDF header name ignoring case.

## Adding a new package

C target + Swift target as described in the README, URL dependencies on the `SPM` branch (or a tag),
and an app (the package's `test-app/`) that depends on it with `.package(path: "..")`.

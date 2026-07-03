# SwiftSupport

Header-only ESP-IDF component that wires the Embedded Swift toolchain into the ESP-IDF CMake build system. Contains no Swift source files.

## Files

| File | Role |
|---|---|
| `project_include.cmake` | Runs at **project scope** — enables Swift, defers linker and definition fixups |
| `CMakeLists.txt` | Defines `swift_configure()` and `extract_riscv_flags()` |
| `include/swift_support.h` | Exports the `SWIFT_NAME()` attribute macro |

## Key behaviours

**`project_include.cmake` runs before any component `CMakeLists.txt`** — this is why it can call `enable_language(Swift)` and install the `target_compile_definitions()` override that intercepts definitions from all ESP-IDF components.

**`target_compile_definitions()` override** wraps every `MACRO=VALUE` item in `$<$<COMPILE_LANGUAGE:C,CXX,ASM>:...>` so the Embedded Swift driver never sees it. The definition is dropped for Swift entirely (not replaced with bare `-DMACRO`) to avoid silent semantic changes. A deferred `swift_fixup_build_definitions()` applies the same fix to definitions set directly on `__idf_build_target`.

**CXX linker** — `force_cxx_linker()` is deferred via `cmake_language(DEFER ...)` so it runs after all component targets exist and can resolve the ELF target name.

**`swift_configure()` macro** (called by each Swift component after `idf_component_register()`):
- Clears all inherited C/C++ compile options (Swift driver rejects them).
- Reads `-march`/`-mabi` from `IDF_TOOLCHAIN_BUILD_DIR/cflags` (ESP-IDF 6.0+), stripping `_xesp*` extensions.
- Falls back to `-mabi=ilp32` when the response file omits it.
- Auto-discovers `module.modulemap` at the component root unless `MODULE_MAP` is specified.
- `MODULE_NAME` defaults to `${COMPONENT_NAME}` when omitted.
- Strips the `.swift_modhash` ELF section via a `POST_BUILD` `objcopy` command (bare-metal linker warning).

## Adding a new Swift component

```cmake
idf_component_register(
    SRCS "MyFile.swift" "helper.c"
    PRIV_INCLUDE_DIRS "."
    REQUIRES SwiftPlatform          # REQUIRES (not PRIV_REQUIRES) when callers import Swift module
    PRIV_REQUIRES SwiftSupport
)

swift_configure(MODULE_NAME MyModule)
```

Place a `module.modulemap` at the component root to expose C headers — it is picked up automatically.

# MIT License
#
# Copyright (c) 2026 Nicolas Christe
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# ==============================================================================
# SwiftSupport component
# ==============================================================================
# Header-only ESP-IDF component that wires the Embedded Swift compiler into the
# ESP-IDF CMake build system.


idf_component_register(
    INCLUDE_DIRS include ${CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES}
)

# ------------------------------------------------------------------------------
# extract_riscv_flags(<out_var>)
# ------------------------------------------------------------------------------
# Reads the RISC-V -march / -mabi flags that ESP-IDF chose for the current
# target and reformats them for the Swift compiler.
#
# The Swift compiler passes architecture flags to its embedded Clang front-end
# via -Xcc, so each flag must be prefixed individually.  Espressif-specific ISA
# extensions (e.g. _xespXXX) are stripped because the Swift compiler does not
# recognise them.
#
# Arguments:
#   out_var  Name of the variable in which the formatted flags are returned to
#            the caller's scope, e.g. "-Xcc -march=rv32imc -Xcc -mabi=ilp32".
#
# Reads:
#   IDF_TOOLCHAIN_BUILD_DIR  Path to the toolchain build directory that contains
#                            the "cflags" response file (available in IDF ≥ 6.0).
function(extract_riscv_flags out_arch_flags)
    set(march_flag "")
    set(mabi_flag "")

    # Extract flags from ESP-IDF's cflags response file (ESP-IDF 6.0+)
    if(DEFINED IDF_TOOLCHAIN_BUILD_DIR AND EXISTS "${IDF_TOOLCHAIN_BUILD_DIR}/cflags")
        file(STRINGS "${IDF_TOOLCHAIN_BUILD_DIR}/cflags" cflags_lines)
        foreach(line IN LISTS cflags_lines)
            if(line MATCHES "^-march=")
                set(march_flag "${line}")
            elseif(line MATCHES "^-mabi=")
                set(mabi_flag "${line}")
            endif()
        endforeach()
    endif()

    # Fall back to the most common ABI when the toolchain file omits it.
    if(NOT mabi_flag)
        set(mabi_flag "-mabi=ilp32")
    endif()

    # Strip Espressif-specific ISA extensions that the Swift compiler rejects.
    if(march_flag)
        string(REGEX REPLACE "_xesp[^ ]*" "" march_flag "${march_flag}")
    endif()

    message(STATUS "Swift: Using arch flags '${march_flag}' '${mabi_flag}'")

    # Prefix each flag with -Xcc so the Swift driver forwards it to Clang.
    set(${out_arch_flags} "-Xcc ${march_flag} -Xcc ${mabi_flag}" PARENT_SCOPE)
endfunction()

# ------------------------------------------------------------------------------
# swift_configure([MODULE_NAME <name>] [MODULE_MAP <path>])
# ------------------------------------------------------------------------------
# Configures ${COMPONENT_LIB} for Embedded Swift compilation.
#
# Must be called after idf_component_register() inside a component's own
# CMakeLists.txt.  It clears the C/C++ compile options inherited from the
# toolchain (the Swift driver rejects them) and replaces them with the correct
# Embedded Swift flags for the current ESP32 target.
#
# Named arguments:
#   MODULE_NAME  Swift module name for this component.  Defaults to
#                ${COMPONENT_NAME} when omitted.
#   MODULE_MAP   Path to a module.modulemap file relative to the component
#                directory, used to expose C headers to Swift.  When omitted,
#                a file named "module.modulemap" in the component directory is
#                used automatically if it exists.
macro(swift_configure)
    # Parse named arguments: MODULE_NAME and MODULE_MAP.
    cmake_parse_arguments(SWIFT "" "MODULE_NAME;MODULE_MAP" "" ${ARGN})

    # Resolve the RISC-V architecture flags for the active IDF target.
    extract_riscv_flags(arch_flags)

    # The Swift driver rejects C/C++ toolchain flags, so start from a clean
    # slate before adding Swift-specific options.
    set_target_properties(${COMPONENT_LIB} PROPERTIES COMPILE_OPTIONS "")

    # Default the module name to the component name when not explicitly set.
    if(NOT SWIFT_MODULE_NAME)
        set(SWIFT_MODULE_NAME "${COMPONENT_NAME}") 
    endif()

    target_compile_options(${COMPONENT_LIB} PRIVATE "$<$<COMPILE_LANGUAGE:Swift>:SHELL:
        -target riscv32-none-none-eabi
        ${arch_flags}
        -Xfrontend -function-sections
        -enable-experimental-feature Embedded
        -wmo
        -parse-as-library
        -Osize
        -Xcc -fno-pic
        -Xcc -fno-pie
        -Xcc -fmodules-cache-path=${CMAKE_BINARY_DIR}/clang-module-cache
        -pch-output-dir ${CMAKE_CURRENT_BINARY_DIR}/pch
        -Xfrontend -enable-single-module-llvm-emission
        -module-name ${SWIFT_MODULE_NAME}
        -emit-module
        -emit-module-path ${CMAKE_CURRENT_BINARY_DIR}/${SWIFT_MODULE_NAME}.swiftmodule
    >")

    # Resolve the module map path: explicit argument takes priority, then the
    # conventional module.modulemap in the component directory.
    if(SWIFT_MODULE_MAP)
        set(_module_map_path "${CMAKE_CURRENT_LIST_DIR}/${SWIFT_MODULE_MAP}")
    else()
        set(_default_map "${CMAKE_CURRENT_LIST_DIR}/module.modulemap")
        if(EXISTS "${_default_map}")
            set(_module_map_path "${_default_map}")
        endif()
    endif()

    # Pass the module map to the Swift compiler so it can import C modules.
    if(_module_map_path)
        target_compile_options(${COMPONENT_LIB} PUBLIC "$<$<COMPILE_LANGUAGE:Swift>:SHELL:
            -Xcc -fmodule-map-file=${_module_map_path}  
        >")
    endif()

    # The Swift compiler emits a .swift_modhash section that is not needed at
    # runtime and can cause linker warnings on bare-metal targets.  Strip it.
    add_custom_command(
        TARGET ${COMPONENT_LIB}
        POST_BUILD
        COMMAND ${CMAKE_OBJCOPY} --remove-section .swift_modhash
                $<TARGET_FILE:${COMPONENT_LIB}> $<TARGET_FILE:${COMPONENT_LIB}>
        COMMENT "Removing .swift_modhash section from ${COMPONENT_LIB}"
    )
endmacro()

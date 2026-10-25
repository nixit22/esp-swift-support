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

# Defines swift_package(): builds a SwiftPM package (Embedded Swift) as a step
# of the ESP-IDF build and links it into the firmware. Replaces espswift's
# `internal build-package` and the old per-component swift_configure().
#
#   swift_package(PACKAGE_DIR <dir with Package.swift>
#                 PRODUCT <static library product>
#                 [SWIFT_BIN <toolchain usr/bin>]
#                 [FLAGS_SOURCE <empty .c in the component>])  # default: swift_flags.c
#
# Call it from the CMakeLists.txt of a component (typically main) right after
# idf_component_register(). The component must have no REQUIRES, so that
# every ESP-IDF include folder is in FLAGS_SOURCE's compile command.
#
# The Embedded Swift toolchain is, in this order: SWIFT_BIN, $ENV{ESP_SWIFT_BIN},
# the one swiftly selects for the package (.swift-version), or, without swiftly,
# the directory of the `swift` found in PATH.

set(SWIFT_SUPPORT_CMAKE_DIR "${CMAKE_CURRENT_LIST_DIR}/cmake")

# Sets <out_var> to the usr/bin folder of the toolchain swiftly selects for
# <package_dir>, or leaves it empty. swiftly's `swift` in PATH is a proxy that
# picks a toolchain from the current directory's .swift-version (else the
# global default), so asking it for the real path would depend on where the
# build runs. Instead: the version in <package_dir>/.swift-version is passed
# as an explicit +selector, and without that file swiftly runs in
# <package_dir>, where it finds .swift-version files in the parent folders.
function(_swift_support_swiftly_bin package_dir out_var)
    set(${out_var} "" PARENT_SCOPE)
    find_program(SWIFTLY_PROGRAM swiftly HINTS "$ENV{SWIFTLY_BIN_DIR}" "$ENV{HOME}/.swiftly/bin" /opt/homebrew/bin /usr/local/bin)
    if(NOT SWIFTLY_PROGRAM)
        return()
    endif()

    set(selector "")
    set(version_file "${package_dir}/.swift-version")
    if(EXISTS "${version_file}")
        file(STRINGS "${version_file}" version LIMIT_COUNT 1)
        string(STRIP "${version}" version)
        if(version)
            set(selector "+${version}")
        endif()
        set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${version_file}")
    endif()

    execute_process(
        COMMAND "${SWIFTLY_PROGRAM}" run sh -c "command -v swift" ${selector}
        WORKING_DIRECTORY "${package_dir}"
        OUTPUT_VARIABLE output
        ERROR_VARIABLE error
        RESULT_VARIABLE result
        OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(NOT result EQUAL 0)
        message(WARNING "swift_package: swiftly could not select a toolchain ${selector}: ${error}")
        return()
    endif()
    # The last line: swiftly may print notices before it.
    string(REGEX REPLACE "^.*\n" "" swift_path "${output}")
    get_filename_component(bin "${swift_path}" DIRECTORY)
    set(${out_var} "${bin}" PARENT_SCOPE)
endfunction()

function(swift_package)
    cmake_parse_arguments(ARG "" "PACKAGE_DIR;PRODUCT;SWIFT_BIN;FLAGS_SOURCE" "" ${ARGN})

    # The toolchain: the SWIFT_BIN argument, else $ESP_SWIFT_BIN, else the
    # one swiftly selects for the package (.swift-version).
    if(NOT ARG_SWIFT_BIN)
        set(ARG_SWIFT_BIN "$ENV{ESP_SWIFT_BIN}")
    endif()
    if(NOT ARG_SWIFT_BIN)
        _swift_support_swiftly_bin("${ARG_PACKAGE_DIR}" ARG_SWIFT_BIN)
    endif()
    if(NOT ARG_SWIFT_BIN AND NOT SWIFTLY_PROGRAM)
        # No swiftly (for example CI): the toolchain installed in PATH.
        find_program(SWIFT_IN_PATH swift)
        if(SWIFT_IN_PATH)
            file(REAL_PATH "${SWIFT_IN_PATH}" swift_real)
            get_filename_component(ARG_SWIFT_BIN "${swift_real}" DIRECTORY)
        endif()
    endif()
    if(NOT ARG_SWIFT_BIN OR NOT EXISTS "${ARG_SWIFT_BIN}/swift")
        message(FATAL_ERROR "swift_package: no Swift toolchain. Set SWIFT_BIN or ESP_SWIFT_BIN to the Embedded Swift toolchain's usr/bin folder, or install swiftly and pin a toolchain in ${ARG_PACKAGE_DIR}/.swift-version.")
    endif()
    if(NOT IS_DIRECTORY "${ARG_SWIFT_BIN}/../lib/swift/embedded")
        message(FATAL_ERROR "swift_package: ${ARG_SWIFT_BIN} is not an Embedded Swift toolchain (no usr/lib/swift/embedded). Is the toolchain pinned in .swift-version a main snapshot?")
    endif()
    # SwiftPM needs an ELF archiver: the toolchain's llvm-ar, else ESP-IDF's ar.
    if(EXISTS "${ARG_SWIFT_BIN}/llvm-ar")
        set(librarian "${ARG_SWIFT_BIN}/llvm-ar")
    else()
        set(librarian "${CMAKE_AR}")
    endif()
    message(STATUS "Swift: toolchain ${ARG_SWIFT_BIN}")
    if(NOT ARG_FLAGS_SOURCE)
        set(ARG_FLAGS_SOURCE "${CMAKE_CURRENT_LIST_DIR}/swift_flags.c")
    endif()

    idf_build_get_property(build_dir BUILD_DIR)
    idf_build_get_property(python PYTHON)

    set(library "${CMAKE_CURRENT_BINARY_DIR}/lib${ARG_PRODUCT}.a")
    string(JOIN "|" implicit_joined ${CMAKE_C_IMPLICIT_INCLUDE_DIRECTORIES})
    string(JOIN "|" implicit_cxx_joined ${CMAKE_CXX_IMPLICIT_INCLUDE_DIRECTORIES})

    # SwiftPM decides what to rebuild; this runs on every build.
    add_custom_target(swift_package_${ARG_PRODUCT}
        COMMAND "${python}" "${SWIFT_SUPPORT_CMAKE_DIR}/swift_build.py"
            --build-folder "${build_dir}"
            --flags-source "${ARG_FLAGS_SOURCE}"
            --package "${ARG_PACKAGE_DIR}"
            --product "${ARG_PRODUCT}"
            --swift-bin "${ARG_SWIFT_BIN}"
            --cc "${CMAKE_C_COMPILER}"
            --librarian "${librarian}"
            --output "${library}"
            --implicit "${implicit_joined}"
            --implicit-cxx "${implicit_cxx_joined}"
        # Swift's module hash section isn't needed in the firmware.
        COMMAND "${CMAKE_OBJCOPY}" --remove-section .swift_modhash "${library}"
        BYPRODUCTS "${library}"
        COMMENT "Building the Swift package ${ARG_PRODUCT}"
        USES_TERMINAL
        VERBATIM)
    add_dependencies(${COMPONENT_LIB} swift_package_${ARG_PRODUCT})

    # Linked as a whole: nothing in ESP-IDF refers to the Swift code until
    # app_main is linked, so the linker would otherwise skip it.
    target_link_options(${COMPONENT_LIB} INTERFACE
        "LINKER:--whole-archive,${library},--no-whole-archive")
    set_property(TARGET ${COMPONENT_LIB} APPEND PROPERTY INTERFACE_LINK_DEPENDS "${library}")

    # Reconfigure when the packages' manifests change.
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${ARG_PACKAGE_DIR}/Package.swift")
endfunction()

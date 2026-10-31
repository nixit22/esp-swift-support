# Bootstrap for apps whose Swift code and esp-swift packages come from SwiftPM.
#
# Include it from the app's top-level CMakeLists.txt, after `swift package resolve` (this file
# lives in a SwiftPM checkout, so the app must resolve before it can include it) and before
# ESP-IDF's project.cmake:
#
#   find_program(SWIFT_PROGRAM swift REQUIRED)
#   set(SWIFTPM_SCRATCH "${CMAKE_BINARY_DIR}/swift-build")
#   string(REPLACE ":" ";" SWIFTPM_PATH "$ENV{PATH}")
#   list(FILTER SWIFTPM_PATH EXCLUDE REGEX "-elf")
#   list(JOIN SWIFTPM_PATH ":" SWIFTPM_PATH)
#   set(SWIFTPM_ENV "${CMAKE_COMMAND}" -E env "PATH=${SWIFTPM_PATH}")
#   execute_process(
#       COMMAND ${SWIFTPM_ENV} "${SWIFT_PROGRAM}" package --package-path "${CMAKE_CURRENT_LIST_DIR}"
#           --scratch-path "${SWIFTPM_SCRATCH}" resolve
#       COMMAND_ERROR_IS_FATAL ANY)
#   set(SWIFT_SUPPORT_DIR "${SWIFTPM_SCRATCH}/checkouts/esp-swift-support")
#   if(NOT EXISTS "${SWIFT_SUPPORT_DIR}")
#       # `swift package edit esp-swift-support --path <dir>` replaces the checkout
#       # with <dir>: SwiftPM records it in workspace-state.json.
#       file(READ "${SWIFTPM_SCRATCH}/workspace-state.json" SWIFTPM_STATE)
#       string(JSON SWIFTPM_DEPS GET "${SWIFTPM_STATE}" object dependencies)
#       string(JSON SWIFTPM_DEP_COUNT LENGTH "${SWIFTPM_DEPS}")
#       math(EXPR SWIFTPM_DEP_LAST "${SWIFTPM_DEP_COUNT} - 1")
#       foreach(i RANGE ${SWIFTPM_DEP_LAST})
#           string(JSON id GET "${SWIFTPM_DEPS}" ${i} packageRef identity)
#           if(id STREQUAL "esp-swift-support")
#               string(JSON SWIFT_SUPPORT_DIR ERROR_VARIABLE err GET "${SWIFTPM_DEPS}" ${i} state path)
#           endif()
#       endforeach()
#   endif()
#   if(NOT EXISTS "${SWIFT_SUPPORT_DIR}/cmake/swiftpm_components.cmake")
#       message(FATAL_ERROR "esp-swift-support not found in ${SWIFTPM_SCRATCH}/checkouts or as an edited package")
#   endif()
#   include("${SWIFT_SUPPORT_DIR}/cmake/swiftpm_components.cmake")
#
# Inputs (set by the snippet above): SWIFT_PROGRAM, SWIFTPM_SCRATCH, SWIFTPM_ENV.
# Output: EXTRA_COMPONENT_DIRS gets every package folder of the dependency graph (the app
# excluded) whose CMakeLists.txt calls idf_component_register(): esp-swift-support itself and,
# for example, the IDF side of esp-swift-matter.

set(SWIFTPM_PACKAGE_DIR "${CMAKE_SOURCE_DIR}")  # the app: its top-level CMakeLists.txt and Package.swift

execute_process(
    COMMAND ${SWIFTPM_ENV} "${SWIFT_PROGRAM}" package
        --package-path "${SWIFTPM_PACKAGE_DIR}" --scratch-path "${SWIFTPM_SCRATCH}"
        show-dependencies --format json
    WORKING_DIRECTORY "${SWIFTPM_PACKAGE_DIR}"
    OUTPUT_VARIABLE SWIFTPM_DEPENDENCIES
    COMMAND_ERROR_IS_FATAL ANY)
file(REAL_PATH "${SWIFTPM_PACKAGE_DIR}" SWIFTPM_ROOT)
string(REGEX MATCHALL "\"path\" *: *\"[^\"]+\"" SWIFTPM_PATHS "${SWIFTPM_DEPENDENCIES}")
list(REMOVE_DUPLICATES SWIFTPM_PATHS)
foreach(entry IN LISTS SWIFTPM_PATHS)
    string(REGEX REPLACE "^\"path\" *: *\"(.*)\"$" "\\1" package_path "${entry}")
    file(REAL_PATH "${package_path}" package_path)
    # Not every CMakeLists.txt is an IDF component (swift-collections has its own).
    if(NOT package_path STREQUAL SWIFTPM_ROOT AND EXISTS "${package_path}/CMakeLists.txt")
        file(STRINGS "${package_path}/CMakeLists.txt" registers REGEX "^[ \t]*idf_component_register")
        if(registers)
            list(APPEND EXTRA_COMPONENT_DIRS "${package_path}")
        endif()
    endif()
endforeach()

if(NOT DEFINED ENV{CC})
    message(FATAL_ERROR "CC must be set to derive CTEST_BUILD_NAME")
endif()
if(NOT DEFINED ENV{CDASH_BUILD_NAME_PREFIX})
    message(FATAL_ERROR "CDASH_BUILD_NAME_PREFIX must be set to derive CTEST_BUILD_NAME")
endif()
if(NOT DEFINED ENV{CTEST_CMAKE_GENERATOR})
    message(FATAL_ERROR "CTEST_CMAKE_GENERATOR must be set")
endif()

set(CTEST_CMAKE_GENERATOR "$ENV{CTEST_CMAKE_GENERATOR}")
string(TOLOWER "${CTEST_CMAKE_GENERATOR}" generator_id)
string(REPLACE " " "-" generator_id "${generator_id}")

execute_process(
    COMMAND $ENV{CC} -dumpmachine
    OUTPUT_VARIABLE host_triplet
    OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY
)
string(REPLACE "-unknown-linux-" "-linux-" host_triplet "${host_triplet}")

execute_process(
    COMMAND $ENV{CC} --version
    OUTPUT_VARIABLE compiler_version
    OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY
)
if(compiler_version MATCHES "clang version ([0-9]+)")
    set(compiler_id "clang")
    set(compiler_major "${CMAKE_MATCH_1}")
elseif(compiler_version MATCHES "gcc \\(GCC\\) ([0-9]+)")
    set(compiler_id "gcc")
    set(compiler_major "${CMAKE_MATCH_1}")
else()
    message(FATAL_ERROR "Could not derive compiler name and version from: ${compiler_version}")
endif()

set(CTEST_BUILD_NAME "$ENV{CDASH_BUILD_NAME_PREFIX}_${host_triplet}_${compiler_id}-${compiler_major}_${generator_id}")
if(DEFINED ENV{CDASH_BUILD_NAME_SUFFIX} AND NOT "$ENV{CDASH_BUILD_NAME_SUFFIX}" STREQUAL "")
    string(APPEND CTEST_BUILD_NAME "_$ENV{CDASH_BUILD_NAME_SUFFIX}")
endif()
message(STATUS "CTEST_BUILD_NAME=${CTEST_BUILD_NAME}")

cmake_host_system_information(RESULT nproc QUERY NUMBER_OF_LOGICAL_CORES)

if(NOT DEFINED CTEST_SITE)
    set(CTEST_SITE "$ENV{CTEST_SITE}")
endif()

get_filename_component(CTEST_SOURCE_DIRECTORY "${CTEST_SOURCE_DIRECTORY}" ABSOLUTE)
set(CTEST_BINARY_DIRECTORY "${CTEST_SOURCE_DIRECTORY}/build-bench")
set(CTEST_GIT_COMMAND git)
set(CTEST_UPDATE_VERSION_ONLY TRUE)
set(CTEST_CMAKE_GENERATOR "Ninja")

if(DEFINED ENV{CTEST_CONFIGURE_PRESET} AND NOT "$ENV{CTEST_CONFIGURE_PRESET}" STREQUAL "")
    set(ctest_configure_preset "$ENV{CTEST_CONFIGURE_PRESET}")
else()
    set(ctest_configure_preset "bench")
endif()

include("${CMAKE_CURRENT_LIST_DIR}/../../bitcoin-core-nightly/scripts/set-cdash-build-name.cmake")

set(bench_presets_file "${CMAKE_CURRENT_LIST_DIR}/../CMakeUserPresets.json")
set(ctest_source_presets_file "${CTEST_SOURCE_DIRECTORY}/CMakeUserPresets.json")
file(COPY_FILE "${bench_presets_file}" "${ctest_source_presets_file}")

set(CTEST_NOTES_FILES)
list(APPEND CTEST_NOTES_FILES "${CMAKE_CURRENT_LIST_FILE}")
list(APPEND CTEST_NOTES_FILES "${ctest_source_presets_file}")
if(DEFINED ENV{BENCHMARK_METADATA} AND EXISTS "$ENV{BENCHMARK_METADATA}")
    list(APPEND CTEST_NOTES_FILES "$ENV{BENCHMARK_METADATA}")
endif()

ctest_start(Nightly)
ctest_update()
ctest_submit(PARTS "Update")

ctest_configure(
    BUILD ${CTEST_BINARY_DIRECTORY}
    SOURCE ${CTEST_SOURCE_DIRECTORY}
    OPTIONS "--preset;${ctest_configure_preset}"
)
list(REMOVE_DUPLICATES CTEST_NOTES_FILES)
ctest_submit(PARTS "Configure" "Notes")
set(CTEST_NOTES_FILES)

ctest_build(BUILD ${CTEST_BINARY_DIRECTORY} TARGET bench_bitcoin RETURN_VALUE build_result)
ctest_submit(PARTS "Build")
if(NOT build_result EQUAL 0)
    ctest_submit(PARTS "Done")
    message(FATAL_ERROR "bench_bitcoin build failed with exit code ${build_result}")
endif()

set(bench_binary "${CTEST_BINARY_DIRECTORY}/bin/bench_bitcoin")
set(bench_script "${CTEST_BINARY_DIRECTORY}/run-bitcoin-bench.sh")
file(WRITE "${bench_script}"
    "#!/usr/bin/env bash\n"
    "set -euo pipefail\n"
    "\"${bench_binary}\" -min-time=\"$ENV{BENCHMARK_MIN_TIME_MS}\" -output-json=\"$ENV{BENCHMARK_JSON}\" -output-csv=\"$ENV{BENCHMARK_CSV}\" 2>&1 | tee \"$ENV{BENCHMARK_LOG}\"\n"
)
file(CHMOD "${bench_script}" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)

file(WRITE "${CTEST_BINARY_DIRECTORY}/CTestTestfile.cmake"
    "add_test(bitcoin-bench \"${bench_script}\")\n"
    "set_tests_properties(bitcoin-bench PROPERTIES TIMEOUT 0)\n"
)

ctest_test(
    BUILD ${CTEST_BINARY_DIRECTORY}
    PARALLEL_LEVEL 1
    OUTPUT_JUNIT "${CTEST_BINARY_DIRECTORY}/bench-junit.xml"
    RETURN_VALUE test_result
)

if(DEFINED ENV{BENCHMARK_LOG} AND EXISTS "$ENV{BENCHMARK_LOG}")
    list(APPEND CTEST_NOTES_FILES "$ENV{BENCHMARK_LOG}")
endif()
ctest_submit(PARTS "Test" "Notes" "Done")

if(NOT test_result EQUAL 0)
    message(FATAL_ERROR "bench_bitcoin failed with exit code ${test_result}")
endif()

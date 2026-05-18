if(NOT DEFINED CTEST_SITE)
    set(CTEST_SITE "$ENV{CTEST_SITE}")
endif()
if(NOT DEFINED CTEST_SOURCE_DIRECTORY)
    set(CTEST_SOURCE_DIRECTORY "$ENV{BITCOIN_PATH}")
endif()

get_filename_component(CTEST_SOURCE_DIRECTORY "${CTEST_SOURCE_DIRECTORY}" ABSOLUTE)
set(CTEST_BINARY_DIRECTORY "$ENV{VALGRIND_FUZZ_BUILD_DIR}")
set(CTEST_BUILD_NAME "valgrind-fuzz")
set(CTEST_CMAKE_GENERATOR "Ninja")
set(CTEST_GIT_COMMAND "git")
set(QA_ASSETS_PATH "$ENV{QA_ASSETS_PATH}")

if(NOT DEFINED VALGRIND_FUZZ_RUN_ONCE)
    execute_process(
        COMMAND git rev-parse HEAD
        WORKING_DIRECTORY ${CTEST_SOURCE_DIRECTORY}
        OUTPUT_VARIABLE OLD_HEAD
        OUTPUT_STRIP_TRAILING_WHITESPACE
        COMMAND_ERROR_IS_FATAL ANY
    )

    while(TRUE)
        execute_process(
            COMMAND git fetch origin
            WORKING_DIRECTORY ${CTEST_SOURCE_DIRECTORY}
            COMMAND_ERROR_IS_FATAL ANY
        )
        execute_process(
            COMMAND git rev-parse origin/master
            WORKING_DIRECTORY ${CTEST_SOURCE_DIRECTORY}
            OUTPUT_VARIABLE NEW_HEAD
            OUTPUT_STRIP_TRAILING_WHITESPACE
            COMMAND_ERROR_IS_FATAL ANY
        )
        execute_process(
            COMMAND git pull --ff-only
            WORKING_DIRECTORY ${QA_ASSETS_PATH}
            COMMAND_ERROR_IS_FATAL ANY
        )

        if(NOT OLD_HEAD STREQUAL NEW_HEAD)
            break()
        endif()
        message("No new commits (at ${OLD_HEAD}), sleeping 60s")
        execute_process(COMMAND sleep 60)
    endwhile()

    find_program(CTEST_COMMAND ctest REQUIRED)
    execute_process(
        COMMAND
            flock "$ENV{BUILD_LOCK}"
            "${CTEST_COMMAND}" --verbose -S "${CMAKE_CURRENT_LIST_FILE}"
            "-DVALGRIND_FUZZ_RUN_ONCE=1"
            "-DCTEST_SOURCE_DIRECTORY=${CTEST_SOURCE_DIRECTORY}"
            "-DCTEST_SITE=${CTEST_SITE}"
        COMMAND_ERROR_IS_FATAL ANY
    )
    return()
endif()

execute_process(
    COMMAND git pull --ff-only
    WORKING_DIRECTORY ${QA_ASSETS_PATH}
    COMMAND_ERROR_IS_FATAL ANY
)

execute_process(
    COMMAND git clean -dfx --exclude=CTestConfig.cmake --exclude=CTestCustom.cmake --exclude=CMakeUserPresets.json
    WORKING_DIRECTORY ${CTEST_SOURCE_DIRECTORY}
    COMMAND_ERROR_IS_FATAL ANY
)

set(valgrind_fuzz_presets_file "${CMAKE_CURRENT_LIST_DIR}/../CMakeUserPresets.json")
set(ctest_source_presets_file "${CTEST_SOURCE_DIRECTORY}/CMakeUserPresets.json")
file(COPY_FILE "${valgrind_fuzz_presets_file}" "${ctest_source_presets_file}")

ctest_start(Continuous)
ctest_update()
ctest_configure(
    BUILD ${CTEST_BINARY_DIRECTORY}
    SOURCE ${CTEST_SOURCE_DIRECTORY}
    OPTIONS "--preset;valgrind-fuzz"
)
ctest_build(BUILD ${CTEST_BINARY_DIRECTORY})

include(ProcessorCount)
ProcessorCount(NCPU)

file(WRITE "${CTEST_BINARY_DIRECTORY}/CTestTestfile.cmake"
    "add_test(valgrind-fuzz ${CTEST_BINARY_DIRECTORY}/test/fuzz/test_runner.py --valgrind -l DEBUG -j ${NCPU} ${QA_ASSETS_PATH}/fuzz_corpora/ --empty_min_time=60)\nset_tests_properties(valgrind-fuzz PROPERTIES TIMEOUT 0)\n"
)

ctest_test(BUILD ${CTEST_BINARY_DIRECTORY})
ctest_submit()

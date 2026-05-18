if(NOT DEFINED CTEST_SITE)
    set(CTEST_SITE "$ENV{CTEST_SITE}")
endif()
if(NOT DEFINED CTEST_SOURCE_DIRECTORY)
    set(CTEST_SOURCE_DIRECTORY "$ENV{BITCOIN_PATH}")
endif()

get_filename_component(CTEST_SOURCE_DIRECTORY "${CTEST_SOURCE_DIRECTORY}" ABSOLUTE)
set(CTEST_BINARY_DIRECTORY "${CTEST_SOURCE_DIRECTORY}")
set(CTEST_BUILD_NAME "guix_multi_${CMAKE_HOST_SYSTEM_PROCESSOR}")
set(CTEST_GIT_COMMAND "git")
set(CTEST_BUILD_COMMAND "bash -c \"unset SOURCE_DATE_EPOCH && '${CTEST_SOURCE_DIRECTORY}/contrib/guix/guix-build'\"")

if(NOT DEFINED GUIX_RUN_ONCE)
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
            "-DGUIX_RUN_ONCE=1"
            "-DCTEST_SOURCE_DIRECTORY=${CTEST_SOURCE_DIRECTORY}"
            "-DCTEST_SITE=${CTEST_SITE}"
        COMMAND_ERROR_IS_FATAL ANY
    )
    return()
endif()

execute_process(
    COMMAND git clean -dfx --exclude=CTestConfig.cmake --exclude=CTestCustom.cmake
    WORKING_DIRECTORY ${CTEST_SOURCE_DIRECTORY}
    COMMAND_ERROR_IS_FATAL ANY
)

ctest_start(Continuous)
ctest_update()
ctest_build()

set(HASH_FILE "${CTEST_BINARY_DIRECTORY}/build-hashes.txt")
execute_process(
    COMMAND bash -c "
        REV=\$(git rev-parse --short=12 HEAD)
        BUILD_DIR=\"guix-build-\${REV}\"
        if [ -d \"\${BUILD_DIR}/output\" ]; then
            uname -m > \"${HASH_FILE}\"
            find \"\${BUILD_DIR}/output/\" -type f -print0 | env LC_ALL=C sort -z | xargs -r0 sha256sum >> \"${HASH_FILE}\"
        fi
    "
    WORKING_DIRECTORY ${CTEST_SOURCE_DIRECTORY}
)
if(EXISTS "${HASH_FILE}")
    set(CTEST_NOTES_FILES "${HASH_FILE}")
endif()

ctest_submit()

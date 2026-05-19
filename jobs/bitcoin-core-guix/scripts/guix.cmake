if(NOT DEFINED CTEST_SITE)
    set(CTEST_SITE "$ENV{CTEST_SITE}")
endif()
if(NOT DEFINED CTEST_SOURCE_DIRECTORY)
    set(CTEST_SOURCE_DIRECTORY "$ENV{BITCOIN_REPO}")
endif()

get_filename_component(CTEST_SOURCE_DIRECTORY "${CTEST_SOURCE_DIRECTORY}" ABSOLUTE)
set(CTEST_BINARY_DIRECTORY "${CTEST_SOURCE_DIRECTORY}")
set(CTEST_BUILD_NAME "guix_multi_${CMAKE_HOST_SYSTEM_PROCESSOR}")
set(CTEST_GIT_COMMAND "git")
set(GUIX_BUILD_LOG "${CTEST_BINARY_DIRECTORY}/guix-build.log")
set(CTEST_BUILD_COMMAND "bash '${CMAKE_CURRENT_LIST_DIR}/run-guix-build.sh' '${CTEST_SOURCE_DIRECTORY}' '${GUIX_BUILD_LOG}'")

set(CTEST_NOTES_FILES "${CMAKE_CURRENT_LIST_FILE}")

execute_process(
    COMMAND git clean -dfx --exclude=CTestConfig.cmake --exclude=CTestCustom.cmake
    WORKING_DIRECTORY ${CTEST_SOURCE_DIRECTORY}
    COMMAND_ERROR_IS_FATAL ANY
)

ctest_start(Continuous)
ctest_update()
ctest_build(RETURN_VALUE build_result)

if(EXISTS "${GUIX_BUILD_LOG}")
    list(APPEND CTEST_NOTES_FILES "${GUIX_BUILD_LOG}")
endif()

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
    list(APPEND CTEST_NOTES_FILES "${HASH_FILE}")
endif()

list(REMOVE_DUPLICATES CTEST_NOTES_FILES)
ctest_submit(PARTS Update Build Notes Done)

if(NOT build_result EQUAL 0)
    message(FATAL_ERROR "Guix build failed with exit code ${build_result}; see ${GUIX_BUILD_LOG}")
endif()

cmake_host_system_information(RESULT nproc QUERY NUMBER_OF_LOGICAL_CORES)
cmake_host_system_information(RESULT host_system_name QUERY OS_NAME)
cmake_host_system_information(RESULT host_system_processor QUERY OS_PLATFORM)
set(CTEST_BUILD_FLAGS -j${nproc})
set(ctest_test_args ${ctest_test_args} PARALLEL_LEVEL ${nproc})

# CTEST_SITE and CTEST_SOURCE_DIRECTORY are provided by the systemd service.
include("${CMAKE_CURRENT_LIST_DIR}/set-cdash-build-name.cmake")
get_filename_component(CTEST_SOURCE_DIRECTORY "${CTEST_SOURCE_DIRECTORY}" ABSOLUTE)
set(CTEST_BINARY_DIRECTORY "${CTEST_SOURCE_DIRECTORY}/build")
set(functional_ctest_binary_directory "${CTEST_SOURCE_DIRECTORY}/build-functional-ctest")
if(DEFINED ENV{CTEST_CONFIGURE_PRESET} AND NOT "$ENV{CTEST_CONFIGURE_PRESET}" STREQUAL "")
    set(ctest_configure_preset "$ENV{CTEST_CONFIGURE_PRESET}")
else()
    set(ctest_configure_preset "default")
endif()
set(nightly_presets_file "${CMAKE_CURRENT_LIST_DIR}/../CMakeUserPresets.json")
set(ctest_source_presets_file "${CTEST_SOURCE_DIRECTORY}/CMakeUserPresets.json")
file(COPY_FILE "${nightly_presets_file}" "${ctest_source_presets_file}")
find_program(CTEST_GIT_COMMAND git)
set(CTEST_UPDATE_VERSION_ONLY TRUE)
if(DEFINED ENV{CTEST_DASHBOARD_MODEL})
    set(ctest_dashboard_model "$ENV{CTEST_DASHBOARD_MODEL}")
else()
    set(ctest_dashboard_model "Nightly")
endif()

# Include this dashboard script in the submitted CDash notes.
set(CTEST_NOTES_FILES)
list(APPEND CTEST_NOTES_FILES "${CMAKE_CURRENT_LIST_FILE}")
list(APPEND CTEST_NOTES_FILES "${ctest_source_presets_file}")

set(ctest_configure_options "--preset ${ctest_configure_preset}")

ctest_start("${ctest_dashboard_model}")

# Record the current revision without updating the source worktree.
ctest_update()
ctest_submit(PARTS "Update")

ctest_configure(
    BUILD   ${CTEST_BINARY_DIRECTORY}
    SOURCE  ${CTEST_SOURCE_DIRECTORY}
    OPTIONS "${ctest_configure_options}"
)
include("${CMAKE_CURRENT_LIST_DIR}/write-build-config-note.cmake")
list(REMOVE_DUPLICATES CTEST_NOTES_FILES)
ctest_submit(PARTS "Configure" "Notes")
set(CTEST_NOTES_FILES)

ctest_build(BUILD ${CTEST_BINARY_DIRECTORY})
ctest_submit(PARTS "Build")

ctest_test(${ctest_test_args} EXCLUDE "interface_ipc")
ctest_submit(PARTS "Test")

file(MAKE_DIRECTORY "${functional_ctest_binary_directory}")
ctest_configure(
    BUILD   ${functional_ctest_binary_directory}
    SOURCE  "${CMAKE_CURRENT_LIST_DIR}/functional-ctest"
    OPTIONS "-DBITCOIN_BUILD_DIR=${CTEST_BINARY_DIRECTORY}"
)

ctest_test(BUILD ${functional_ctest_binary_directory} APPEND ${ctest_test_args})
ctest_submit(PARTS "Test")

# Submit Done last so CDash marks the build as complete.
ctest_submit(PARTS "Done")

cmake_minimum_required(VERSION 3.22)

project(BitcoinFunctionalCTest NONE)

enable_testing()

find_package(Python3 3.10 REQUIRED COMPONENTS Interpreter)

set(BITCOIN_BUILD_DIR "" CACHE PATH "Bitcoin Core build directory")
set(BITCOIN_FUNCTIONAL_EXTENDED_TESTS OFF CACHE BOOL "Register extended functional tests")
set(BITCOIN_FUNCTIONAL_TEST_TIMEOUT_FACTOR "1" CACHE STRING "Timeout factor passed to functional tests")
set(BITCOIN_FUNCTIONAL_TEST_SCRIPT_DIR "" CACHE PATH "Directory containing functional test scripts")
set(BITCOIN_FUNCTIONAL_TEST_CONFIG_FILE "" CACHE FILEPATH "Functional test config.ini")
set(BITCOIN_FUNCTIONAL_TEST_CACHE_DIR "${CMAKE_BINARY_DIR}/cache" CACHE PATH "Functional test cache directory")
set(BITCOIN_FUNCTIONAL_TEST_TMPDIR "${CMAKE_BINARY_DIR}/tmp" CACHE PATH "Functional test temporary directory root")

if(NOT BITCOIN_BUILD_DIR)
  message(FATAL_ERROR "BITCOIN_BUILD_DIR must be set to a configured Bitcoin Core build directory")
endif()

if(NOT BITCOIN_FUNCTIONAL_TEST_SCRIPT_DIR)
  set(BITCOIN_FUNCTIONAL_TEST_SCRIPT_DIR "${BITCOIN_BUILD_DIR}/test/functional")
endif()

if(NOT BITCOIN_FUNCTIONAL_TEST_CONFIG_FILE)
  set(BITCOIN_FUNCTIONAL_TEST_CONFIG_FILE "${BITCOIN_BUILD_DIR}/test/config.ini")
endif()

if(NOT EXISTS "${BITCOIN_FUNCTIONAL_TEST_SCRIPT_DIR}/test_runner.py")
  message(FATAL_ERROR "test_runner.py not found in BITCOIN_FUNCTIONAL_TEST_SCRIPT_DIR=${BITCOIN_FUNCTIONAL_TEST_SCRIPT_DIR}")
endif()

if(NOT EXISTS "${BITCOIN_FUNCTIONAL_TEST_CONFIG_FILE}")
  message(FATAL_ERROR "Functional test config file not found: ${BITCOIN_FUNCTIONAL_TEST_CONFIG_FILE}")
endif()

file(MAKE_DIRECTORY "${BITCOIN_FUNCTIONAL_TEST_TMPDIR}")

set(generated_tests "${CMAKE_BINARY_DIR}/FunctionalTests.cmake")
set(generate_tests_args
  --python "${Python3_EXECUTABLE}"
  --script-dir "${BITCOIN_FUNCTIONAL_TEST_SCRIPT_DIR}"
  --config-file "${BITCOIN_FUNCTIONAL_TEST_CONFIG_FILE}"
  --cache-dir "${BITCOIN_FUNCTIONAL_TEST_CACHE_DIR}"
  --tmpdir "${BITCOIN_FUNCTIONAL_TEST_TMPDIR}"
  --timeout-factor "${BITCOIN_FUNCTIONAL_TEST_TIMEOUT_FACTOR}"
  --output "${generated_tests}"
)
if(BITCOIN_FUNCTIONAL_EXTENDED_TESTS)
  list(APPEND generate_tests_args --extended)
endif()

execute_process(
  COMMAND
    ${Python3_EXECUTABLE}
    "${CMAKE_CURRENT_LIST_DIR}/generate-functional-tests.py"
    ${generate_tests_args}
  COMMAND_ERROR_IS_FATAL ANY
)

include("${generated_tests}")

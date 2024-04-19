#!/usr/bin/env bash

include './src/lib/kwio.sh'
include './src/lib/kwlib.sh'
include './tests/unit/utils.sh'
include './tests/integration/utils.sh'

declare -g CLONED_KERNEL_TREE_PATH_HOST
declare -g TARGET_RANDOM_DISTRO
declare -g KERNEL_TREE_PATH_CONTAINER
declare -g CONTAINER

function oneTimeSetUp()
{
  local url_kernel_repo_tree='https://github.com/torvalds/linux'

  # Select a random distro for the tests
  TARGET_RANDOM_DISTRO=$(select_random_distro)
  CLONED_KERNEL_TREE_PATH_HOST="$(mktemp --directory)/linux"
  CONTAINER="kw-${TARGET_RANDOM_DISTRO}"

  # The VERBOSE variable is set and exported in the run_tests.sh script based
  # on the command-line options provided by the user. It controls the verbosity
  # of the output during the test runs.
  setup_container_environment "$VERBOSE" 'build' "$TARGET_RANDOM_DISTRO"

  # Install kernel build dependencies
  container_exec "$CONTAINER" 'yes | ./setup.sh --install-kernel-dev-deps > /dev/null 2>&1'
  if [[ "$?" -ne 0 ]]; then
    complain "Failed to install kernel build dependencies for ${TARGET_RANDOM_DISTRO}"
    return 22 # EINVAL
  fi

  git clone --quiet --depth 5 "$url_kernel_repo_tree" "$CLONED_KERNEL_TREE_PATH_HOST"
  if [[ "$?" -ne 0 ]]; then
    complain "Failed to clone ${url_kernel_repo_tree}"
    if [[ -n "$CLONED_KERNEL_TREE_PATH_HOST" ]]; then
      if is_safe_path_to_remove "$CLONED_KERNEL_TREE_PATH_HOST"; then
        rm --recursive --force "$CLONED_KERNEL_TREE_PATH_HOST"
      else
        complain "Unsafe path: ${CLONED_KERNEL_TREE_PATH_HOST} - Not removing"
      fi
    fi
  fi
}

function setUp()
{
  KERNEL_TREE_PATH_CONTAINER="$(container_exec "$CONTAINER" 'mktemp --directory')/linux"
  if [[ "$?" -ne 0 ]]; then
    fail "(${LINENO}): Failed to create temporary directory in container."
  fi

  setup_kernel_tree_with_config_file "$CONTAINER"
}

function tearDown()
{
  container_exec "$CONTAINER" "cd ${KERNEL_TREE_PATH_CONTAINER} && kw build --full-cleanup > /dev/null 2>&1"
  assert_equals_helper "kw build --clean failed for ${CONTAINER}" "(${LINENO})" 0 "$?"
}

# shellcheck disable=SC2317
function oneTimeTearDown()
{
  if [[ -n "$CLONED_KERNEL_TREE_PATH_HOST" ]]; then
    if is_safe_path_to_remove "$CLONED_KERNEL_TREE_PATH_HOST"; then
      rm --recursive --force "$CLONED_KERNEL_TREE_PATH_HOST"
    fi
  fi
}

function setup_kernel_tree_with_config_file()
{
  container_copy "$CONTAINER" "$CLONED_KERNEL_TREE_PATH_HOST" "$KERNEL_TREE_PATH_CONTAINER"
  if [[ "$?" -ne 0 ]]; then
    fail "(${LINENO}): Failed to copy ${CLONED_KERNEL_TREE_PATH_HOST} to ${CONTAINER}:${KERNEL_TREE_PATH_CONTAINER}"
  fi

  optimize_dot_config "$CONTAINER" "$KERNEL_TREE_PATH_CONTAINER"
}

# Optimize the .config file in a container.
#
# @container                   The ID or name of the container.
# @KERNEL_TREE_PATH_CONTAINER  The temporary directory in the container to use for intermediate files.
function optimize_dot_config()
{
  # Generate a list of currently loaded modules in the container
  container_exec "$CONTAINER" "cd ${KERNEL_TREE_PATH_CONTAINER} && /usr/sbin/lsmod > container_mod_list"
  if [[ "$?" -ne 0 ]]; then
    fail "(${LINENO}): Failed to generate module list in container."
  fi

  # Create a default configuration and then update it to reflect current settings
  container_exec "$CONTAINER" "cd ${KERNEL_TREE_PATH_CONTAINER} && make defconfig > /dev/null 2>&1 && make olddefconfig > /dev/null 2>&1"
  if [[ "$?" -ne 0 ]]; then
    fail "(${LINENO}): Failed to create default configuration in container."
  fi

  # Optimize the configuration based on the currently loaded modules
  container_exec "$CONTAINER" "cd ${KERNEL_TREE_PATH_CONTAINER} && make LSMOD=${KERNEL_TREE_PATH_CONTAINER}/container_mod_list localmodconfig > /dev/null 2>&1"
  if [[ "$?" -ne 0 ]]; then
    fail "(${LINENO}): Failed to optimize configuration based on loaded modules in container."
  fi
}

function test_kernel_build_gcc_x86_64_no_env()
{
  local kw_build_cmd
  local build_type_string
  local build_result_status
  local raw_build_log_from_db

  kw_build_cmd='kw build'
  container_exec "$CONTAINER" "cd ${KERNEL_TREE_PATH_CONTAINER} && ${kw_build_cmd} > /dev/null 2>&1"
  assert_equals_helper "kw build failed for ${CONTAINER}" "(${LINENO})" 0 "$?"

  # Verify kernel binary exists
  kernel_binary_path=$(container_exec "$CONTAINER" "find ${KERNEL_TREE_PATH_CONTAINER}/arch/x86/boot/ -type f -name 'bzImage'")

  if [[ -z "$kernel_binary_path" ]]; then
    assert_equals_helper "Kernel binary not found for ${CONTAINER}" "$LINENO" '0' '1'
  fi

  # Retrieve the build status log from the database
  raw_build_log_from_db=$(container_exec "$CONTAINER" "sqlite3 ~/.local/share/kw/kw.db \"SELECT * FROM statistics_report\" | tail --lines=1")

  # Extract the build status and result from the log
  build_type_string=$(printf '%s' "$raw_build_log_from_db" | cut --delimiter='|' --fields=2)
  assert_equals_helper "Build status check failed for ${CONTAINER}" "$LINENO" 'build' "$build_type_string"

  build_result_status=$(printf '%s' "$raw_build_log_from_db" | cut --delimiter='|' --fields=3)
  assert_equals_helper "Build result check failed for ${CONTAINER}" "$LINENO" 'success' "$build_result_status"
}

function test_kw_build_cpu_scaling_execution()
{
  local cpu_scaling_percentage=50

  # Execute the test script inside the container
  # The test script will run the kw build command with the --cpu-scaling 50 option
  container_exec "$CONTAINER" "cd ${KERNEL_TREE_PATH_CONTAINER} && kw_build_cpu_scaling_monitor ${cpu_scaling_percentage} > /dev/null 2>&1"
  assert_equals_helper "kw build --cpu-scaling 50 failed for ${CONTAINER}" "(${LINENO})" 0 "$?"

  # For more details about this test, check the file:
  # tests/integration/podman/scripts/kw_build_cpu_scaling_monitor
}

function test_kernel_build_llvm()
{
  local kw_build_cmd
  local build_type_string
  local build_result_status
  local raw_build_log_from_db

  kw_build_cmd='kw build --llvm'
  container_exec "$CONTAINER" "cd ${KERNEL_TREE_PATH_CONTAINER} && ${kw_build_cmd} > /dev/null 2>&1"
  assert_equals_helper "kw build failed for ${CONTAINER}" "(${LINENO})" 0 "$?"

  # Retrieve the build status log from the database
  raw_build_log_from_db=$(container_exec "$CONTAINER" "sqlite3 ~/.local/share/kw/kw.db \"SELECT * FROM statistics_report\" | tail --lines=1")

  # Extract the build status and result from the log
  build_type_string=$(printf '%s' "$raw_build_log_from_db" | cut --delimiter='|' --fields=2)
  assert_equals_helper "Build status check failed for ${CONTAINER}" "$LINENO" 'build' "$build_type_string"

  build_result_status=$(printf '%s' "$raw_build_log_from_db" | cut --delimiter='|' --fields=3)
  assert_equals_helper "Build result check failed for ${CONTAINER}" "$LINENO" 'success' "$build_result_status"
}

invoke_shunit

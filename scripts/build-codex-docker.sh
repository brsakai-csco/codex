#!/usr/bin/env bash

set -euo pipefail

if ! command -v flock >/dev/null 2>&1; then
  echo "flock is required to prevent concurrent Docker builds" >&2
  exit 1
fi

exec 9<"$0"
if ! flock -n 9; then
  echo "another build-codex-docker.sh invocation is already running" >&2
  exit 1
fi

usage() {
  cat >&2 <<'EOF'
Usage: scripts/build-codex-docker.sh [--debug] [--no-test] [--all-tests] [--platform linux/amd64|linux/arm64]

Builds the codex binary in the repo's contributor Docker image, runs focused
regression tests by default, then installs it at ~/bin/codex.

Options:
  --debug       Build the debug profile instead of the release profile.
  --no-test     Skip regression tests.
  --all-tests   Run the full Rust test suite instead of codex-cli tests.
  --platform    Docker platform to build and run. Defaults to linux/amd64.
  -h, --help    Show this help.

Environment:
  CODEX_DOCKER_IMAGE_NAME  Docker image tag. Defaults to codex-linux-dev.
  CODEX_DOCKER_CACHE_DIR  Cache directory. Defaults to ../.codex-docker-cache.
EOF
}

profile="release"
platform="linux/amd64"
test_mode="focused"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      profile="debug"
      shift
      ;;
    --no-test)
      test_mode="none"
      shift
      ;;
    --all-tests)
      test_mode="all"
      shift
      ;;
    --platform)
      if [[ $# -lt 2 ]]; then
        echo "--platform requires a value" >&2
        exit 2
      fi
      platform="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

case "${platform}" in
  linux/amd64)
    target_dir="/workspace/codex-rs/target-amd64"
    ;;
  linux/arm64)
    target_dir="/workspace/codex-rs/target-arm64"
    ;;
  *)
    echo "unsupported platform: ${platform}" >&2
    exit 2
    ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "run this script from inside the codex git repository" >&2
  exit 1
}

image_name="${CODEX_DOCKER_IMAGE_NAME:-codex-linux-dev}"
platform_suffix="${platform#linux/}"
cache_root="${CODEX_DOCKER_CACHE_DIR:-$(dirname "${repo_root}")/.codex-docker-cache/${platform_suffix}}"
cargo_home="${cache_root}/cargo"
rustup_home="${cache_root}/rustup"
home_cache="${cache_root}/home"
mkdir -p "${cargo_home}" "${rustup_home}" "${home_cache}" "${repo_root}/codex-rs/${target_dir#/workspace/codex-rs/}"

docker build \
  --platform="${platform}" \
  --build-arg "USER_UID=$(id -u)" \
  --build-arg "USER_GID=$(id -g)" \
  -t "${image_name}" \
  "${repo_root}/.devcontainer"

cargo_args=(build -p codex-cli --bin codex)
if [[ "${profile}" == "release" ]]; then
  cargo_args+=(--release)
fi

docker_run_args=(
  --platform="${platform}"
  --rm
  -e "CARGO_TARGET_DIR=${target_dir}"
  -e "CARGO_HOME=/cache/cargo"
  -e "HOME=/cache/home"
  -e "RUSTUP_HOME=/cache/rustup"
  -v "${cargo_home}:/cache/cargo"
  -v "${rustup_home}:/cache/rustup"
  -v "${home_cache}:/cache/home"
  -v "${repo_root}:/workspace"
  -w /workspace/codex-rs
  "${image_name}"
)
if [[ -t 0 && -t 1 ]]; then
  docker_run_args+=(-it)
fi

docker run "${docker_run_args[@]}" cargo "${cargo_args[@]}"

case "${test_mode}" in
  focused)
    # Keep focused tests aligned with the package under active development.
    # The exclusions below are Docker-hostile in this personal fork's Ubuntu
    # 22.04 container. Keep the broad codex-core coverage, and add/remove
    # exclusions here as the Docker environment changes.
    codex_core_filter='package(codex-core)'
    codex_core_filter+=' & not test(suite::cli_stream::)'
    codex_core_filter+=' & not test(suite::code_mode::)'
    codex_core_filter+=' & not test(suite::hooks_mcp::)'
    codex_core_filter+=' & not test(suite::rmcp_client::)'
    codex_core_filter+=' & not test(suite::approvals::)'
    codex_core_filter+=' & not test(suite::plugins::)'
    codex_core_filter+=' & not test(suite::search_tool::)'
    codex_core_filter+=' & not test(suite::request_permissions::)'
    codex_core_filter+=' & not test(suite::network_approval::guardian_receives_exact_trigger_for_single_network_request)'
    codex_core_filter+=' & not test(suite::network_approval::guardian_receives_exact_triggers_for_concurrent_network_requests)'
    codex_core_filter+=' & not test(suite::network_approval::allowing_network_policy_amendment_persists_context_and_bypasses_prompt)'
    codex_core_filter+=' & not test(suite::network_approval::user_network_approval_once_session_and_denial_semantics)'
    codex_core_filter+=' & not test(suite::network_approval::guardian_network_approval_preserves_action_and_outcome_routing)'
    codex_core_filter+=' & not test(suite::network_approval::cancelled_guardian_network_review_fails_closed_without_rewriting_turn_state)'
    codex_core_filter+=' & not test(suite::network_approval::timed_out_guardian_network_review_uses_timeout_outcome_without_user_fallback)'
    codex_core_filter+=' & not test(suite::network_approval::ambiguous_unattributed_network_request_is_not_assigned_to_active_calls)'
    codex_core_filter+=' & not test(suite::extension_sandbox::)'
    codex_core_filter+=' & not test(suite::sqlite_state::)'
    codex_core_filter+=' & not test(suite::token_budget::)'
    codex_core_filter+=' & not test(suite::truncation::)'
    codex_core_filter+=' & not test(suite::apply_patch_cli::apply_patch_cli_preserves_existing_hard_link_outside_workspace)'
    codex_core_filter+=' & not test(suite::apply_patch_cli::apply_patch_cli_rejects_move_path_traversal_outside_workspace)'
    codex_core_filter+=' & not test(suite::hooks::permission_request_hook_allows_network_approval_without_prompt)'
    codex_core_filter+=' & not test(suite::hooks::permission_request_hook_denies_network_approval_with_custom_message)'
    codex_core_filter+=' & not test(suite::workspace_roots::workspace_roots_allow_file_and_command_writes)'
    codex_core_filter+=' & not test(suite::workspace_roots::workspace_roots_deny_file_and_command_writes_outside_roots)'
    codex_core_filter+=' & not test(suite::tools::shell_command_enforces_glob_deny_read_policy)'
    codex_core_filter+=' & not test(suite::tools::sandbox_denied_shell_command_returns_original_output)'
    codex_core_filter+=' & not test(suite::unified_exec::unified_exec_runs_under_sandbox)'
    codex_core_filter+=' & not test(suite::unified_exec::unified_exec_enforces_glob_deny_read_policy)'
    codex_core_filter+=' & not test(suite::unified_exec::unified_exec_short_lived_network_denial_emits_failed_end_event)'
    codex_core_filter+=' & not test(suite::unified_exec::unified_exec_network_denial_emits_failed_background_end_event)'
    codex_core_filter+=' & not test(suite::multi_exec_server_sandbox::two_exec_servers_isolate_workspace_write_roots)'
    codex_core_filter+=' & not test(exec::tests::process_exec_tool_call_cancellation_allows_sigterm_cleanup)'
    codex_core_filter+=' & not test(exec::tests::kill_child_process_group_kills_grandchildren_on_timeout)'
    codex_core_filter+=' & not test(image_preparation::tests::detail_policies_apply_the_expected_budgets)'
    tui_filter='package(codex-tui)'
    tui_filter+=' & not test(status::tests::status_snapshot_includes_enterprise_monthly_credit_limit)'
    tui_filter+=' & not test(status::tests::status_snapshot_wraps_enterprise_monthly_credit_details_in_narrow_terminal)'
    test_args=(test -E "(${codex_core_filter}) | (${tui_filter})")
    ;;
  all)
    test_args=(test)
    ;;
  none)
    test_args=()
    ;;
esac

if [[ "${test_mode}" != "none" ]]; then
  docker run "${docker_run_args[@]}" just "${test_args[@]}"
fi

if [[ "${profile}" == "release" ]]; then
  binary_path="codex-rs/${target_dir#/workspace/codex-rs/}/release/codex"
else
  binary_path="codex-rs/${target_dir#/workspace/codex-rs/}/debug/codex"
fi

bin_path="${HOME}/bin/codex"
rm -f "${bin_path}"
cp "${repo_root}/${binary_path}" "${bin_path}"

echo "Built ${binary_path}"
echo "Installed ${bin_path}"

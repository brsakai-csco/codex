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
regression tests by default, then installs it and codex-code-mode-host at
~/bin.

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
    rust_target="x86_64-unknown-linux-gnu"
    ;;
  linux/arm64)
    target_dir="/workspace/codex-rs/target-arm64"
    rust_target="aarch64-unknown-linux-gnu"
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
v8_cache_dir="${cache_root}/rusty-v8"
mkdir -p "${cargo_home}" "${rustup_home}" "${home_cache}" "${v8_cache_dir}" "${repo_root}/codex-rs/${target_dir#/workspace/codex-rs/}"

docker build \
  --platform="${platform}" \
  --build-arg "USER_UID=$(id -u)" \
  --build-arg "USER_GID=$(id -g)" \
  -t "${image_name}" \
  "${repo_root}/.devcontainer"

v8_version="$(awk '
  $0 == "name = \"v8\"" { found = 1; next }
  found && /^version = / {
    gsub(/"/, "", $3)
    print $3
    exit
  }
' "${repo_root}/codex-rs/Cargo.lock")"
if [[ -z "${v8_version}" ]]; then
  echo "could not determine the v8 crate version from codex-rs/Cargo.lock" >&2
  exit 1
fi
v8_release_url="https://github.com/openai/codex/releases/download/rusty-v8-v${v8_version}"
v8_profile="ptrcomp_sandbox_release"
v8_archive_name="librusty_v8_${v8_profile}_${rust_target}.a.gz"
v8_binding_name="src_binding_${v8_profile}_${rust_target}.rs"
v8_checksums_name="rusty_v8_${v8_profile}_${rust_target}.sha256"

docker run \
  --platform="${platform}" \
  --rm \
  -e "V8_RELEASE_URL=${v8_release_url}" \
  -e "V8_ARCHIVE_NAME=${v8_archive_name}" \
  -e "V8_BINDING_NAME=${v8_binding_name}" \
  -e "V8_CHECKSUMS_NAME=${v8_checksums_name}" \
  -v "${v8_cache_dir}:/cache/rusty-v8" \
  "${image_name}" \
  bash -c '
    set -euo pipefail
    for artifact in "${V8_ARCHIVE_NAME}" "${V8_BINDING_NAME}" "${V8_CHECKSUMS_NAME}"; do
      if [[ ! -s "/cache/rusty-v8/${artifact}" ]]; then
        curl -fsSL "${V8_RELEASE_URL}/${artifact}" -o "/cache/rusty-v8/${artifact}"
      fi
    done
    if [[ "$(wc -l < "/cache/rusty-v8/${V8_CHECKSUMS_NAME}")" -ne 2 ]]; then
      echo "expected exactly two V8 checksums" >&2
      exit 1
    fi
    cd /cache/rusty-v8
    tr -d "\r" < "${V8_CHECKSUMS_NAME}" | sha256sum -c -
  '

cargo_args=(build -p codex-cli --bin codex -p codex-code-mode-host --bin codex-code-mode-host)
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
  -e "RUSTY_V8_ARCHIVE=/cache/rusty-v8/${v8_archive_name}"
  -e "RUSTY_V8_SRC_BINDING_PATH=/cache/rusty-v8/${v8_binding_name}"
  -v "${cargo_home}:/cache/cargo"
  -v "${rustup_home}:/cache/rustup"
  -v "${home_cache}:/cache/home"
  -v "${v8_cache_dir}:/cache/rusty-v8"
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
    codex_core_filter+=' & not test(tools::handlers::multi_agents::tests::multi_agent_v2_wait_agent_clamps_timeout_below_configured_min)'
    codex_core_filter+=' & not test(suite::agents_md::restricted_project_without_instructions_starts_successfully)'
    codex_core_filter+=' & not test(suite::guardian_review::guardian_session_is_reused_for_consecutive_tool_reviews_without_prewarm)'
    codex_core_filter+=' & not test(suite::hooks::async_hook_finishing_while_idle_waits_for_the_next_turn)'
    codex_core_filter+=' & not test(suite::network_approval::failed_network_policy_amendment_denies_request_and_does_not_approve_host)'
    codex_core_filter+=' & not test(suite::network_approval::denying_network_policy_amendment_persists_and_blocks_request)'
    codex_core_filter+=' & not test(suite::network_approval::strict_auto_review_routes_network_approval_to_guardian_when_user_reviewer_is_selected)'
    codex_core_filter+=' & not test(suite::network_approval::background_network_approval_uses_active_turn_after_original_turn_completes)'
    codex_core_filter+=' & not test(suite::network_approval::disconnected_network_request_explains_failure_to_model::plain_http)'
    codex_core_filter+=' & not test(suite::network_approval::disconnected_network_request_explains_failure_to_model::connect)'
    codex_core_filter+=' & not test(suite::network_approval::latest_network_rejection_wins_for_multiple_reviews_of_one_execution)'
    codex_core_filter+=' & not test(suite::openai_file_mcp::codex_apps_file_params_reject_denied_file_before_upload)'
    codex_core_filter+=' & not test(suite::openai_file_mcp::codex_apps_file_params_stream_allowed_file_under_restricted_read_policy)'
    codex_core_filter+=' & not test(suite::remote_env::environment_permissions_follow_configuration_ownership)'
    codex_core_filter+=' & not test(suite::cloud_config::managed_deny_read_requirements_follow_thread_permission_updates)'
    codex_core_filter+=' & not test(suite::view_image::view_image_tool_applies_local_sandbox_read_denies)'
    codex_core_filter+=' & not test(suite::apply_patch_cli::apply_patch_cli_does_not_write_through_symlink_escape_outside_workspace)'
    codex_core_filter+=' & not test(suite::workspace_roots::workspace_roots_allow_apply_patch_in_secondary_root)'
    codex_core_filter+=' & not test(suite::workspace_roots::workspace_roots_allow_patches_but_protect_metadata_directories)'
    codex_core_filter+=' & not test(suite::apply_patch_cli::escalated_patch_rejects_symlink_swapped_after_approval_request)'
    codex_core_filter+=' & not test(suite::apply_patch_cli::intercepted_apply_patch_verification_uses_local_sandbox)'
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
    codex_core_filter+=' & not test(suite::tools::exec_command_enforces_glob_deny_read_policy)'
    codex_core_filter+=' & not test(suite::tools::sandbox_denied_exec_command_returns_original_output)'
    codex_core_filter+=' & not test(suite::unified_exec::unified_exec_runs_under_sandbox)'
    codex_core_filter+=' & not test(suite::unified_exec::unified_exec_enforces_glob_deny_read_policy)'
    codex_core_filter+=' & not test(suite::unified_exec::unified_exec_short_lived_network_denial_emits_failed_end_event)'
    codex_core_filter+=' & not test(suite::unified_exec::unified_exec_network_denial_emits_failed_background_end_event)'
    codex_core_filter+=' & not test(suite::multi_exec_server_sandbox::two_exec_servers_isolate_workspace_write_roots)'
    codex_core_filter+=' & not test(exec::tests::process_exec_tool_call_cancellation_allows_sigterm_cleanup)'
    codex_core_filter+=' & not test(exec::tests::kill_child_process_group_kills_grandchildren_on_timeout)'
    codex_core_filter+=' & not test(image_preparation::tests::detail_policies_apply_the_expected_budgets)'
    codex_core_filter+=' & not test(suite::compact_remote::remote_compact_v2_charges_retained_images_to_token_budget)'
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
  code_mode_host_path="codex-rs/${target_dir#/workspace/codex-rs/}/release/codex-code-mode-host"
else
  binary_path="codex-rs/${target_dir#/workspace/codex-rs/}/debug/codex"
  code_mode_host_path="codex-rs/${target_dir#/workspace/codex-rs/}/debug/codex-code-mode-host"
fi

bin_path="${HOME}/bin/codex"
code_mode_host_bin_path="${HOME}/bin/codex-code-mode-host"
rm -f "${bin_path}"
cp "${repo_root}/${binary_path}" "${bin_path}"
rm -f "${code_mode_host_bin_path}"
cp "${repo_root}/${code_mode_host_path}" "${code_mode_host_bin_path}"

echo "Built ${binary_path}"
echo "Installed ${bin_path}"
echo "Built ${code_mode_host_path}"
echo "Installed ${code_mode_host_bin_path}"

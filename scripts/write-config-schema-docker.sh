#!/usr/bin/env bash

set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "run this script from inside the codex git repository" >&2
  exit 1
}

image_name="${CODEX_DOCKER_IMAGE_NAME:-codex-linux-dev}"
cache_root="${CODEX_DOCKER_CACHE_DIR:-$(dirname "${repo_root}")/.codex-docker-cache/amd64}"

mkdir -p "${cache_root}/cargo" "${cache_root}/rustup" "${cache_root}/home"

docker run \
  --platform=linux/amd64 \
  --rm \
  -e CARGO_TARGET_DIR=/workspace/codex-rs/target-amd64 \
  -e CARGO_HOME=/cache/cargo \
  -e HOME=/cache/home \
  -e RUSTUP_HOME=/cache/rustup \
  -v "${cache_root}/cargo:/cache/cargo" \
  -v "${cache_root}/rustup:/cache/rustup" \
  -v "${cache_root}/home:/cache/home" \
  -v "${repo_root}:/workspace" \
  -w /workspace/codex-rs \
  "${image_name}" \
  just write-config-schema

#!/usr/bin/env bash
set -euo pipefail
export SHELLOPTS

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
project_dir="$(dirname "$script_dir")"
bin_dir="${PROJECT_BIN_DIR:-$project_dir/bin}"
force_reinstall="${FORCE_REINSTALL_BINARIES:-}"
github_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
download_retry_count="${DOWNLOAD_RETRY_COUNT:-12}"
download_retry_delay_seconds="${DOWNLOAD_RETRY_DELAY_SECONDS:-5}"
download_connect_timeout_seconds="${DOWNLOAD_CONNECT_TIMEOUT_SECONDS:-60}"

default_ckb_version="v0.205.0"
default_ckb_cli_version="v2.0.0"
default_fnn_version="v0.8.0-rc1"

download_root="$(mktemp -d "${TMPDIR:-/tmp}/ckb-chat-binaries.XXXXXX")"
trap 'rm -rf "$download_root"' EXIT INT TERM

mkdir -p "$bin_dir"

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required to download release binaries" >&2
    exit 1
  fi
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

command_path() {
  command -v "$1" 2>/dev/null || true
}

require_command curl
require_command tar
require_command unzip

normalize_os() {
  case "$(uname -s)" in
    Darwin)
      printf 'darwin\n'
      ;;
    Linux)
      printf 'linux\n'
      ;;
    *)
      echo "unsupported operating system: $(uname -s)" >&2
      exit 1
      ;;
  esac
}

normalize_arch() {
  case "$(uname -m)" in
    arm64|aarch64)
      printf 'aarch64\n'
      ;;
    x86_64|amd64)
      printf 'x86_64\n'
      ;;
    *)
      echo "unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

host_os="$(normalize_os)"
host_arch="$(normalize_arch)"

version_to_tag() {
  local version="$1"
  if [[ "$version" = v* ]]; then
    printf '%s\n' "$version"
  else
    printf 'v%s\n' "$version"
  fi
}

resolve_latest_release_tag_including_prereleases() {
  local repo="$1"
  local fallback_tag="$2"
  local resolved_tag=""

  if has_command gh; then
    if [ -n "$github_token" ]; then
      resolved_tag="$(
        GH_TOKEN="$github_token" GH_PROMPT_DISABLED=1 \
          gh api "repos/$repo/releases" --jq '.[] | select(.draft == false) | .tag_name' 2>/dev/null | head -n 1 || true
      )"
    else
      resolved_tag="$(
        GH_PROMPT_DISABLED=1 \
          gh api "repos/$repo/releases" --jq '.[] | select(.draft == false) | .tag_name' 2>/dev/null | head -n 1 || true
      )"
    fi
  fi

  if [ -z "$resolved_tag" ]; then
    resolved_tag="$fallback_tag"
  fi

  printf '%s\n' "$resolved_tag"
}

download_asset() {
  local url="$1"
  local output_path="$2"
  local -a curl_args=(
    -fL
    --retry "$download_retry_count"
    --retry-delay "$download_retry_delay_seconds"
    --retry-all-errors
    --connect-timeout "$download_connect_timeout_seconds"
    -A "ckb-chat-installer"
    -H "Accept: application/octet-stream"
    -o "$output_path"
  )

  rm -f "$output_path"

  if [ -t 2 ]; then
    curl_args+=(--progress-bar)
  else
    curl_args+=(-sS)
  fi

  if [ -n "$github_token" ]; then
    curl_args+=(-H "Authorization: Bearer $github_token")
    curl "${curl_args[@]}" "$url"
    return 0
  fi

  curl "${curl_args[@]}" "$url"
}

download_asset_with_gh() {
  local repo="$1"
  local tag="$2"
  local asset_name="$3"
  local output_path="$4"
  local gh_download_dir
  local gh_asset_path

  if ! has_command gh; then
    return 1
  fi

  gh_download_dir="$download_root/gh-download-$asset_name"
  rm -rf "$gh_download_dir"
  mkdir -p "$gh_download_dir"

  if [ -n "$github_token" ]; then
    GH_TOKEN="$github_token" GH_PROMPT_DISABLED=1 \
      gh release download "$tag" -R "$repo" -p "$asset_name" -D "$gh_download_dir" >/dev/null 2>&1
  else
    GH_PROMPT_DISABLED=1 \
      gh release download "$tag" -R "$repo" -p "$asset_name" -D "$gh_download_dir" >/dev/null 2>&1
  fi

  gh_asset_path="$gh_download_dir/$asset_name"
  if [ ! -f "$gh_asset_path" ]; then
    return 1
  fi

  mv "$gh_asset_path" "$output_path"
}

extract_archive() {
  local archive_path="$1"
  local destination_dir="$2"

  case "$archive_path" in
    *.tar.gz)
      tar -xzf "$archive_path" -C "$destination_dir"
      ;;
    *.zip)
      unzip -oq "$archive_path" -d "$destination_dir"
      ;;
    *)
      echo "unsupported archive format: $archive_path" >&2
      return 1
      ;;
  esac
}

find_extracted_binary() {
  local expected_name="$1"
  local extract_dir="$2"
  local found_path

  found_path="$(find "$extract_dir" -type f -name "$expected_name" | head -n 1 || true)"
  if [ -z "$found_path" ]; then
    echo "unable to locate $expected_name after extracting archive" >&2
    return 1
  fi

  printf '%s\n' "$found_path"
}

verify_binary() {
  local binary_name="$1"
  local binary_path="$2"

  if "$binary_path" --version >/dev/null 2>&1; then
    return 0
  fi

  echo "installed $binary_name but failed to execute '$binary_path --version'" >&2
  if [ "$binary_name" = "fnn" ] && [ "$host_os" = "darwin" ] && [ "$host_arch" = "aarch64" ]; then
    echo "Fiber official release currently only provides x86_64 macOS fnn. Please install Rosetta 2, or provide a native fnn manually." >&2
  fi
  return 1
}

existing_binary_is_usable() {
  local binary_name="$1"
  local binary_path="$2"

  if [ ! -x "$binary_path" ]; then
    return 1
  fi

  if "$binary_path" --version >/dev/null 2>&1; then
    echo "using existing $binary_name: $binary_path"
    return 0
  fi

  echo "existing $binary_name failed '$binary_path --version', reinstalling..." >&2
  return 1
}

effective_binary_path() {
  local binary_name="$1"
  local preferred_path="$2"
  local system_binary_path

  if existing_binary_is_usable "$binary_name" "$preferred_path" >/dev/null 2>&1; then
    printf '%s\n' "$preferred_path"
    return 0
  fi

  system_binary_path="$(command_path "$binary_name")"
  if [ -n "$system_binary_path" ]; then
    printf '%s\n' "$system_binary_path"
    return 0
  fi

  return 1
}

print_binary_summary() {
  local binary_name="$1"
  local preferred_path="$2"
  local resolved_path

  if ! resolved_path="$(effective_binary_path "$binary_name" "$preferred_path")"; then
    echo "$binary_name -> missing"
    return 1
  fi

  if [ "$resolved_path" = "$preferred_path" ]; then
    ls -l "$resolved_path"
  else
    echo "$binary_name -> $resolved_path"
  fi
}

ckb_asset_candidates() {
  local tag="$1"

  case "$host_os/$host_arch" in
    darwin/aarch64)
      printf 'ckb_%s_aarch64-apple-darwin-portable.zip\n' "$tag"
      printf 'ckb_%s_aarch64-apple-darwin.zip\n' "$tag"
      ;;
    darwin/x86_64)
      printf 'ckb_%s_x86_64-apple-darwin-portable.zip\n' "$tag"
      printf 'ckb_%s_x86_64-apple-darwin.zip\n' "$tag"
      ;;
    linux/aarch64)
      printf 'ckb_%s_aarch64-unknown-linux-gnu.tar.gz\n' "$tag"
      ;;
    linux/x86_64)
      printf 'ckb_%s_x86_64-unknown-linux-gnu-portable.tar.gz\n' "$tag"
      printf 'ckb_%s_x86_64-unknown-linux-gnu.tar.gz\n' "$tag"
      printf 'ckb_%s_x86_64-unknown-centos-gnu-portable.tar.gz\n' "$tag"
      printf 'ckb_%s_x86_64-unknown-centos-gnu.tar.gz\n' "$tag"
      ;;
    *)
      return 1
      ;;
  esac
}

ckb_cli_asset_candidates() {
  local tag="$1"

  case "$host_os/$host_arch" in
    darwin/aarch64)
      printf 'ckb-cli_%s_aarch64-apple-darwin.zip\n' "$tag"
      ;;
    darwin/x86_64)
      printf 'ckb-cli_%s_x86_64-apple-darwin.zip\n' "$tag"
      ;;
    linux/aarch64)
      printf 'ckb-cli_%s_aarch64-unknown-linux-gnu.tar.gz\n' "$tag"
      ;;
    linux/x86_64)
      printf 'ckb-cli_%s_x86_64-unknown-linux-gnu.tar.gz\n' "$tag"
      printf 'ckb-cli_%s_x86_64-unknown-centos-gnu.tar.gz\n' "$tag"
      ;;
    *)
      return 1
      ;;
  esac
}

fnn_asset_candidates() {
  local tag="$1"

  case "$host_os/$host_arch" in
    darwin/aarch64)
      echo "macOS currently uses the official x86_64-darwin-portable fnn release by default." >&2
      printf 'fnn_%s-x86_64-darwin-portable.tar.gz\n' "$tag"
      ;;
    darwin/x86_64)
      printf 'fnn_%s-x86_64-darwin-portable.tar.gz\n' "$tag"
      ;;
    linux/x86_64)
      printf 'fnn_%s-x86_64-linux-portable.tar.gz\n' "$tag"
      printf 'fnn_%s-x86_64-linux.tar.gz\n' "$tag"
      ;;
    linux/aarch64)
      printf 'fnn_%s-aarch64-linux-portable.tar.gz\n' "$tag"
      ;;
    *)
      return 1
      ;;
  esac
}

install_from_github_release() {
  local binary_name="$1"
  local target_path="$2"
  local repo="$3"
  local version="$4"
  shift 4

  local candidate_builder="$1"
  local tag
  local asset_candidates=()
  local asset_name
  local selected_asset=""
  local download_url=""
  local archive_path=""
  local extract_dir
  local source_path

  if [ -z "$force_reinstall" ] && existing_binary_is_usable "$binary_name" "$target_path"; then
    return 0
  fi

  tag="$(version_to_tag "$version")"

  while IFS= read -r asset_name; do
    if [ -n "$asset_name" ]; then
      asset_candidates+=("$asset_name")
    fi
  done < <("$candidate_builder" "$tag")

  if [ "${#asset_candidates[@]}" -eq 0 ]; then
    echo "no asset candidates available for $binary_name on $host_os/$host_arch" >&2
    return 1
  fi

  for asset_name in "${asset_candidates[@]}"; do
    download_url="https://github.com/$repo/releases/download/$tag/$asset_name"
    archive_path="$download_root/$asset_name"
    echo "downloading $binary_name from $download_url"
    if download_asset "$download_url" "$archive_path"; then
      selected_asset="$asset_name"
      break
    fi

    if download_asset_with_gh "$repo" "$tag" "$asset_name" "$archive_path"; then
      echo "curl download failed, recovered via gh release download for $asset_name"
      selected_asset="$asset_name"
      break
    fi

    rm -f "$archive_path"
  done

  if [ -z "$selected_asset" ]; then
    echo "failed to download a matching release asset for $binary_name from $repo $tag" >&2
    printf 'tried assets:\n' >&2
    for asset_name in "${asset_candidates[@]}"; do
      printf -- '- %s\n' "$asset_name" >&2
    done
    return 1
  fi

  extract_dir="$download_root/extract-$binary_name"
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  extract_archive "$archive_path" "$extract_dir"
  if ! source_path="$(find_extracted_binary "$binary_name" "$extract_dir")"; then
    return 1
  fi

  mkdir -p "$(dirname "$target_path")"
  cp -f "$source_path" "$target_path"
  chmod +x "$target_path"
  if ! verify_binary "$binary_name" "$target_path"; then
    rm -f "$target_path"
    return 1
  fi

  echo "installed $binary_name -> $target_path (from $repo $tag / $selected_asset)"
}

install_or_use_system_binary() {
  local binary_name="$1"
  local target_path="$2"
  local repo="$3"
  local version="$4"
  local candidate_builder="$5"
  local system_binary_path

  if [ -z "$force_reinstall" ] && existing_binary_is_usable "$binary_name" "$target_path"; then
    return 0
  fi

  system_binary_path="$(command_path "$binary_name")"
  if [ -n "$system_binary_path" ] && [ -z "$force_reinstall" ]; then
    echo "using system $binary_name from PATH: $system_binary_path"
    return 0
  fi

  install_from_github_release \
    "$binary_name" \
    "$target_path" \
    "$repo" \
    "$version" \
    "$candidate_builder"
}

ckb_version="$(version_to_tag "${CKB_VERSION:-$default_ckb_version}")"
ckb_cli_version="$(version_to_tag "${CKB_CLI_VERSION:-$default_ckb_cli_version}")"
if [ -n "${FNN_VERSION:-}" ]; then
  fnn_version="$(version_to_tag "$FNN_VERSION")"
else
  fnn_version="$(resolve_latest_release_tag_including_prereleases "nervosnetwork/fiber" "$default_fnn_version")"
fi

echo "installing demo binaries into $bin_dir"

install_or_use_system_binary \
  "ckb" \
  "$bin_dir/ckb" \
  "nervosnetwork/ckb" \
  "$ckb_version" \
  ckb_asset_candidates

install_or_use_system_binary \
  "ckb-cli" \
  "$bin_dir/ckb-cli" \
  "nervosnetwork/ckb-cli" \
  "$ckb_cli_version" \
  ckb_cli_asset_candidates

install_from_github_release \
  "fnn" \
  "$bin_dir/fnn" \
  "nervosnetwork/fiber" \
  "$fnn_version" \
  fnn_asset_candidates

echo "demo binaries are ready:"
print_binary_summary "ckb" "$bin_dir/ckb"
print_binary_summary "ckb-cli" "$bin_dir/ckb-cli"
print_binary_summary "fnn" "$bin_dir/fnn"

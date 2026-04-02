#!/usr/bin/env bash

set -euo pipefail
export SHELLOPTS

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
project_dir="$(dirname "$script_dir")"
dist_dir="${DIST_DIR:-$project_dir/dist}"
app_name="${APP_NAME:-fiber-chat}"
profile="${PROFILE:-release}"
target_triple="${TARGET_TRIPLE:-$(rustc -vV | sed -n 's/^host: //p')}"
release_version="${RELEASE_VERSION:-$(git -C "$project_dir" describe --tags --always --dirty 2>/dev/null || date +%Y%m%d-%H%M%S)}"

case "$profile" in
  release)
    cargo_profile_args=(--release)
    binary_subdir="release"
    ;;
  debug)
    cargo_profile_args=()
    binary_subdir="debug"
    ;;
  *)
    echo "unsupported PROFILE: $profile" >&2
    exit 1
    ;;
esac

mkdir -p "$dist_dir"

bundle_name="${app_name}-${release_version}-${target_triple}"
stage_root="$(mktemp -d "${TMPDIR:-/tmp}/fiber-chat-release.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT INT TERM
stage_dir="$stage_root/$bundle_name"

cargo build \
  --locked \
  --target "$target_triple" \
  "${cargo_profile_args[@]}" \
  --manifest-path "$project_dir/Cargo.toml"

binary_path="$project_dir/target/$target_triple/$binary_subdir/ckb-chat"
if [ ! -x "$binary_path" ]; then
  echo "expected binary not found: $binary_path" >&2
  exit 1
fi

mkdir -p "$stage_dir/bin"
install -m 755 "$binary_path" "$stage_dir/bin/ckb-chat"
cp -R "$project_dir/static" "$stage_dir/static"
cp -R "$project_dir/scripts" "$stage_dir/scripts"
cp -R "$project_dir/fiber-bundle" "$stage_dir/fiber-bundle"
cp "$project_dir/start.sh" "$stage_dir/start.sh"
cp "$project_dir/README.md" "$stage_dir/README.md"

rm -rf "$stage_dir/fiber-bundle/deploy/node-data"
find "$stage_dir/fiber-bundle/nodes" -type f -name '*.log' -delete
find "$stage_dir/fiber-bundle/nodes" -type d -path '*/fiber/store' -prune -exec rm -rf {} +

archive_path="$dist_dir/$bundle_name.tar.gz"
tar -czf "$archive_path" -C "$stage_root" "$bundle_name"

echo "created release bundle: $archive_path"

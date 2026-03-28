#!/usr/bin/env bash
set -euo pipefail
export SHELLOPTS

export RUST_BACKTRACE=full
export RUST_LOG="${RUST_LOG:-info,fnn=debug,fnn::cch::trackers::lnd_trackers=off,fnn::fiber::gossip=off,fnn::fiber::graph=off,fnn::utils::actor=off,fnn::watchtower::actor=off}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
project_dir="$(dirname "$script_dir")"
bin_dir="$project_dir/bin"
bundle_dir="$project_dir/fiber-bundle"
nodes_dir="$bundle_dir/nodes"
deploy_dir="$bundle_dir/deploy"
install_binaries_script="$script_dir/install-binaries.sh"
fnn_bin="${FNN_BINARY:-$bin_dir/fnn}"
should_remove_old_state="${REMOVE_OLD_STATE:-}"
should_clean_fiber_state="${REMOVE_OLD_FIBER:-}"
ckb_rpc_host="${CKB_RPC_HOST:-127.0.0.1}"
ckb_rpc_port="${CKB_RPC_PORT:-8114}"
ckb_startup_timeout_seconds="${CKB_STARTUP_TIMEOUT_SECONDS:-60}"

fiber_logs_have_incompatible_database() {
  rg -q "incompatible database|higher version fiber executable binary|need to upgrade fiber binary" \
    "$nodes_dir" \
    -g '*.log'
}

ckb_log_has_chain_spec_mismatch() {
  local log_file="$1"
  rg -q "chain_spec_hash mismatch" "$log_file" 2>/dev/null
}

resolve_binary_path() {
  local preferred_path="$1"
  local command_name="$2"

  if [ -x "$preferred_path" ]; then
    printf '%s\n' "$preferred_path"
    return 0
  fi

  command -v "$command_name" 2>/dev/null || true
}

if [ ! -f "$install_binaries_script" ]; then
  echo "install script is missing: $install_binaries_script" >&2
  exit 1
fi

bash "$install_binaries_script"
export PATH="$bin_dir:$PATH"

ckb_bin="$(resolve_binary_path "$bin_dir/ckb" ckb)"
ckb_cli_bin="$(resolve_binary_path "$bin_dir/ckb-cli" ckb-cli)"

for binary_path in "$ckb_bin" "$ckb_cli_bin" "$fnn_bin"; do
  if [ -z "$binary_path" ] || [ ! -x "$binary_path" ]; then
    echo "required binary is not executable: $binary_path" >&2
    exit 1
  fi
done

# Fiber checks secret-key file permissions on startup.
find "$nodes_dir" -path '*/fiber/sk' -exec chmod 600 {} + >/dev/null 2>&1 || true

cleanup() {
  local jobs_pids
  jobs_pids="$(jobs -p || true)"
  if [ -n "$jobs_pids" ]; then
    echo "$jobs_pids" | xargs kill >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM

port_is_open() {
  local host="$1"
  local port="$2"
  (exec 3<>"/dev/tcp/$host/$port") >/dev/null 2>&1
}

wait_for_ckb_rpc() {
  local ckb_pid="$1"
  local log_file="$2"
  local second

  for ((second = 0; second < ckb_startup_timeout_seconds; second++)); do
    if port_is_open "$ckb_rpc_host" "$ckb_rpc_port"; then
      echo "CKB RPC is ready: ${ckb_rpc_host}:${ckb_rpc_port}"
      return 0
    fi

    if ! kill -0 "$ckb_pid" 2>/dev/null; then
      echo "CKB exited before RPC ${ckb_rpc_host}:${ckb_rpc_port} became ready." >&2
      echo "See $log_file for details." >&2
      return 1
    fi

    sleep 1
  done

  echo "Timed out waiting for CKB RPC ${ckb_rpc_host}:${ckb_rpc_port}." >&2
  echo "See $log_file for details." >&2
  return 1
}

reset_ckb_chain_state() {
  echo "Detected a CKB chain spec mismatch. Rebuilding local dev chain state ..."
  rm -rf "$nodes_dir"/*/fiber/store
  "$deploy_dir/init-dev-chain.sh" -f
}

start_ckb() {
  ckb_log_file="$nodes_dir/ckb.log"
  echo "logging to $(basename "$ckb_log_file")"
  : >"$ckb_log_file"
  "$ckb_bin" run -C "$deploy_dir/node-data" --indexer >"$ckb_log_file" 2>&1 &
  ckb_pid=$!
}

ensure_ckb_ready() {
  local reset_attempted=0

  while true; do
    start_ckb
    if wait_for_ckb_rpc "$ckb_pid" "$ckb_log_file"; then
      return 0
    fi

    if [ "$reset_attempted" -eq 0 ] && ckb_log_has_chain_spec_mismatch "$ckb_log_file"; then
      reset_attempted=1
      reset_ckb_chain_state
      continue
    fi

    return 1
  done
}

if [ -n "$should_clean_fiber_state" ]; then
  echo "cleaning local Fiber stores ..."
  rm -rf "$nodes_dir"/*/fiber/store
elif [ -n "$should_remove_old_state" ]; then
  echo "resetting local dev chain and Fiber stores ..."
  rm -rf "$nodes_dir"/*/fiber/store
  "$deploy_dir/init-dev-chain.sh" -f
fi

"$deploy_dir/init-dev-chain.sh"

echo "Initializing finished, begin to start services .... local bundle"
sleep 1

ensure_ckb_ready

cd "$nodes_dir" || exit 1

start_fnn() {
  log_file="${2}.log"
  echo "logging to ${log_file}"
  "$fnn_bin" "$@" 2>&1 | tee "$log_file"
}

FIBER_SECRET_KEY_PASSWORD='password0' LOG_PREFIX=$'[boot node]' start_fnn -d bootnode &
sleep 5
export FIBER_BOOTNODE_ADDRS=/ip4/127.0.0.1/tcp/8343/p2p/Qmbyc4rhwEwxxSQXd5B4Ej4XkKZL6XLipa3iJrnPL9cjGR
FIBER_SECRET_KEY_PASSWORD='password1' LOG_PREFIX=$'[node 1]' start_fnn -d 1 &
FIBER_SECRET_KEY_PASSWORD='password2' LOG_PREFIX=$'[node 2]' start_fnn -d 2 &
FIBER_SECRET_KEY_PASSWORD='password3' LOG_PREFIX=$'[node 3]' start_fnn -d 3 &

initial_jobs=$(jobs -p | wc -l)
while true; do
  if ! kill -0 "$ckb_pid" 2>/dev/null; then
    echo "CKB exited, exiting ..." >&2
    echo "See $ckb_log_file for details." >&2
    exit 1
  fi

  current_jobs=$(jobs -p | wc -l)
  if [ "$current_jobs" -lt "$initial_jobs" ]; then
    if fiber_logs_have_incompatible_database; then
      echo "Detected an incompatible Fiber store version." >&2
      echo "Re-run with REMOVE_OLD_FIBER=y ./scripts/start-fiber-network.sh to clear fiber-bundle/nodes/*/fiber/store." >&2
    fi
    echo "A background job has exited, exiting ..."
    exit 1
  fi
  sleep 1
done

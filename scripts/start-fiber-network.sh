#!/usr/bin/env bash
set -euo pipefail
export SHELLOPTS

export RUST_BACKTRACE=full
export RUST_LOG="${RUST_LOG:-info,fnn=debug,fnn::cch::trackers::lnd_trackers=off,fnn::fiber::gossip=off,fnn::fiber::graph=off,fnn::utils::actor=off}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
project_dir="$(dirname "$script_dir")"
bundle_dir="$project_dir/fiber-bundle"
nodes_dir="$bundle_dir/nodes"
deploy_dir="$bundle_dir/deploy"
fnn_bin="${FNN_BINARY:-$project_dir/bin/fnn}"
should_remove_old_state="${REMOVE_OLD_STATE:-}"
should_clean_fiber_state="${REMOVE_OLD_FIBER:-}"

for command in ckb ckb-cli; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required to run the local Fiber demo network" >&2
    exit 1
  fi
done

if [ ! -x "$fnn_bin" ]; then
  echo "Fiber binary not found or not executable: $fnn_bin" >&2
  exit 1
fi

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

ckb run -C "$deploy_dir/node-data" --indexer &

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
  current_jobs=$(jobs -p | wc -l)
  if [ "$current_jobs" -lt "$initial_jobs" ]; then
    echo "A background job has exited, exiting ..."
    exit 1
  fi
  sleep 1
done

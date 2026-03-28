#!/usr/bin/env bash
set -euo pipefail
export SHELLOPTS

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
fiber_script="$project_dir/scripts/start-fiber-network.sh"
fiber_nodes_dir="$project_dir/fiber-bundle/nodes"
demo_api_base="${DEMO_API_BASE:-http://127.0.0.1:3000}"
startup_timeout_seconds="${STARTUP_TIMEOUT_SECONDS:-240}"
startup_grace_seconds="${STARTUP_GRACE_SECONDS:-3}"
shutdown_grace_seconds="${SHUTDOWN_GRACE_SECONDS:-5}"

startup_ports=(
  3000
  8114
  8343
  8344
  8345
  8346
  21713
  21714
  21715
  21716
)

required_ports=(
  8114
  21713
  21714
  21715
  21716
)

fiber_pid=""
cargo_pid=""

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required by start.sh" >&2
    exit 1
  fi
}

require_command lsof
require_command rg
require_command curl

print_success_banner() {
  local message="$1"
  local border="========================================"

  if [ -t 1 ]; then
    printf '\n\033[1;32m%s\n%s\n%s\033[0m\n' "$border" "$message" "$border"
  else
    printf '\n%s\n%s\n%s\n' "$border" "$message" "$border"
  fi
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM

  if [ -n "$cargo_pid" ] && kill -0 "$cargo_pid" 2>/dev/null; then
    kill "$cargo_pid" 2>/dev/null || true
    wait "$cargo_pid" 2>/dev/null || true
  fi

  if [ -n "$fiber_pid" ] && kill -0 "$fiber_pid" 2>/dev/null; then
    kill "$fiber_pid" 2>/dev/null || true
    wait "$fiber_pid" 2>/dev/null || true
  fi

  exit "$exit_code"
}

trap cleanup EXIT INT TERM

port_listener_rows() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
}

port_listener_pids() {
  local port="$1"
  lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
}

port_is_open() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1
}

port_has_listener() {
  local port="$1"
  lsof -tiTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

wait_for_ports_to_clear() {
  local second
  local port

  for ((second = 0; second < shutdown_grace_seconds; second++)); do
    local any_busy=0
    for port in "${startup_ports[@]}"; do
      if port_has_listener "$port"; then
        any_busy=1
        break
      fi
    done

    if [ "$any_busy" -eq 0 ]; then
      return 0
    fi

    sleep 1
  done

  return 1
}

ensure_startup_ports_available() {
  local occupied_ports=()
  local port
  local pid_lines=""
  local answer
  local unique_pids

  for port in "${startup_ports[@]}"; do
    if port_has_listener "$port"; then
      occupied_ports+=("$port")
    fi
  done

  if [ "${#occupied_ports[@]}" -eq 0 ]; then
    return 0
  fi

  echo "The following ports are already in use:"
  for port in "${occupied_ports[@]}"; do
    echo
    echo "port $port"
    port_listener_rows "$port"
    while IFS= read -r pid; do
      if [ -n "$pid" ]; then
        pid_lines="${pid_lines}${pid}"$'\n'
      fi
    done <<EOF
$(port_listener_pids "$port")
EOF
  done

  if [ ! -t 0 ]; then
    echo "start.sh needs an interactive terminal to confirm whether these processes should be killed." >&2
    return 1
  fi

  printf '\nKill these processes and continue? [y/N] '
  read -r answer
  case "$answer" in
    y|Y|yes|YES)
      ;;
    *)
      echo "Leaving existing processes untouched."
      return 1
      ;;
  esac

  unique_pids="$(printf '%s' "$pid_lines" | awk 'NF' | sort -u)"
  if [ -z "$unique_pids" ]; then
    echo "Ports are busy but no listener PID could be resolved." >&2
    return 1
  fi

  echo "$unique_pids" | xargs kill
  if wait_for_ports_to_clear; then
    return 0
  fi

  echo "Some processes are still holding ports after SIGTERM. Sending SIGKILL ..."
  echo "$unique_pids" | xargs kill -9
  if wait_for_ports_to_clear; then
    return 0
  fi

  echo "Ports are still occupied after attempting to kill the listener processes." >&2
  return 1
}

# Backward-compatible alias for older local copies/logs that may still call the
# misspelled helper name during startup.
re_startup_ports_available() {
  ensure_startup_ports_available "$@"
}

fiber_logs_have_incompatible_database() {
  rg -q "incompatible database|higher version fiber executable binary|need to upgrade fiber binary" \
    "$fiber_nodes_dir" \
    -g '*.log'
}

offer_fiber_store_reset() {
  if ! fiber_logs_have_incompatible_database; then
    return 1
  fi

  echo "Detected an incompatible Fiber store version in $fiber_nodes_dir."
  echo "The downloaded fnn binary is older than the existing local store schema."
  echo "We can delete fiber-bundle/nodes/*/fiber/store and retry."

  if [ ! -t 0 ]; then
    echo "Re-run with REMOVE_OLD_FIBER=y ./start.sh if you want to clear the Fiber stores automatically." >&2
    return 1
  fi

  local answer
  printf 'Clear local Fiber stores and retry? [y/N] '
  read -r answer
  case "$answer" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      echo "Leaving Fiber stores untouched. You can re-run with REMOVE_OLD_FIBER=y ./start.sh later."
      return 1
      ;;
  esac
}

wait_for_port() {
  local port="$1"
  local second

  for ((second = 0; second < startup_timeout_seconds; second++)); do
    if ! kill -0 "$fiber_pid" 2>/dev/null; then
      local fiber_status=0
      wait "$fiber_pid" || fiber_status=$?
      if fiber_logs_have_incompatible_database; then
        echo "Fiber startup stopped because the on-disk Fiber store was created by a newer fnn binary." >&2
        return 42
      fi
      echo "Fiber network exited before port 127.0.0.1:$port became ready" >&2
      return "$fiber_status"
    fi

    if port_is_open "$port"; then
      echo "Fiber port is ready: 127.0.0.1:$port"
      return 0
    fi

    sleep 1
  done

  echo "Timed out waiting for Fiber port 127.0.0.1:$port" >&2
  return 1
}

start_fiber_network_once() {
  local reset_fiber_store="$1"

  echo "Starting Fiber network ..."
  if [ -n "$reset_fiber_store" ]; then
    REMOVE_OLD_FIBER=y bash "$fiber_script" &
  else
    bash "$fiber_script" &
  fi
  fiber_pid=$!

  for port in "${required_ports[@]}"; do
    wait_for_port "$port"
  done

  for ((second = 0; second < startup_grace_seconds; second++)); do
    if ! kill -0 "$fiber_pid" 2>/dev/null; then
      fiber_status=0
      wait "$fiber_pid" || fiber_status=$?
      if fiber_logs_have_incompatible_database; then
        echo "Fiber startup stopped because the on-disk Fiber store was created by a newer fnn binary." >&2
        return 42
      fi
      echo "Fiber network exited during startup grace period" >&2
      return "$fiber_status"
    fi
    sleep 1
  done

  return 0
}

wait_for_demo_server() {
  local second

  for ((second = 0; second < startup_timeout_seconds; second++)); do
    if curl -sf "$demo_api_base/api/state" >/dev/null 2>&1; then
      echo "Demo server is ready: $demo_api_base"
      return 0
    fi

    if ! kill -0 "$fiber_pid" 2>/dev/null; then
      local fiber_status=0
      wait "$fiber_pid" || fiber_status=$?
      echo "Fiber network exited before demo server became ready" >&2
      return "$fiber_status"
    fi

    if ! kill -0 "$cargo_pid" 2>/dev/null; then
      local cargo_status=0
      wait "$cargo_pid" || cargo_status=$?
      echo "cargo run exited before demo server became ready" >&2
      return "$cargo_status"
    fi

    sleep 1
  done

  echo "Timed out waiting for demo server at $demo_api_base" >&2
  return 1
}

prepare_demo_network() {
  local response_file
  local http_code

  response_file="$(mktemp)"
  http_code="$(curl -sS -o "$response_file" -w '%{http_code}' \
    -X POST "$demo_api_base/api/prepare" \
    -H 'content-type: application/json' \
    -d '{}')" || {
      echo "Failed to call $demo_api_base/api/prepare" >&2
      cat "$response_file" >&2 || true
      rm -f "$response_file"
      return 1
    }

  if [ "$http_code" != "200" ]; then
    echo "Demo network prepare failed with HTTP $http_code" >&2
    cat "$response_file" >&2 || true
    rm -f "$response_file"
    return 1
  fi

  rm -f "$response_file"
  print_success_banner "Demo network is ready for chat. Open $demo_api_base"
}

if [ ! -f "$fiber_script" ]; then
  echo "Fiber start script is missing: $fiber_script" >&2
  exit 1
fi

cd "$project_dir"
ensure_startup_ports_available

reset_fiber_store=""
if ! start_fiber_network_once "$reset_fiber_store"; then
  startup_status=$?
  if [ "$startup_status" -eq 42 ] && offer_fiber_store_reset; then
    reset_fiber_store="y"
    start_fiber_network_once "$reset_fiber_store"
  else
    exit "$startup_status"
  fi
fi

echo "Fiber network looks healthy, starting cargo run ..."
cargo run &
cargo_pid=$!

wait_for_demo_server
echo "Preparing demo network ..."
prepare_demo_network

while true; do
  if ! kill -0 "$fiber_pid" 2>/dev/null; then
    fiber_status=0
    wait "$fiber_pid" || fiber_status=$?
    echo "Fiber network exited, stopping demo server ..." >&2
    exit "$fiber_status"
  fi

  if ! kill -0 "$cargo_pid" 2>/dev/null; then
    cargo_status=0
    wait "$cargo_pid" || cargo_status=$?
    exit "$cargo_status"
  fi

  sleep 1
done

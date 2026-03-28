#!/usr/bin/env bash

set -euo pipefail
export SHELLOPTS

check_deps() {
    for command in "$@"; do
        if ! command -v "$command" >/dev/null; then
            echo "$* are required to run this script"
            exit 1
        fi
    done
}

check_deps ckb ckb-cli

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
data_dir="$script_dir/node-data"
nodes_dir="$script_dir/../nodes"
startup_log_file="${STARTUP_LOG_FILE:-$nodes_dir/init-dev-chain.log}"

ckb-cli() {
    # Don't pollute the home directory.
    env HOME="$data_dir" ckb-cli --url http://127.0.0.1:8114 "$@"
}

run_quiet() {
    if "$@" >>"$startup_log_file" 2>&1; then
        return 0
    fi

    echo
    echo "init-dev-chain failed. See $startup_log_file for details." >&2
    return 1
}

run_with_progress() {
    local label="$1"
    shift
    local child_pid

    printf '%s' "$label"
    "$@" >>"$startup_log_file" 2>&1 &
    child_pid=$!

    while kill -0 "$child_pid" 2>/dev/null; do
        printf '.'
        sleep 2
    done

    if wait "$child_pid"; then
        printf ' done\n'
        return 0
    fi

    printf ' failed\n'
    echo "init-dev-chain failed. See $startup_log_file for details." >&2
    return 1
}

# If -f is used, we will remove old state data. Otherwise we will skip the initialization.
while getopts "f" opt; do
    case $opt in
    f)
        rm -rf "$data_dir"
        ;;
    \?)
        echo "Invalid option: $OPTARG" 1>&2
        ;;
    esac
done

# Initialize the data directory if it does not exist.
if ! [[ -d "$data_dir" ]]; then
    mkdir -p "$nodes_dir"
    : >"$startup_log_file"

    run_quiet ckb init -C "$data_dir" -c dev --force --ba-arg 0xc8328aabcd9b9e8e64fbc566c4385c3bdeb219d7
    sed -i.bak 's|info|info,ckb-script=debug|g' "$data_dir/ckb.toml"
    cp "$nodes_dir/deployer/dev.toml" "$data_dir/specs/dev.toml"
    sed -i.bak 's|\.\./\.\./deploy/contracts|\.\./\.\./\.\./deploy/contracts|g' "$data_dir/specs/dev.toml"

    # Enable the IntegrationTest module (required to generate blocks).
    if ! grep -E '^modules.*IntegrationTest' "$data_dir/ckb.toml"; then
        # -i.bak is required to sed work on both Linux and macOS.
        sed -i.bak 's/\("Debug"\)/\1, "IntegrationTest"/' "$data_dir/ckb.toml"
    fi

    ckb run -C "$data_dir" --indexer >>"$startup_log_file" 2>&1 &

    # Make some accounts with default balances, and deploy the contracts to the network.
    # Don't continue until the default account has some money.
    # Transfer some money from the default account (node 3) to node 1 for later use.
    printf 'Waiting for CKB RPC'
    for i in {1..20}; do
        if ! nc -z 127.0.0.1 8114; then
            printf '.'
            sleep 2
        else
            printf ' ready\n'
            break
        fi
    done

    # Transfer some money to the node 1/2/3.
    # The address of node 1 can be seen with the following command:
    # echo | HOME=/tmp ckb-cli account import --local-only --privkey-path "$$nodes_dir/1/ckb/plain_key"
    printf 'Funding demo accounts'
    for i in {1..5}; do
        printf '.'
        run_quiet ckb-cli wallet transfer --to-address "$(cat "$nodes_dir/1/ckb/wallet")" --capacity 1000000000 --fee-rate 2000 --privkey-path "$nodes_dir/deployer/ckb/plain_key"
        sleep 1
        "$script_dir/generate-blocks.sh" 4 >>"$startup_log_file" 2>&1
        sleep 1

        # Transfer some money to the node 2.
        run_quiet ckb-cli wallet transfer --to-address "$(cat "$nodes_dir/2/ckb/wallet")" --capacity 1000000000 --fee-rate 2000 --privkey-path "$nodes_dir/deployer/ckb/plain_key"
        sleep 1
        "$script_dir/generate-blocks.sh" 4 >>"$startup_log_file" 2>&1
        sleep 1

        # Transfer some money to the node 3.
        run_quiet ckb-cli wallet transfer --to-address "$(cat "$nodes_dir/3/ckb/wallet")" --capacity 1000000000 --fee-rate 2000 --privkey-path "$nodes_dir/deployer/ckb/plain_key"
        sleep 1
        "$script_dir/generate-blocks.sh" 4 >>"$startup_log_file" 2>&1
        sleep 1
    done
    printf ' done\n'

    # Also deploy the contracts.
    run_with_progress "Deploying demo contracts" "$script_dir/deploy.sh"

    pkill -P $$
fi

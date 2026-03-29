# Fiber Chat Demo

This is a minimal runnable demo:

- The frontend is a web chat UI
- The backend is a Rust HTTP service
- Messages are transported through Fiber `send_payment.custom_records`

Each chat message is encoded as JSON and written into the fixed record key `0xcafe`.
Every message triggers a tiny keysend payment underneath.

## Run

1. Start the Fiber network and the demo service together

```bash
./start.sh
```

Then after it finishing, open the web UI at:

```text
http://127.0.0.1:3000
```

If `ckb` or `ckb-cli` already exist in your `PATH`, the installer reuses them instead of downloading new copies. It only forces reinstallation into `bin/` when you explicitly set:

```bash
FORCE_REINSTALL_BINARIES=y
```

On macOS, `fnn` currently defaults to the official `x86_64-darwin-portable` package.

You can also run the installer directly:

```bash
./scripts/install-binaries.sh
```

Optional environment variables:
- `CKB_VERSION`
- `CKB_CLI_VERSION`
- `FNN_VERSION`
- `GITHUB_TOKEN` or `GH_TOKEN`

Runtime uses these project-local paths:

- `bin/ckb`
- `bin/ckb-cli`
- `bin/fnn`
- `fiber-bundle/nodes/*`
- `fiber-bundle/deploy/*`

If you want to fully rebuild the local dev chain:

```bash
REMOVE_OLD_STATE=y ./scripts/start-fiber-network.sh
```

If you only want to clear Fiber store state:

```bash
REMOVE_OLD_FIBER=y ./start.sh
```

## Prepare The Network

Click `Prepare Demo Network` in the UI.

It will automatically:

- `connect_peer`
- `open_channel` for `node1 -> node2`
- `open_channel` for `node2 -> node3`
- generate epochs until funding transactions are confirmed
- wait for channels to reach `ChannelReady`
- seed reverse liquidity so both directions can chat

Available routes:
- `/system`: global observer page, shows the full network timeline and does not send messages
- `/nodes/node1`: the node-specific chat page for `node1`

`/system` keeps the global view, while `/nodes/<node-id>` only shows conversations relevant to that node.


## Structure

- `src/main.rs`: Rust backend for Fiber JSON-RPC calls, payment polling, demo network preparation, and web APIs
- `static/`: single-page frontend
- `bin/`: project-local directory for `ckb`, `ckb-cli`, and `fnn`
- `fiber-bundle/`: vendored Fiber node configs, keys, and dev-chain dependencies
- `scripts/install-binaries.sh`: installs the binaries needed by this project
- `scripts/start-fiber-network.sh`: starts the three reference nodes from the local bundle

## Current Tradeoff

Fiber's public RPC is still payment-session oriented and does not expose a direct inbox-style API for reading received `custom_records` from the receiver side.

So this demo uses a pragmatic local three-node approach:

- the backend polls `list_payments` on each local node
- it extracts only payments carrying the `0xcafe` chat record
- it reconstructs the chat timeline from those payment sessions


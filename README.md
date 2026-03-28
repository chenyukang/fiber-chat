# Fiber Chat Demo

这是一个最小可跑的 demo:

- 网页端是聊天界面
- 后端是 Rust HTTP 服务
- 底层消息通过 Fiber `send_payment` 的 `custom_records` 传输

消息体会被编码成 JSON，再塞进固定 record key `0xcafe`。每发一条消息，都会触发一笔 tiny keysend payment。

## 结构

- `src/main.rs`: Rust 后端，负责 Fiber JSON-RPC 调用、轮询 payment 状态、准备 demo 网络、提供网页 API
- `static/`: 单页前端
- `bin/`: 项目内使用的 `ckb`、`ckb-cli`、`fnn` 二进制目录
- `fiber-bundle/`: 已拷贝到项目内的 Fiber 节点配置、密钥和 dev-chain 依赖
- `scripts/install-binaries.sh`: 一键安装项目运行需要的二进制
- `scripts/start-fiber-network.sh`: 使用项目内 bundle 启动 3 个参考节点

## 运行

1. 一键启动 Fiber 网络和 demo 服务

```bash
cd /Users/yukang/code/ckb-chat
./start.sh
```

这个根目录脚本会先启动 `./scripts/start-fiber-network.sh`，等本地 Fiber 网络关键端口 ready 之后，再自动执行 `cargo run`，并在 HTTP 服务 ready 后自动调用一次 `/api/prepare`，把 channel 和 liquidity 准备好。
如果 `3000`、`8114`、`8343-8346`、`21713-21716` 这些端口已被占用，脚本会先列出占用进程并询问你是否要 kill 掉再继续。
如果当前 `fiber/store` 是由更高版本的 `fnn` 创建的，脚本也会提示你是否清理 `fiber-bundle/nodes/*/fiber/store` 后自动重试。

2. 如果你只想单独启动 Fiber 参考网络

```bash
cd /Users/yukang/code/ckb-chat
./scripts/start-fiber-network.sh
```

这个脚本启动前会先执行 `./scripts/install-binaries.sh`，从官方 GitHub release 下载适合当前系统的二进制到项目里的 `bin/`。默认固定版本是:

- `ckb`: `nervosnetwork/ckb` `v0.205.0`
- `ckb-cli`: `nervosnetwork/ckb-cli` `v2.0.0`
- `fnn`: 默认会解析 `nervosnetwork/fiber` 最新发布版本，包含 rc / prerelease；我现在核对到的是 `v0.8.0-rc1`

下载默认走 GitHub release 直链；如果 `curl` 在下载阶段偶发失败，脚本会自动尝试用本机 `gh release download` 兜底。
如果你本机 `PATH` 里已经有 `ckb` 或 `ckb-cli`，安装脚本会直接复用本机命令，不再下载；只有显式设置 `FORCE_REINSTALL_BINARIES=y` 时才会强制下载安装到项目 `bin/`。
在 macOS 上，`fnn` 默认直接使用官方 `x86_64-darwin-portable` 包，不会再先尝试一个不存在的 `aarch64-darwin` 资产。

如果你想单独执行安装，也可以直接跑:

```bash
cd /Users/yukang/code/ckb-chat
./scripts/install-binaries.sh
```

如果你需要覆盖默认版本，可以在执行前设置这些环境变量:

- `CKB_VERSION`
- `CKB_CLI_VERSION`
- `FNN_VERSION`
- `GITHUB_TOKEN` 或 `GH_TOKEN`

启动脚本之后会直接使用当前项目里的这些文件:

- `bin/ckb`
- `bin/ckb-cli`
- `bin/fnn`
- `fiber-bundle/nodes/*`
- `fiber-bundle/deploy/*`

补充一点：截至 2026 年 3 月，Fiber 官方 release 还没有 `aarch64-apple-darwin` 的 `fnn`，所以在 Apple Silicon 上安装脚本会回退到官方提供的 `x86_64-darwin-portable` 包。如果你的机器没有 Rosetta 2，脚本会在校验阶段报错并停止。

如果你想强制重建本地 dev chain，可以这样启动:

```bash
REMOVE_OLD_STATE=y ./scripts/start-fiber-network.sh
```

3. 如果你想单独启动 demo 服务

```bash
cd /Users/yukang/code/ckb-chat
cargo run
```

4. 打开浏览器

```text
http://127.0.0.1:3000
```

5. 点击页面上的 `Prepare Demo Network`

它会自动做这些事:

- `connect_peer`
- `open_channel` for `node1 -> node2`
- `open_channel` for `node2 -> node3`
- `generate_epochs` 让 funding tx 确认
- 等待 channel 进入 `ChannelReady`

准备好之后，可以用这些路由进入不同视角:

- `/system`: 全局 system 页面，只展示全网 timeline，不提供发送入口
- `/nodes/node1`: `node1` 自己的聊天页面

`system` 页面保留全局视角，`/nodes/<node-id>` 页面则只显示这个 node 自己相关的会话。

## 当前取舍

Fiber 现有公开 RPC 更偏向付款侧 session 视角，并没有直接暴露一个“收件箱”接口来读取接收方已经落库的 `custom_records`。所以这个 demo 采用了一个对本地三节点很实用的办法:

- 后端轮询每个本地节点的 `list_payments`
- 只提取带 `0xcafe` record 的 payment
- 以此还原聊天时间线

这意味着:

- 消息的真实承载仍然是 Fiber payment
- `system` 页面展示的是“全局观察者视角”的聊天记录
- `node` 页面是在前端按参与方过滤出的单节点视角

如果你后面想把它继续推进成真正的 per-node inbox，可以往两个方向扩展:

- 给 Fiber 增加读取接收侧 `custom_records` 的 RPC
- 或者给 demo 后端直接接 Fiber 本地 store

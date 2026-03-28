# Fiber Chat Demo

这是一个最小可跑的 demo:

- 网页端是聊天界面
- 后端是 Rust HTTP 服务
- 底层消息通过 Fiber `send_payment` 的 `custom_records` 传输

消息体会被编码成 JSON，再塞进固定 record key `0xcafe`。每发一条消息，都会触发一笔 tiny keysend payment。

## 结构

- `src/main.rs`: Rust 后端，负责 Fiber JSON-RPC 调用、轮询 payment 状态、准备 demo 网络、提供网页 API
- `static/`: 单页前端
- `bin/fnn`: 已拷贝到项目内的 Fiber 节点二进制
- `fiber-bundle/`: 已拷贝到项目内的 Fiber 节点配置、密钥和 dev-chain 依赖
- `scripts/start-fiber-network.sh`: 使用项目内 bundle 启动 3 个参考节点

## 运行

1. 启动 Fiber 参考网络

```bash
cd /Users/yukang/code/ckb-chat
./scripts/start-fiber-network.sh
```

这个脚本会直接使用当前项目里的这些文件:

- `bin/fnn`
- `fiber-bundle/nodes/*`
- `fiber-bundle/deploy/*`

不再依赖外部 `/Users/yukang/code/fiber/tests/nodes` 目录。

如果你想强制重建本地 dev chain，可以这样启动:

```bash
REMOVE_OLD_STATE=y ./scripts/start-fiber-network.sh
```

2. 另开一个终端，启动 demo 服务

```bash
cd /Users/yukang/code/ckb-chat
cargo run
```

3. 打开浏览器

```text
http://127.0.0.1:3000
```

4. 点击页面上的 `Prepare Demo Network`

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

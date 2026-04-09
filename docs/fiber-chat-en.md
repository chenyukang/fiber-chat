
I recently built a small demo called [fiber-chat](https://github.com/chenyukang/fiber-chat).

On the surface, it looks like a web chat app. Under the hood, though, it does not rely on a traditional centralized messaging service. Instead, it writes chat messages into Fiber Network's `send_payment.custom_records`, so each message travels through the network together with a Layer 2 payment.

![image|369x499](upload://wErZWOsCNZAmsvP2Bb1pvA12m2k.jpeg)


What drew me in was not the chat system itself, but a broader question:

**Can a payment network like Fiber also serve as the messaging layer for decentralized social applications?**

After building this demo, I believe the answer is yes. Because at their core, many of the hardest challenges in decentralized social are the same ones Fiber already solves.

## What makes decentralized social hard

Sending a message from A to B is not hard by itself. The difficult part is everything around it:

- Who forwards the message for you
- Why anyone would want to forward it
- How to limit spam and abuse
- Whether intermediate nodes can read the content while forwarding it

Some decentralized social systems end up falling back to centralized servers. That is not surprising. Once message delivery, node incentives, and privacy all have to work together, things get complicated very quickly.

What `fiber-chat` tries to test is whether Fiber can put those pieces into one coherent model.

## The core idea behind fiber-chat

In this demo, sending a message means:

1. Encoding the message as JSON
2. Writing it into `send_payment.custom_records`
3. Sending a keysend payment with a tiny amount (just enough to cover fees)
4. Letting that payment route through the Fiber network to the recipient

So this is not “chat simulated on top of Fiber.” The message is actually embedded into the payment session itself.

At the UI level, it looks like chat. At the protocol level, it is a Layer 2 payment carrying application data.

## Why this looks a lot like decentralized social

### 1. Sending a message has a cost

In `fiber-chat`, the sender pays a very small amount of CKB to send a message.

That amount can be tiny, small enough that normal chatting still feels natural. But it does something important:

**messages are not free.**

That matters a lot for decentralized social.

In centralized systems, spam is usually handled by moderation, risk controls, and account enforcement. In a decentralized network, that kind of control is weaker by design. If sending messages is completely free, spam and abuse quickly become structural problems.

With Fiber, each message carries a tiny CKB cost.

For ordinary users, that cost is almost invisible. But for anyone trying to flood the network with junk, it starts to add up immediately.

That gives us a more fundamental constraint than governance alone.

### 2. Intermediate nodes can earn fees for forwarding

Another recurring problem in decentralized social is simple:

**why should other nodes relay your messages at all?**

Many designs assume nodes will just participate in routing because they are part of the network. In practice, running a node has real costs: uptime, bandwidth, state maintenance operational complexity.

Without incentives, it is hard to expect the network to stay healthy over time.

Fiber is different because it is already a fee-based routing network.

In `fiber-chat`, a message is not broadcast to everyone. It follows a payment route across existing channels. Whenever the message crosses intermediate hops, those nodes can earn forwarding fees.

The model as simple as:

- the sender pays a tiny amount of CKB
- intermediate nodes earn fees for forwarding
- the receiver gets the message

That gives message delivery an actual incentive loop.

From the perspective of decentralized social, that is a big deal. It means message propagation is not only technically possible, but also economically sustainable.

### 3. Intermediate nodes route messages without reading them

That is because the message rides inside Fiber's onion-style routing model. An intermediate hop knows where it received the payment from, where to forward it next, and what amount it is handling. But it does not directly see the actual chat payload.

That matters a lot, intermediate nodes act more like postal routes than editors.

That is very close to what decentralized social infrastructure should look like:

- decentralized system
- incentives for participation
- privacy and censorship resistance

## How the demo works

The current `fiber-chat` demo has three layers.

### Frontend

The frontend is a chat UI with:

- node-specific chat pages
- conversation lists and unread state
- left/right message bubbles
- per-message Fiber details such as route, fee, payment hash, and hop information

From the user's point of view, it looks like a regular chat app. The difference is that every message corresponds to a real Fiber payment underneath.

### Rust backend

The backend is the coordinator. It handles:

- Fiber JSON-RPC calls
- automatic network preparation
- encoding messages into `custom_records`
- sending payments
- polling payment history on each node and reconstructing the chat timeline

There is a tradeoff here. Fiber's current public RPC is still centered around payment sessions, not around an inbox-style messaging API. Because of that, this demo uses an observer-style aggregation approach: the backend watches payment records, extracts the ones that carry chat records, and turns them back into messages for the frontend.

### Local Fiber network

For demonstration purposes, the repository includes a local bundle with:

- a local CKB dev chain
- a small Fiber network with `node1`, `node2`, and `node3`

On startup, the project automatically:

- assigns CKB to the nodes
- starts local Fiber nodes
- opens channels
- seeds bidirectional liquidity

So while this is currently a local demo, the underlying mechanism is real. It is not a fake frontend simulation.

If you want to try out the demo locally, you can run:

```bash

docker pull chenyukang/fiber-chat:latest

docker run --rm -p 3000:3000 chenyukang/fiber-chat:latest

```

Or follow [README](https://github.com/chenyukang/fiber-chat?tab=readme-ov-file#quick-start) to start it from source code.


## Where this could go next

If this direction is worth pursuing further, some obvious next steps would be:

- end-to-end encryption
- image and file metadata messages
- a proper wallet-based identity layer
- multi-node deployments beyond the local demo
- better route and fee visualization

And beyond that, it would be interesting to see how this kind of messaging layer could support more complex social applications, such as group chats, forums, or even microblogging.

Fiber is not limited to payments. It can also carry higher-level messaging protocols.
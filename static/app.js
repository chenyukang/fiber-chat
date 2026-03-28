const THREAD_READ_STATE_STORAGE_KEY = "fiber-chat-read-state-v1";

const state = {
  apiState: null,
  route: { kind: "system", nodeId: null },
  activePeerByNode: {},
  forceScrollNodeTimelineToBottom: false,
  expandedMessages: {},
  threadReadAt: loadThreadReadAt(),
};

const nodesContainer = document.querySelector("#nodes");
const refreshTime = document.querySelector("#refresh-time");
const prepareButton = document.querySelector("#prepare-button");
const prepareStatus = document.querySelector("#prepare-status");
const routeNav = document.querySelector("#route-nav");
const viewMeta = document.querySelector("#view-meta");

const systemView = document.querySelector("#system-view");
const systemTimeline = document.querySelector("#system-timeline");
const systemTimelineMeta = document.querySelector("#system-timeline-meta");

const nodeView = document.querySelector("#node-view");
const chatPageTitle = document.querySelector("#chat-page-title");
const chatPageMeta = document.querySelector("#chat-page-meta");
const conversationCount = document.querySelector("#conversation-count");
const conversationList = document.querySelector("#conversation-list");
const chatPeerLabel = document.querySelector("#chat-peer-label");
const nodeTimeline = document.querySelector("#node-timeline");
const nodeTimelineMeta = document.querySelector("#node-timeline-meta");
const nodeComposer = document.querySelector("#node-composer");
const nodeMessage = document.querySelector("#node-message");
const nodeSendStatus = document.querySelector("#node-send-status");
const nodeSendButton = document.querySelector("#node-send-button");

const nodeTemplate = document.querySelector("#node-template");
const conversationTemplate = document.querySelector("#conversation-template");
const messageTemplate = document.querySelector("#message-template");

async function requestJson(url, options) {
  const response = await fetch(url, {
    headers: {
      "Content-Type": "application/json",
    },
    ...options,
  });

  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || `Request failed with ${response.status}`);
  }
  return payload;
}

function shortHash(value) {
  if (!value) return "unknown";
  if (value.length <= 18) return value;
  return `${value.slice(0, 10)}...${value.slice(-6)}`;
}

function formatIntegerString(value) {
  if (!value) return "0";
  if (!/^\d+$/.test(String(value))) return String(value);

  const digits = String(value);
  const chunks = [];
  for (let index = digits.length; index > 0; index -= 3) {
    chunks.unshift(digits.slice(Math.max(0, index - 3), index));
  }
  return chunks.join(",");
}

function messageRouteText(message) {
  return message.route_hops.join(" -> ");
}

function isMessageExpanded(paymentHash) {
  return Boolean(state.expandedMessages[paymentHash]);
}

function setMessageExpanded(paymentHash, expanded) {
  if (expanded) {
    state.expandedMessages[paymentHash] = true;
    return;
  }
  delete state.expandedMessages[paymentHash];
}

function loadThreadReadAt() {
  try {
    const raw = window.localStorage.getItem(THREAD_READ_STATE_STORAGE_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function saveThreadReadAt() {
  try {
    window.localStorage.setItem(
      THREAD_READ_STATE_STORAGE_KEY,
      JSON.stringify(state.threadReadAt),
    );
  } catch {
    // Ignore storage failures and fall back to in-memory unread state.
  }
}

function threadReadKey(nodeId, peerId) {
  return `${nodeId}::${peerId}`;
}

function getThreadReadAt(nodeId, peerId) {
  return Number(state.threadReadAt[threadReadKey(nodeId, peerId)] || 0);
}

function markThreadRead(nodeId, peerId, messages) {
  const latestTimestamp = messages.reduce(
    (current, message) => Math.max(current, message.sent_at_ms),
    0,
  );
  if (!latestTimestamp) return;

  const key = threadReadKey(nodeId, peerId);
  if (Number(state.threadReadAt[key] || 0) >= latestTimestamp) return;
  state.threadReadAt[key] = latestTimestamp;
  saveThreadReadAt();
}

function formatTimestamp(ms) {
  if (!ms) return "unknown time";
  return new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    month: "short",
    day: "numeric",
  }).format(new Date(ms));
}

function bindCtrlEnterSubmit(textarea, form) {
  textarea.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" || !event.ctrlKey || event.isComposing) {
      return;
    }

    event.preventDefault();
    if (!textarea.disabled) {
      form.requestSubmit();
    }
  });
}

function getNodeById(nodes, nodeId) {
  return nodes.find((node) => node.id === nodeId) || null;
}

function normalizePath(pathname) {
  if (!pathname || pathname === "/") return "/";
  return pathname.endsWith("/") ? pathname.slice(0, -1) : pathname;
}

function canonicalPath(route) {
  if (route.kind === "node" && route.nodeId) {
    return `/nodes/${encodeURIComponent(route.nodeId)}`;
  }
  return "/system";
}

function parseRoute(nodes) {
  const pathname = normalizePath(window.location.pathname);

  if (pathname === "/" || pathname === "/system") {
    return {
      kind: "system",
      nodeId: null,
    };
  }

  const nodeMatch = pathname.match(/^\/nodes\/([^/]+)$/);
  if (nodeMatch) {
    const nodeId = decodeURIComponent(nodeMatch[1]);
    if (getNodeById(nodes, nodeId)) {
      return {
        kind: "node",
        nodeId,
      };
    }
  }

  return {
    kind: "system",
    nodeId: null,
  };
}

function syncRouteToLocation(route, replace = true) {
  const nextPath = canonicalPath(route);
  const currentPath = normalizePath(window.location.pathname);
  if (nextPath === currentPath) return;
  const method = replace ? "replaceState" : "pushState";
  window.history[method](null, "", nextPath);
}

function navigateTo(route) {
  state.route = route;
  syncRouteToLocation(route, false);
  if (state.apiState) {
    render(state.apiState);
  }
}

function routeButton(label, subtitle, route, isActive) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "route-link";
  button.dataset.path = canonicalPath(route);
  button.dataset.active = String(isActive);
  button.innerHTML = `<span>${label}</span><small>${subtitle}</small>`;
  return button;
}

function renderRouteNav(nodes, route) {
  routeNav.innerHTML = "";

  nodes.forEach((node) => {
    routeNav.append(
      routeButton(
        node.id,
        "chat",
        { kind: "node", nodeId: node.id },
        route.kind === "node" && route.nodeId === node.id,
      ),
    );
  });

  routeNav.append(
    routeButton("system", "global", { kind: "system", nodeId: null }, route.kind === "system"),
  );
}

function renderNodes(nodes, route) {
  nodesContainer.innerHTML = "";
  nodes.forEach((node) => {
    const fragment = nodeTemplate.content.cloneNode(true);
    const root = fragment.querySelector(".node-card");
    root.dataset.online = String(node.online);
    root.dataset.context = String(route.kind === "node" && route.nodeId === node.id);
    root.dataset.nodeId = node.id;

    fragment.querySelector(".node-label").textContent = node.label;
    fragment.querySelector(".node-id").textContent = `${node.id} · ${node.rpc_url}`;
    fragment.querySelector(".badge").textContent = node.online ? "ONLINE" : "OFFLINE";
    fragment.querySelector(".peers-count").textContent = String(node.peers_count);
    fragment.querySelector(".ready-count").textContent = `${node.ready_channels}/${node.channel_count}`;
    fragment.querySelector(".pubkey").textContent = node.pubkey
      ? `pubkey: ${shortHash(node.pubkey)}`
      : "pubkey: unavailable";

    const channelList = fragment.querySelector(".channel-list");
    if (node.channels.length === 0) {
      const empty = document.createElement("li");
      empty.textContent = "还没有看到可用 channel";
      channelList.append(empty);
    } else {
      node.channels.forEach((channel) => {
        const item = document.createElement("li");
        const peer = channel.peer_id || shortHash(channel.peer_pubkey);
        item.textContent = `${peer} · ${channel.state_name}`;
        channelList.append(item);
      });
    }

    fragment.querySelector(".node-error").textContent = node.last_error || "";
    nodesContainer.append(fragment);
  });
}

function renderHopList(container, message) {
  container.innerHTML = "";

  if (!Array.isArray(message.hop_details) || message.hop_details.length === 0) {
    const empty = document.createElement("p");
    empty.className = "message-hop-empty subtle";
    empty.textContent = "当前 payment 没有返回可展开的 channel trace。";
    container.append(empty);
    return;
  }

  message.hop_details.forEach((hop) => {
    const item = document.createElement("article");
    item.className = "message-hop-row";

    const title = document.createElement("p");
    title.className = "message-hop-title";
    title.textContent = `Hop ${hop.hop_index} · ${hop.from_node_id} -> ${hop.to_node_id}`;

    const channel = document.createElement("p");
    channel.className = "message-hop-channel message-code";
    channel.textContent = `channel ${hop.channel_outpoint}`;

    const amount = document.createElement("p");
    amount.className = "message-hop-amount subtle";
    amount.textContent = `amount ${formatIntegerString(hop.amount_shannons)} shannons`;

    item.append(title, channel, amount);
    container.append(item);
  });
}

function buildMessageCard(message, options = {}) {
  const { flow = "neutral", directionLabel = "" } = options;
  const fragment = messageTemplate.content.cloneNode(true);
  const root = fragment.querySelector(".message-card");
  const expanded = isMessageExpanded(message.payment_hash);
  const routeText = messageRouteText(message);

  root.dataset.status = message.status.toLowerCase();
  root.dataset.flow = flow;
  root.dataset.expanded = String(expanded);

  fragment.querySelector(".message-direction").textContent = directionLabel;
  fragment.querySelector(".message-status").textContent = message.status;
  fragment.querySelector(".message-body").textContent = message.text;
  fragment.querySelector(".message-time").textContent = formatTimestamp(message.sent_at_ms);

  const toggle = fragment.querySelector(".message-detail-toggle");
  toggle.dataset.paymentHash = message.payment_hash;
  toggle.setAttribute("aria-expanded", String(expanded));
  toggle.textContent = expanded ? "Details" : "Details";

  const details = fragment.querySelector(".message-details");
  details.hidden = !expanded;
  fragment.querySelector(".message-detail-route").textContent = routeText;
  fragment.querySelector(".message-detail-fee").textContent =
    `${formatIntegerString(message.fee_shannons)} shannons`;
  fragment.querySelector(".message-detail-hash").textContent = message.payment_hash;
  fragment.querySelector(".message-detail-hop-count").textContent = `${message.hop_count} hops`;
  renderHopList(fragment.querySelector(".message-hop-list"), message);

  const error = fragment.querySelector(".message-error");
  const failedError = message.failed_error || "";
  error.textContent = failedError;
  error.hidden = failedError.length === 0;

  return fragment;
}

function renderSystemMessages(messages) {
  systemTimeline.innerHTML = "";
  if (messages.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty-state";
    empty.textContent = "还没有聊天消息。先准备网络，再发第一条消息。";
    systemTimeline.append(empty);
    return;
  }

  messages.forEach((message) => {
    systemTimeline.append(
      buildMessageCard(message, {
        flow: "neutral",
        directionLabel: `${message.from_node_label} → ${message.to_node_label}`,
      }),
    );
  });
}

function getPeerNodes(nodes, activeNodeId) {
  return nodes.filter((node) => node.id !== activeNodeId);
}

function isMessageBetween(message, leftNodeId, rightNodeId) {
  const participants = [message.from_node_id, message.to_node_id];
  return participants.includes(leftNodeId) && participants.includes(rightNodeId);
}

function buildThreads(nodes, messages, activeNodeId) {
  return getPeerNodes(nodes, activeNodeId)
    .map((peer) => {
      const threadMessages = messages.filter((message) =>
        isMessageBetween(message, activeNodeId, peer.id),
      );
      return {
        peer,
        messages: threadMessages,
        lastMessage: threadMessages[0] || null,
      };
    })
    .sort((left, right) => {
      if (left.lastMessage && right.lastMessage) {
        return (
          right.lastMessage.sent_at_ms - left.lastMessage.sent_at_ms ||
          left.peer.sort_index - right.peer.sort_index
        );
      }
      if (left.lastMessage) return -1;
      if (right.lastMessage) return 1;
      return left.peer.sort_index - right.peer.sort_index;
    });
}

function conversationPreview(thread, activeNodeId) {
  if (!thread.lastMessage) {
    return "还没有消息，发第一条试试。";
  }
  if (thread.lastMessage.from_node_id === activeNodeId) {
    return `你: ${thread.lastMessage.text}`;
  }
  return `${thread.peer.label}: ${thread.lastMessage.text}`;
}

function unreadCountForThread(activeNodeId, thread) {
  const readAt = getThreadReadAt(activeNodeId, thread.peer.id);
  return thread.messages.filter((message) => {
    return message.from_node_id !== activeNodeId && message.sent_at_ms > readAt;
  }).length;
}

function conversationAvatarText(thread) {
  const numericSuffix = thread.peer.label.match(/\d+/)?.[0];
  if (numericSuffix) {
    return `N${numericSuffix}`;
  }

  return thread.peer.label
    .replace(/\s+/g, "")
    .slice(0, 2)
    .toUpperCase();
}

function renderConversationList(threads, activeNode, activePeerId) {
  conversationList.innerHTML = "";
  const totalUnread = threads.reduce((total, thread) => total + thread.unreadCount, 0);
  conversationCount.textContent =
    totalUnread > 0 ? `${threads.length} chats · ${totalUnread} unread` : `${threads.length} chats`;

  threads.forEach((thread) => {
    const fragment = conversationTemplate.content.cloneNode(true);
    const root = fragment.querySelector(".conversation-item");
    root.dataset.peerId = thread.peer.id;
    root.dataset.active = String(thread.peer.id === activePeerId);
    root.dataset.unread = String(thread.unreadCount > 0);

    fragment.querySelector(".conversation-avatar").textContent = conversationAvatarText(thread);
    fragment.querySelector(".conversation-peer").textContent = thread.peer.label;
    fragment.querySelector(".conversation-time").textContent = thread.lastMessage
      ? formatTimestamp(thread.lastMessage.sent_at_ms)
      : "No messages";
    fragment.querySelector(".conversation-preview").textContent = conversationPreview(
      thread,
      activeNode.id,
    );

    const unreadBadge = fragment.querySelector(".conversation-badge");
    unreadBadge.hidden = thread.unreadCount === 0;
    unreadBadge.textContent = "";
    unreadBadge.title = thread.unreadCount > 0 ? `${thread.unreadCount} unread` : "";

    conversationList.append(fragment);
  });

  if (threads.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty-state";
    empty.textContent = "没有可聊天的 peer。";
    conversationList.append(empty);
  }
}

function renderNodeMessages(threadMessages, activeNode, activePeer, statePayload) {
  const forceScroll = state.forceScrollNodeTimelineToBottom;
  state.forceScrollNodeTimelineToBottom = false;
  const shouldStickToBottom =
    nodeTimeline.scrollHeight - nodeTimeline.scrollTop - nodeTimeline.clientHeight < 80;

  nodeTimeline.innerHTML = "";

  if (!activePeer) {
    const empty = document.createElement("p");
    empty.className = "empty-state";
    empty.textContent = "先选择一个会话。";
    nodeTimeline.append(empty);
    chatPeerLabel.textContent = "选择一个会话";
    nodeTimelineMeta.textContent = "等待聊天记录";
    return;
  }

  const displayMessages = [...threadMessages].sort((left, right) => {
    return left.sent_at_ms - right.sent_at_ms || left.payment_hash.localeCompare(right.payment_hash);
  });

  chatPeerLabel.textContent = `${activeNode.label} ↔ ${activePeer.label}`;
  nodeTimelineMeta.textContent =
    `记录键 ${statePayload.record_key_hex} · ${displayMessages.length} messages`;

  if (displayMessages.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty-state";
    empty.textContent = `${activeNode.label} 和 ${activePeer.label} 还没有聊天记录。`;
    nodeTimeline.append(empty);
    return;
  }

  displayMessages.forEach((message) => {
    const isOutbound = message.from_node_id === activeNode.id;
    nodeTimeline.append(
      buildMessageCard(message, {
        flow: isOutbound ? "outbound" : "inbound",
        directionLabel: isOutbound ? `发给 ${activePeer.label}` : `收到来自 ${activePeer.label}`,
      }),
    );
  });

  if (forceScroll || shouldStickToBottom || displayMessages.length <= 6) {
    nodeTimeline.scrollTop = nodeTimeline.scrollHeight;
  }
}

function renderNodeComposer(activeNode, activePeer) {
  const disabled = !activeNode || !activePeer;
  nodeMessage.disabled = disabled;
  nodeSendButton.disabled = disabled;

  if (disabled) {
    nodeMessage.placeholder = "先选择一个会话";
    nodeSendButton.textContent = "Send Via Fiber";
    return;
  }

  nodeMessage.placeholder = `以 ${activeNode.label} 的身份给 ${activePeer.label} 发一条消息。`;
  nodeSendButton.textContent = `Send As ${activeNode.label}`;
}

function renderNodeView(nodes, messages, route, statePayload) {
  const activeNode = getNodeById(nodes, route.nodeId);
  if (!activeNode) {
    navigateTo({ kind: "system", nodeId: null });
    return;
  }

  const threads = buildThreads(nodes, messages, activeNode.id);
  if (!threads.some((thread) => thread.peer.id === state.activePeerByNode[activeNode.id])) {
    state.activePeerByNode[activeNode.id] = threads[0]?.peer.id || null;
  }

  const activePeer = getNodeById(nodes, state.activePeerByNode[activeNode.id]);
  const threadMessages = activePeer
    ? messages.filter((message) => isMessageBetween(message, activeNode.id, activePeer.id))
    : [];

  if (activePeer) {
    markThreadRead(activeNode.id, activePeer.id, threadMessages);
  }

  const threadsWithUnread = threads.map((thread) => ({
    ...thread,
    unreadCount: unreadCountForThread(activeNode.id, thread),
  }));

  chatPageTitle.textContent = `${activeNode.label} Chat Page`;
  chatPageMeta.textContent = `当前路由 ${canonicalPath(route)} · 全局视角统一走 /system。`;

  renderConversationList(threadsWithUnread, activeNode, activePeer?.id);
  renderNodeMessages(threadMessages, activeNode, activePeer, statePayload);
  renderNodeComposer(activeNode, activePeer);
}

function setDocumentTitle(route, nodes) {
  if (route.kind === "node" && route.nodeId) {
    const node = getNodeById(nodes, route.nodeId);
    document.title = node ? `${node.label} Chat · Fiber Chat Demo` : "Fiber Chat Demo";
    return;
  }
  document.title = "System View · Fiber Chat Demo";
}

function render(statePayload) {
  state.apiState = statePayload;
  state.route = parseRoute(statePayload.nodes);
  syncRouteToLocation(state.route, true);

  renderRouteNav(statePayload.nodes, state.route);
  renderNodes(statePayload.nodes, state.route);
  renderSystemMessages(statePayload.messages);

  systemTimelineMeta.textContent =
    `记录键 ${statePayload.record_key_hex} · ${statePayload.messages.length} messages`;

  if (state.route.kind === "system") {
    systemView.hidden = false;
    nodeView.hidden = true;
    viewMeta.textContent = "当前路由 /system，展示全网观察者视角。";
  } else {
    const activeNode = getNodeById(statePayload.nodes, state.route.nodeId);
    systemView.hidden = true;
    nodeView.hidden = false;
    viewMeta.textContent = activeNode
      ? `当前路由 ${canonicalPath(state.route)}，已经进入 ${activeNode.label} 的聊天页面。`
      : "当前是 node 聊天页面。";
    renderNodeView(statePayload.nodes, statePayload.messages, state.route, statePayload);
  }

  setDocumentTitle(state.route, statePayload.nodes);
  refreshTime.textContent = `最后刷新: ${formatTimestamp(statePayload.last_refresh_ms)}`;
}

async function loadState() {
  try {
    const payload = await requestJson("/api/state");
    render(payload);
    prepareStatus.textContent = "节点在线后可直接准备网络";
  } catch (error) {
    prepareStatus.textContent = error.message;
  }
}

prepareButton.addEventListener("click", async () => {
  prepareButton.disabled = true;
  prepareStatus.textContent = "正在连 peer、开 channel、出块确认...";
  try {
    const payload = await requestJson("/api/prepare", {
      method: "POST",
      body: JSON.stringify({}),
    });
    render(payload);
    prepareStatus.textContent = "Demo network 已准备好，可以开始聊天";
  } catch (error) {
    prepareStatus.textContent = error.message;
  } finally {
    prepareButton.disabled = false;
  }
});

routeNav.addEventListener("click", (event) => {
  const link = event.target.closest(".route-link");
  if (!link || !state.apiState) return;

  const path = link.dataset.path;
  if (path === "/system") {
    navigateTo({ kind: "system", nodeId: null });
    return;
  }

  navigateTo({
    kind: "node",
    nodeId: decodeURIComponent(path.split("/")[2]),
  });
});

nodesContainer.addEventListener("click", (event) => {
  const card = event.target.closest(".node-card");
  if (!card || !state.apiState) return;
  navigateTo({ kind: "node", nodeId: card.dataset.nodeId });
});

conversationList.addEventListener("click", (event) => {
  const item = event.target.closest(".conversation-item");
  if (!item || state.route.kind !== "node" || !state.route.nodeId) return;
  state.activePeerByNode[state.route.nodeId] = item.dataset.peerId;
  state.forceScrollNodeTimelineToBottom = true;
  render(state.apiState);
});

function handleMessageDetailToggle(event) {
  const button = event.target.closest(".message-detail-toggle");
  if (!button || !state.apiState) return;

  const paymentHash = button.dataset.paymentHash;
  setMessageExpanded(paymentHash, !isMessageExpanded(paymentHash));
  render(state.apiState);
}

systemTimeline.addEventListener("click", handleMessageDetailToggle);
nodeTimeline.addEventListener("click", handleMessageDetailToggle);

nodeComposer.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!state.apiState || state.route.kind !== "node" || !state.route.nodeId) return;

  const payload = {
    sender_id: state.route.nodeId,
    recipient_id: state.activePeerByNode[state.route.nodeId],
    message: nodeMessage.value,
  };

  nodeSendStatus.textContent = "消息发送中...";

  try {
    const result = await requestJson("/api/send", {
      method: "POST",
      body: JSON.stringify(payload),
    });
    nodeSendStatus.textContent = `已发起 payment ${shortHash(result.payment_hash)} (${result.status})`;
    nodeMessage.value = "";
    await loadState();
  } catch (error) {
    nodeSendStatus.textContent = error.message;
  }
});

window.addEventListener("popstate", () => {
  if (state.apiState) {
    render(state.apiState);
  }
});

bindCtrlEnterSubmit(nodeMessage, nodeComposer);

loadState();
setInterval(loadState, 2000);

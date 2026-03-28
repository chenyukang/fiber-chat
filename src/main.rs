use std::{
    collections::{BTreeMap, HashMap},
    net::SocketAddr,
    sync::Arc,
    time::Duration,
};

use anyhow::{anyhow, bail, Context, Result};
use axum::{
    extract::State,
    http::StatusCode,
    response::{Html, IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use reqwest::Client;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::{sync::RwLock, time::sleep};
use tower_http::services::ServeDir;
use tracing::{error, info, warn};

const CHAT_RECORD_KEY: u32 = 0xcafe;
const DEMO_PAYMENT_AMOUNT: u128 = 1_000;
const MIN_BIDIRECTIONAL_LIQUIDITY: u128 = 1_000_000;
const CHANNEL_FUNDING_AMOUNT: u128 = 61_000_000_000_000;
const NODE_1_2_FEE_RATE: u128 = 1_200;
const NODE_2_3_FEE_RATE: u128 = 1_400;
const POLL_INTERVAL_SECS: u64 = 2;
const SEND_TIMEOUT_SECS: u64 = 60;
const CKB_RPC_URL: &str = "http://127.0.0.1:8114";

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "ckb_chat=info,tower_http=info".into()),
        )
        .init();

    let app = Arc::new(DemoApp::new()?);
    app.refresh().await;

    let poller = Arc::clone(&app);
    tokio::spawn(async move {
        loop {
            sleep(Duration::from_secs(POLL_INTERVAL_SECS)).await;
            poller.refresh().await;
        }
    });

    let router = Router::new()
        .route("/", get(spa_entry))
        .route("/system", get(spa_entry))
        .route("/nodes/{node_id}", get(spa_entry))
        .route("/api/state", get(get_state))
        .route("/api/prepare", post(prepare_network))
        .route("/api/send", post(send_message))
        .with_state(Arc::clone(&app))
        .fallback_service(ServeDir::new("static"));

    let addr = SocketAddr::from(([127, 0, 0, 1], 3000));
    info!("Fiber chat demo listening on http://{addr}");

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .context("failed to bind http listener")?;
    axum::serve(listener, router)
        .await
        .context("http server crashed")?;

    Ok(())
}

async fn get_state(State(app): State<Arc<DemoApp>>) -> Result<Json<ApiState>, ApiError> {
    Ok(Json(app.state_snapshot().await))
}

async fn prepare_network(State(app): State<Arc<DemoApp>>) -> Result<Json<ApiState>, ApiError> {
    app.prepare_network().await?;
    app.refresh().await;
    Ok(Json(app.state_snapshot().await))
}

async fn send_message(
    State(app): State<Arc<DemoApp>>,
    Json(request): Json<SendChatRequest>,
) -> Result<Json<SendChatResponse>, ApiError> {
    let response = app.send_message(request).await?;
    Ok(Json(response))
}

async fn spa_entry() -> Response {
    match std::fs::read_to_string("static/index.html") {
        Ok(html) => Html(html).into_response(),
        Err(error) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("failed to load static/index.html: {error}"),
        )
            .into_response(),
    }
}

#[derive(Clone)]
struct DemoApp {
    http: Client,
    nodes: Vec<NodeConfig>,
    state: Arc<RwLock<AppState>>,
}

impl DemoApp {
    fn new() -> Result<Self> {
        let http = Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .context("failed to build reqwest client")?;

        Ok(Self {
            http,
            nodes: demo_nodes(),
            state: Arc::new(RwLock::new(AppState::default())),
        })
    }

    async fn state_snapshot(&self) -> ApiState {
        let state = self.state.read().await;
        let mut nodes = self
            .nodes
            .iter()
            .map(|config| {
                state
                    .nodes
                    .get(config.id)
                    .cloned()
                    .unwrap_or_else(|| NodeView::placeholder(config))
            })
            .collect::<Vec<_>>();
        nodes.sort_by_key(|node| node.sort_index);

        let mut messages = state.messages.values().cloned().collect::<Vec<_>>();
        messages.sort_by(|left, right| {
            right
                .sent_at_ms
                .cmp(&left.sent_at_ms)
                .then_with(|| right.payment_hash.cmp(&left.payment_hash))
        });

        ApiState {
            nodes,
            messages,
            last_refresh_ms: state.last_refresh_ms,
            record_key_hex: format!("0x{CHAT_RECORD_KEY:x}"),
            payment_amount_shannons: DEMO_PAYMENT_AMOUNT.to_string(),
        }
    }

    async fn refresh(&self) {
        let mut raw_nodes = Vec::with_capacity(self.nodes.len());

        for node in &self.nodes {
            match self.fetch_raw_node(node).await {
                Ok(raw) => raw_nodes.push(RawNodeState::Online(raw)),
                Err(error) => raw_nodes.push(RawNodeState::Offline {
                    config: node.clone(),
                    error: error.to_string(),
                }),
            }
        }

        let pubkey_to_id = raw_nodes
            .iter()
            .filter_map(|entry| match entry {
                RawNodeState::Online(raw) => {
                    Some((raw.node_info.pubkey.clone(), raw.config.id.to_string()))
                }
                RawNodeState::Offline { .. } => None,
            })
            .collect::<HashMap<_, _>>();

        let mut state = self.state.write().await;

        for entry in raw_nodes {
            match entry {
                RawNodeState::Online(raw) => {
                    let node_view = NodeView::from_raw(&raw, &pubkey_to_id);
                    for payment in raw.payments {
                        if let Some(message) =
                            ChatMessage::from_payment(raw.config.id, &payment, &pubkey_to_id)
                        {
                            state.messages.insert(message.payment_hash.clone(), message);
                        }
                    }
                    state.nodes.insert(raw.config.id.to_string(), node_view);
                }
                RawNodeState::Offline { config, error } => {
                    let previous = state
                        .nodes
                        .get(config.id)
                        .cloned()
                        .unwrap_or_else(|| NodeView::placeholder(&config));
                    state.nodes.insert(
                        config.id.to_string(),
                        NodeView {
                            online: false,
                            last_error: Some(error),
                            ..previous
                        },
                    );
                }
            }
        }

        state.last_refresh_ms = now_ms();
    }

    async fn prepare_network(&self) -> Result<()> {
        let raw_1 = self.fetch_raw_node(&self.nodes[0]).await?;
        let raw_2 = self.fetch_raw_node(&self.nodes[1]).await?;
        let raw_3 = self.fetch_raw_node(&self.nodes[2]).await?;

        self.ensure_connected(&raw_2.config, raw_1.first_address()?)
            .await?;
        self.ensure_connected(&raw_3.config, raw_2.first_address()?)
            .await?;

        self.ensure_ready_channel(
            &raw_1.config,
            &raw_2.config,
            &raw_2.node_info.pubkey,
            NODE_1_2_FEE_RATE,
        )
        .await?;
        self.ensure_bidirectional_liquidity(&raw_1.config, &raw_2.config, &raw_2.node_info.pubkey)
            .await?;

        self.ensure_ready_channel(
            &raw_2.config,
            &raw_3.config,
            &raw_3.node_info.pubkey,
            NODE_2_3_FEE_RATE,
        )
        .await?;
        self.ensure_bidirectional_liquidity(&raw_2.config, &raw_3.config, &raw_3.node_info.pubkey)
            .await?;

        self.wait_for_graph_visibility(&raw_1.config, 2).await?;

        Ok(())
    }

    async fn send_message(&self, request: SendChatRequest) -> Result<SendChatResponse> {
        let message = request.message.trim();
        if message.is_empty() {
            bail!("message can not be empty");
        }
        if request.sender_id == request.recipient_id {
            bail!("sender and recipient must be different nodes");
        }

        let sender_config = self
            .find_node(&request.sender_id)
            .ok_or_else(|| anyhow!("unknown sender node {}", request.sender_id))?;
        let recipient_config = self
            .find_node(&request.recipient_id)
            .ok_or_else(|| anyhow!("unknown recipient node {}", request.recipient_id))?;

        let sender = self.fetch_raw_node(sender_config).await?;
        let recipient = self.fetch_raw_node(recipient_config).await?;

        let envelope = ChatEnvelope {
            version: 1,
            kind: "fiber-chat-demo".to_string(),
            sender_id: sender.config.id.to_string(),
            sender_label: sender.config.label.to_string(),
            sender_pubkey: sender.node_info.pubkey.clone(),
            recipient_id: recipient.config.id.to_string(),
            recipient_label: recipient.config.label.to_string(),
            recipient_pubkey: recipient.node_info.pubkey.clone(),
            text: message.to_string(),
            sent_at_ms: now_ms(),
        };

        let payload = serde_json::to_vec(&envelope).context("failed to encode chat payload")?;
        if payload.len() > 1_500 {
            bail!("message is too large for demo custom_records");
        }

        let result: FiberPayment = self
            .rpc_call(
                &sender.config.rpc_url,
                "send_payment",
                Some(json!({
                    "target_pubkey": recipient.node_info.pubkey,
                    "amount": to_hex_u128(DEMO_PAYMENT_AMOUNT),
                    "keysend": true,
                    "timeout": to_hex_u64(SEND_TIMEOUT_SECS),
                    "custom_records": {
                        format!("0x{CHAT_RECORD_KEY:x}"): bytes_to_hex(&payload)
                    }
                })),
            )
            .await
            .context("send_payment failed")?;

        if let Some(chat_message) = ChatMessage::from_payment(
            sender.config.id,
            &result,
            &HashMap::from([
                (
                    sender.node_info.pubkey.clone(),
                    sender.config.id.to_string(),
                ),
                (
                    recipient.node_info.pubkey.clone(),
                    recipient.config.id.to_string(),
                ),
            ]),
        ) {
            self.state
                .write()
                .await
                .messages
                .insert(chat_message.payment_hash.clone(), chat_message.clone());
        }

        Ok(SendChatResponse {
            payment_hash: result.payment_hash,
            status: result.status,
        })
    }

    async fn fetch_raw_node(&self, config: &NodeConfig) -> Result<RawOnlineNode> {
        let node_info: FiberNodeInfo = self
            .rpc_call(&config.rpc_url, "node_info", None)
            .await
            .with_context(|| format!("node_info failed for {}", config.id))?;

        let channel_list: FiberChannelsResponse = self
            .rpc_call(
                &config.rpc_url,
                "list_channels",
                Some(json!({"include_closed": false})),
            )
            .await
            .with_context(|| format!("list_channels failed for {}", config.id))?;

        let payments: FiberPaymentsResponse = self
            .rpc_call(
                &config.rpc_url,
                "list_payments",
                Some(json!({"limit": to_hex_u64(200)})),
            )
            .await
            .with_context(|| format!("list_payments failed for {}", config.id))?;

        Ok(RawOnlineNode {
            config: config.clone(),
            node_info,
            channels: channel_list.channels,
            payments: payments.payments,
        })
    }

    async fn ensure_connected(&self, dialer: &NodeConfig, address: String) -> Result<()> {
        let attempt = self
            .rpc_call_allow_null(
                &dialer.rpc_url,
                "connect_peer",
                Some(json!({ "address": address })),
            )
            .await;

        if let Err(error) = attempt {
            let message = error.to_string();
            if !message.contains("already connected") {
                warn!("connect_peer for {} returned: {message}", dialer.id);
            }
        }

        sleep(Duration::from_secs(1)).await;
        Ok(())
    }

    async fn ensure_ready_channel(
        &self,
        source: &NodeConfig,
        target: &NodeConfig,
        target_pubkey: &str,
        fee_rate: u128,
    ) -> Result<()> {
        let source_pubkey = self.fetch_raw_node(source).await?.node_info.pubkey;

        if self.channel_ready(source, target_pubkey).await? {
            return Ok(());
        }

        if !self.channel_exists(source, target_pubkey).await? {
            self.rpc_call::<OpenChannelResult>(
                &source.rpc_url,
                "open_channel",
                Some(json!({
                    "pubkey": target_pubkey,
                    "funding_amount": to_hex_u128(CHANNEL_FUNDING_AMOUNT),
                    "tlc_fee_proportional_millionths": to_hex_u128(fee_rate)
                })),
            )
            .await
            .with_context(|| format!("open_channel failed for {} -> {}", source.id, target.id))?;

            sleep(Duration::from_secs(2)).await;
        }

        self.generate_epochs(2).await?;
        self.wait_for_channel_ready(source, target_pubkey).await?;
        self.wait_for_channel_ready(target, &source_pubkey).await?;

        Ok(())
    }

    async fn channel_exists(&self, node: &NodeConfig, peer_pubkey: &str) -> Result<bool> {
        let response: FiberChannelsResponse = self
            .rpc_call(
                &node.rpc_url,
                "list_channels",
                Some(json!({ "pubkey": peer_pubkey })),
            )
            .await?;

        Ok(!response.channels.is_empty())
    }

    async fn channel_ready(&self, node: &NodeConfig, peer_pubkey: &str) -> Result<bool> {
        let response: FiberChannelsResponse = self
            .rpc_call(
                &node.rpc_url,
                "list_channels",
                Some(json!({ "pubkey": peer_pubkey })),
            )
            .await?;

        Ok(response.channels.iter().any(FiberChannel::is_ready))
    }

    async fn wait_for_channel_ready(&self, node: &NodeConfig, peer_pubkey: &str) -> Result<()> {
        for _ in 0..20 {
            if self.channel_ready(node, peer_pubkey).await? {
                return Ok(());
            }
            sleep(Duration::from_secs(2)).await;
        }

        bail!(
            "channel between {} and {peer_pubkey} did not reach ChannelReady in time",
            node.id
        );
    }

    async fn wait_for_graph_visibility(
        &self,
        node: &NodeConfig,
        minimum_channels: usize,
    ) -> Result<()> {
        for _ in 0..20 {
            let graph: GraphChannelsResponse = self
                .rpc_call(
                    &node.rpc_url,
                    "graph_channels",
                    Some(json!({ "limit": to_hex_u64(32) })),
                )
                .await?;

            if graph.channels.len() >= minimum_channels {
                return Ok(());
            }

            sleep(Duration::from_secs(2)).await;
        }

        bail!("graph_channels on {} did not show enough channels", node.id);
    }

    async fn ensure_bidirectional_liquidity(
        &self,
        source: &NodeConfig,
        target: &NodeConfig,
        target_pubkey: &str,
    ) -> Result<()> {
        let source_pubkey = self.fetch_raw_node(source).await?.node_info.pubkey;
        let current_balance = self
            .channel_local_balance(target, &source_pubkey)
            .await?
            .unwrap_or_default();

        if current_balance >= MIN_BIDIRECTIONAL_LIQUIDITY {
            return Ok(());
        }

        let top_up_amount = MIN_BIDIRECTIONAL_LIQUIDITY - current_balance;
        info!(
            "seeding reverse liquidity on {} <-> {} with {} shannons",
            source.id, target.id, top_up_amount
        );

        self.rpc_call::<FiberPayment>(
            &source.rpc_url,
            "send_payment",
            Some(json!({
                "target_pubkey": target_pubkey,
                "amount": to_hex_u128(top_up_amount),
                "keysend": true,
                "timeout": to_hex_u64(SEND_TIMEOUT_SECS),
            })),
        )
        .await
        .with_context(|| {
            format!(
                "failed to seed reverse liquidity for {} -> {}",
                source.id, target.id
            )
        })?;

        self.wait_for_local_balance(target, &source_pubkey, MIN_BIDIRECTIONAL_LIQUIDITY)
            .await?;
        Ok(())
    }

    async fn channel_local_balance(
        &self,
        node: &NodeConfig,
        peer_pubkey: &str,
    ) -> Result<Option<u128>> {
        let response: FiberChannelsResponse = self
            .rpc_call(
                &node.rpc_url,
                "list_channels",
                Some(json!({ "pubkey": peer_pubkey })),
            )
            .await?;

        response
            .channels
            .into_iter()
            .next()
            .map(|channel| channel.local_balance_u128())
            .transpose()
    }

    async fn wait_for_local_balance(
        &self,
        node: &NodeConfig,
        peer_pubkey: &str,
        minimum_balance: u128,
    ) -> Result<()> {
        for _ in 0..20 {
            if self
                .channel_local_balance(node, peer_pubkey)
                .await?
                .unwrap_or_default()
                >= minimum_balance
            {
                return Ok(());
            }

            sleep(Duration::from_secs(1)).await;
        }

        bail!(
            "channel between {} and {peer_pubkey} did not reach local balance {} in time",
            node.id,
            minimum_balance
        );
    }

    async fn generate_epochs(&self, epochs: u64) -> Result<()> {
        self.rpc_call::<Value>(
            CKB_RPC_URL,
            "generate_epochs",
            Some(json!([to_hex_u64(epochs)])),
        )
        .await
        .context("generate_epochs failed")?;
        sleep(Duration::from_secs(5)).await;
        Ok(())
    }

    fn find_node(&self, node_id: &str) -> Option<&NodeConfig> {
        self.nodes.iter().find(|config| config.id == node_id)
    }

    async fn rpc_call<T>(&self, url: &str, method: &str, params: Option<Value>) -> Result<T>
    where
        T: DeserializeOwned,
    {
        let params_value = match params {
            Some(Value::Array(values)) => Value::Array(values),
            Some(value) => Value::Array(vec![value]),
            None => Value::Array(vec![]),
        };

        let response = self
            .http
            .post(url)
            .json(&json!({
                "id": "ckb-chat-demo",
                "jsonrpc": "2.0",
                "method": method,
                "params": params_value,
            }))
            .send()
            .await
            .with_context(|| format!("http request failed for {method} at {url}"))?;

        let rpc: JsonRpcResponse<T> = response
            .json()
            .await
            .with_context(|| format!("failed to decode rpc response for {method}"))?;

        if let Some(error) = rpc.error {
            bail!("rpc {method} failed: {}", error.message);
        }

        rpc.result
            .ok_or_else(|| anyhow!("rpc {method} did not return a result"))
    }

    async fn rpc_call_allow_null(
        &self,
        url: &str,
        method: &str,
        params: Option<Value>,
    ) -> Result<Option<Value>> {
        let params_value = match params {
            Some(Value::Array(values)) => Value::Array(values),
            Some(value) => Value::Array(vec![value]),
            None => Value::Array(vec![]),
        };

        let response = self
            .http
            .post(url)
            .json(&json!({
                "id": "ckb-chat-demo",
                "jsonrpc": "2.0",
                "method": method,
                "params": params_value,
            }))
            .send()
            .await
            .with_context(|| format!("http request failed for {method} at {url}"))?;

        let rpc: JsonRpcResponse<Value> = response
            .json()
            .await
            .with_context(|| format!("failed to decode rpc response for {method}"))?;

        if let Some(error) = rpc.error {
            bail!("rpc {method} failed: {}", error.message);
        }

        Ok(rpc.result)
    }
}

fn demo_nodes() -> Vec<NodeConfig> {
    vec![
        NodeConfig::new(0, "node1", "Node 1", "http://127.0.0.1:21714"),
        NodeConfig::new(1, "node2", "Node 2", "http://127.0.0.1:21715"),
        NodeConfig::new(2, "node3", "Node 3", "http://127.0.0.1:21716"),
    ]
}

#[derive(Clone)]
struct NodeConfig {
    sort_index: usize,
    id: &'static str,
    label: &'static str,
    rpc_url: &'static str,
}

impl NodeConfig {
    const fn new(
        sort_index: usize,
        id: &'static str,
        label: &'static str,
        rpc_url: &'static str,
    ) -> Self {
        Self {
            sort_index,
            id,
            label,
            rpc_url,
        }
    }
}

#[derive(Default)]
struct AppState {
    nodes: BTreeMap<String, NodeView>,
    messages: BTreeMap<String, ChatMessage>,
    last_refresh_ms: u64,
}

enum RawNodeState {
    Online(RawOnlineNode),
    Offline { config: NodeConfig, error: String },
}

struct RawOnlineNode {
    config: NodeConfig,
    node_info: FiberNodeInfo,
    channels: Vec<FiberChannel>,
    payments: Vec<FiberPayment>,
}

impl RawOnlineNode {
    fn first_address(&self) -> Result<String> {
        self.node_info
            .addresses
            .first()
            .cloned()
            .ok_or_else(|| anyhow!("{} does not expose a dialable address", self.config.id))
    }
}

#[derive(Clone, Serialize)]
struct ApiState {
    nodes: Vec<NodeView>,
    messages: Vec<ChatMessage>,
    last_refresh_ms: u64,
    record_key_hex: String,
    payment_amount_shannons: String,
}

#[derive(Clone, Serialize)]
struct NodeView {
    sort_index: usize,
    id: String,
    label: String,
    rpc_url: String,
    online: bool,
    pubkey: Option<String>,
    addresses: Vec<String>,
    peers_count: u64,
    channel_count: u64,
    ready_channels: u64,
    channels: Vec<ChannelView>,
    last_error: Option<String>,
}

impl NodeView {
    fn placeholder(config: &NodeConfig) -> Self {
        Self {
            sort_index: config.sort_index,
            id: config.id.to_string(),
            label: config.label.to_string(),
            rpc_url: config.rpc_url.to_string(),
            online: false,
            pubkey: None,
            addresses: vec![],
            peers_count: 0,
            channel_count: 0,
            ready_channels: 0,
            channels: vec![],
            last_error: Some("node is offline".to_string()),
        }
    }

    fn from_raw(raw: &RawOnlineNode, pubkey_to_id: &HashMap<String, String>) -> Self {
        let mut channels = raw
            .channels
            .iter()
            .map(|channel| ChannelView {
                peer_id: pubkey_to_id.get(&channel.pubkey).cloned(),
                peer_pubkey: channel.pubkey.clone(),
                channel_id: channel.channel_id.clone(),
                state_name: channel.state_name(),
                enabled: channel.enabled,
            })
            .collect::<Vec<_>>();
        channels.sort_by(|left, right| left.peer_pubkey.cmp(&right.peer_pubkey));

        let ready_channels = raw
            .channels
            .iter()
            .filter(|channel| channel.is_ready())
            .count() as u64;

        Self {
            sort_index: raw.config.sort_index,
            id: raw.config.id.to_string(),
            label: raw.config.label.to_string(),
            rpc_url: raw.config.rpc_url.to_string(),
            online: true,
            pubkey: Some(raw.node_info.pubkey.clone()),
            addresses: raw.node_info.addresses.clone(),
            peers_count: hex_to_u64(&raw.node_info.peers_count).unwrap_or_default(),
            channel_count: hex_to_u64(&raw.node_info.channel_count).unwrap_or_default(),
            ready_channels,
            channels,
            last_error: None,
        }
    }
}

#[derive(Clone, Serialize)]
struct ChannelView {
    peer_id: Option<String>,
    peer_pubkey: String,
    channel_id: String,
    state_name: String,
    enabled: bool,
}

#[derive(Clone, Serialize)]
struct ChatMessage {
    payment_hash: String,
    status: String,
    from_node_id: String,
    from_node_label: String,
    to_node_id: String,
    to_node_label: String,
    route_hops: Vec<String>,
    hop_count: usize,
    hop_details: Vec<ChatRouteHop>,
    text: String,
    sent_at_ms: u64,
    payment_created_at_ms: u64,
    payment_updated_at_ms: u64,
    fee_shannons: String,
    failed_error: Option<String>,
}

#[derive(Clone, Serialize)]
struct ChatRouteHop {
    hop_index: usize,
    from_node_id: String,
    to_node_id: String,
    channel_outpoint: String,
    amount_shannons: String,
}

impl ChatMessage {
    fn from_payment(
        sender_id: &str,
        payment: &FiberPayment,
        pubkey_to_id: &HashMap<String, String>,
    ) -> Option<Self> {
        let record_hex = payment
            .custom_records
            .as_ref()?
            .get(&format!("0x{CHAT_RECORD_KEY:x}"))?
            .clone();
        let payload = hex_to_bytes(&record_hex).ok()?;
        let envelope: ChatEnvelope = serde_json::from_slice(&payload).ok()?;
        if envelope.kind != "fiber-chat-demo" || envelope.version != 1 {
            return None;
        }

        let sender_node = pubkey_to_id
            .get(&envelope.sender_pubkey)
            .cloned()
            .unwrap_or_else(|| sender_id.to_string());
        let recipient_node = pubkey_to_id
            .get(&envelope.recipient_pubkey)
            .cloned()
            .unwrap_or_else(|| envelope.recipient_id.clone());
        let route_nodes = payment
            .routers
            .first()
            .map(|route| route.nodes.clone())
            .unwrap_or_default();

        let mut route_hops = if route_nodes.is_empty() {
            vec![sender_node.clone(), recipient_node.clone()]
        } else {
            route_nodes
                .iter()
                .map(|node| {
                    pubkey_to_id
                        .get(&node.pubkey)
                        .cloned()
                        .unwrap_or_else(|| short_pubkey(&node.pubkey))
                })
                .collect::<Vec<_>>()
        };
        if route_hops.first() != Some(&sender_node) {
            route_hops.insert(0, sender_node.clone());
        }
        if route_hops.last() != Some(&recipient_node) {
            route_hops.push(recipient_node.clone());
        }

        let hop_details = route_nodes
            .iter()
            .enumerate()
            .map(|(index, node)| {
                let from_node_id = pubkey_to_id
                    .get(&node.pubkey)
                    .cloned()
                    .unwrap_or_else(|| short_pubkey(&node.pubkey));
                let to_node_id = route_nodes
                    .get(index + 1)
                    .map(|next| {
                        pubkey_to_id
                            .get(&next.pubkey)
                            .cloned()
                            .unwrap_or_else(|| short_pubkey(&next.pubkey))
                    })
                    .unwrap_or_else(|| recipient_node.clone());

                Some(ChatRouteHop {
                    hop_index: index + 1,
                    from_node_id,
                    to_node_id,
                    channel_outpoint: node.channel_outpoint.clone(),
                    amount_shannons: hex_to_u128(&node.amount)
                        .map(|amount| amount.to_string())
                        .unwrap_or_else(|_| node.amount.clone()),
                })
            })
            .collect::<Option<Vec<_>>>()?;
        let hop_count = route_hops.len().saturating_sub(1);

        Some(Self {
            payment_hash: payment.payment_hash.clone(),
            status: payment.status.clone(),
            from_node_id: sender_node,
            from_node_label: envelope.sender_label,
            to_node_id: recipient_node,
            to_node_label: envelope.recipient_label,
            route_hops,
            hop_count,
            hop_details,
            text: envelope.text,
            sent_at_ms: envelope.sent_at_ms,
            payment_created_at_ms: hex_to_u64(&payment.created_at).ok()?,
            payment_updated_at_ms: hex_to_u64(&payment.last_updated_at).ok()?,
            fee_shannons: hex_to_u128(&payment.fee).ok()?.to_string(),
            failed_error: payment.failed_error.clone(),
        })
    }
}

#[derive(Deserialize)]
struct SendChatRequest {
    sender_id: String,
    recipient_id: String,
    message: String,
}

#[derive(Serialize)]
struct SendChatResponse {
    payment_hash: String,
    status: String,
}

#[derive(Serialize, Deserialize)]
struct ChatEnvelope {
    version: u8,
    kind: String,
    sender_id: String,
    sender_label: String,
    sender_pubkey: String,
    recipient_id: String,
    recipient_label: String,
    recipient_pubkey: String,
    text: String,
    sent_at_ms: u64,
}

#[derive(Deserialize)]
struct JsonRpcResponse<T> {
    #[allow(dead_code)]
    jsonrpc: String,
    #[allow(dead_code)]
    id: Value,
    result: Option<T>,
    error: Option<JsonRpcError>,
}

#[derive(Deserialize)]
struct JsonRpcError {
    #[allow(dead_code)]
    code: i64,
    message: String,
}

#[derive(Deserialize)]
struct FiberNodeInfo {
    pubkey: String,
    addresses: Vec<String>,
    channel_count: String,
    peers_count: String,
}

#[derive(Deserialize)]
struct FiberChannelsResponse {
    channels: Vec<FiberChannel>,
}

#[derive(Deserialize)]
struct FiberChannel {
    channel_id: String,
    pubkey: String,
    enabled: bool,
    local_balance: String,
    remote_balance: String,
    state: Value,
}

impl FiberChannel {
    fn state_name(&self) -> String {
        self.state
            .get("state_name")
            .and_then(Value::as_str)
            .unwrap_or("Unknown")
            .to_string()
    }

    fn is_ready(&self) -> bool {
        self.state_name() == "ChannelReady"
    }

    fn local_balance_u128(&self) -> Result<u128> {
        hex_to_u128(&self.local_balance)
    }

    #[allow(dead_code)]
    fn remote_balance_u128(&self) -> Result<u128> {
        hex_to_u128(&self.remote_balance)
    }
}

#[derive(Deserialize)]
struct OpenChannelResult {
    #[allow(dead_code)]
    temporary_channel_id: String,
}

#[derive(Deserialize)]
struct FiberPaymentsResponse {
    payments: Vec<FiberPayment>,
}

#[derive(Clone, Deserialize)]
struct FiberPayment {
    payment_hash: String,
    status: String,
    created_at: String,
    last_updated_at: String,
    failed_error: Option<String>,
    fee: String,
    custom_records: Option<HashMap<String, String>>,
    #[serde(default)]
    routers: Vec<FiberSessionRoute>,
}

#[derive(Deserialize)]
struct GraphChannelsResponse {
    channels: Vec<Value>,
}

#[derive(Clone, Deserialize)]
struct FiberSessionRoute {
    nodes: Vec<FiberRouteNode>,
}

#[derive(Clone, Deserialize)]
struct FiberRouteNode {
    pubkey: String,
    amount: String,
    channel_outpoint: String,
}

#[derive(Debug)]
struct ApiError(anyhow::Error);

impl<E> From<E> for ApiError
where
    E: Into<anyhow::Error>,
{
    fn from(value: E) -> Self {
        Self(value.into())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        error!("{:#}", self.0);
        (
            StatusCode::BAD_REQUEST,
            Json(json!({
                "error": self.0.to_string(),
            })),
        )
            .into_response()
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or_default()
}

fn to_hex_u64(value: u64) -> String {
    format!("0x{value:x}")
}

fn to_hex_u128(value: u128) -> String {
    format!("0x{value:x}")
}

fn hex_to_u64(value: &str) -> Result<u64> {
    let trimmed = value.trim_start_matches("0x");
    u64::from_str_radix(trimmed, 16).with_context(|| format!("invalid u64 hex {value}"))
}

fn hex_to_u128(value: &str) -> Result<u128> {
    let trimmed = value.trim_start_matches("0x");
    u128::from_str_radix(trimmed, 16).with_context(|| format!("invalid u128 hex {value}"))
}

fn bytes_to_hex(bytes: &[u8]) -> String {
    let mut output = String::with_capacity(2 + bytes.len() * 2);
    output.push_str("0x");
    for byte in bytes {
        output.push_str(&format!("{byte:02x}"));
    }
    output
}

fn hex_to_bytes(value: &str) -> Result<Vec<u8>> {
    let trimmed = value.trim_start_matches("0x");
    if trimmed.len() % 2 != 0 {
        bail!("hex string has odd length");
    }

    let mut output = Vec::with_capacity(trimmed.len() / 2);
    let bytes = trimmed.as_bytes();
    for index in (0..bytes.len()).step_by(2) {
        let chunk = std::str::from_utf8(&bytes[index..index + 2]).context("hex was not utf-8")?;
        let byte = u8::from_str_radix(chunk, 16)
            .with_context(|| format!("invalid byte {chunk} in hex string"))?;
        output.push(byte);
    }
    Ok(output)
}

fn short_pubkey(value: &str) -> String {
    if value.len() <= 14 {
        value.to_string()
    } else {
        format!("{}...{}", &value[..8], &value[value.len() - 4..])
    }
}

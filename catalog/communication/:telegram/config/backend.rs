//! TelegramConfig Node - Telegram Bot API credentials
//!
//! Stores the bot token. Connect its "config" output to
//! TelegramReceive (trigger) or TelegramSend nodes.

use async_trait::async_trait;
use crate::node::{Node, NodeMetadata, NodeFeatures, PortDef, ExecutionContext, FieldDef};
use crate::{NodeResult, register_node};

#[derive(Default)]
pub struct TelegramConfigNode;

#[async_trait]
impl Node for TelegramConfigNode {
    fn node_type(&self) -> &'static str {
        "TelegramConfig"
    }

    fn metadata(&self) -> NodeMetadata {
        NodeMetadata {
            label: "Telegram Config",
            inputs: vec![],
            outputs: vec![
                PortDef::new("config", "Dict[String, String]", false),
            ],
            features: NodeFeatures {
                ..Default::default()
            },
            fields: vec![
                FieldDef::password("botToken"),
            ],
        }
    }

    async fn execute(&self, ctx: ExecutionContext) -> NodeResult {
        let mut config = ctx.config.clone();
        let missing_token = config.get("botToken")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().is_empty())
            .unwrap_or(true);

        if missing_token {
            if let Ok(env_token) = std::env::var("TELEGRAM_BOT_TOKEN") {
                if !env_token.trim().is_empty() {
                    config["botToken"] = serde_json::json!(env_token);
                }
            }
        }

        NodeResult::completed(serde_json::json!({ "config": config }))
    }
}

register_node!(TelegramConfigNode);

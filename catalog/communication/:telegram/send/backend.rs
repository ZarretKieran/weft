//! TelegramSend Node - Send messages and media via Telegram Bot API.
//!
//! Uses POST /bot<token>/sendMessage for text, and sendPhoto/sendVideo/
//! sendAudio/sendDocument when a media object is provided.
//! Supports replies via replyToMessageId.

use async_trait::async_trait;
use crate::node::{Node, NodeMetadata, NodeFeatures, PortDef, ExecutionContext};
use crate::{NodeResult, register_node};
use base64::prelude::*;
use reqwest::multipart::{Form, Part};

fn decode_data_url(value: &str) -> Option<Vec<u8>> {
    let (_, encoded) = value.split_once(",")?;
    BASE64_STANDARD.decode(encoded).ok()
}

fn decode_media_bytes(media_obj: &serde_json::Value) -> Option<Vec<u8>> {
    if let Some(data) = media_obj.get("data").and_then(|v| v.as_str()) {
        if !data.is_empty() {
            if data.starts_with("data:") {
                return decode_data_url(data);
            }
            return BASE64_STANDARD.decode(data).ok();
        }
    }

    media_obj
        .get("url")
        .and_then(|v| v.as_str())
        .filter(|url| url.starts_with("data:"))
        .and_then(decode_data_url)
}

#[derive(Default)]
pub struct TelegramSendNode;

#[async_trait]
impl Node for TelegramSendNode {
    fn node_type(&self) -> &'static str {
        "TelegramSend"
    }

    fn metadata(&self) -> NodeMetadata {
        NodeMetadata {
            label: "Telegram Send",
            inputs: vec![
                PortDef::wired_only("config", "Dict[String, String]", true),
                PortDef::new("chatId", "String", true),
                PortDef::new("text", "String", false),
                PortDef::new("replyToMessageId", "String", false),
                PortDef::new("media", "Media", false),
            ],
            outputs: vec![
                PortDef::new("messageId", "String", false),
                PortDef::new("success", "Boolean", false),
            ],
            features: NodeFeatures {
                oneOfRequired: vec![vec!["text".into(), "media".into()]],
                ..Default::default()
            },
            fields: vec![],
        }
    }

    async fn execute(&self, ctx: ExecutionContext) -> NodeResult {
        let text = ctx.input.get("text")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        let mut chat_id = ctx.input.get("chatId")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        if chat_id.trim().is_empty() {
            if let Ok(env_chat_id) = std::env::var("TELEGRAM_CHAT_ID") {
                if !env_chat_id.trim().is_empty() {
                    chat_id = env_chat_id;
                }
            }
        }

        let reply_to = ctx.input.get("replyToMessageId")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty());

        let media = ctx.input.get("media")
            .filter(|v| v.is_object() && !v.as_object().unwrap().is_empty());

        let bot_token = ctx.input.get("config")
            .and_then(|v| v.get("botToken"))
            .and_then(|v| v.as_str())
            .unwrap_or("");

        if bot_token.is_empty() {
            return NodeResult::failed("Telegram bot token is required. Connect a TelegramConfig node.");
        }

        if chat_id.trim().is_empty() {
            return NodeResult::failed("Chat ID is required");
        }

        if text.is_empty() && media.is_none() {
            return NodeResult::failed("Either text or media is required");
        }

        let client = reqwest::Client::new();

        let response = if let Some(media_obj) = media {
            let media_url = media_obj.get("url").and_then(|v| v.as_str()).unwrap_or("");
            let mime = media_obj.get("mimeType").and_then(|v| v.as_str()).unwrap_or("");
            let media_type = weft_core::media_category_from_mime(mime);
            let filename = media_obj.get("filename")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .unwrap_or(match media_type {
                    "image" => "image.jpg",
                    "video" => "video.mp4",
                    "audio" => "audio.mp3",
                    _ => "attachment",
                });
            let force_document = media_obj.get("telegramSendAsDocument")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            let inline_bytes = decode_media_bytes(media_obj);

            if media_url.is_empty() && inline_bytes.is_none() {
                let mut body = serde_json::json!({ "chat_id": chat_id, "text": text });
                if let Some(reply_id) = reply_to {
                    body["reply_parameters"] = serde_json::json!({ "message_id": reply_id.parse::<i64>().unwrap_or(0) });
                }
                client
                    .post(format!("https://api.telegram.org/bot{}/sendMessage", bot_token))
                    .header("Content-Type", "application/json")
                    .json(&body)
                    .send()
                    .await
            } else if let Some(bytes) = inline_bytes {
                let preserve_image_quality = media_type == "image";
                let (method, field_name) = if force_document || preserve_image_quality {
                    ("sendDocument", "document")
                } else {
                    match media_type {
                        "video" => ("sendVideo", "video"),
                        "audio" => ("sendAudio", "audio"),
                        _ => ("sendDocument", "document"),
                    }
                };

                let part = if !mime.is_empty() {
                    Part::bytes(bytes.clone())
                        .file_name(filename.to_string())
                        .mime_str(mime)
                        .unwrap_or_else(|_| Part::bytes(bytes).file_name(filename.to_string()))
                } else {
                    Part::bytes(bytes).file_name(filename.to_string())
                };

                let mut form = Form::new()
                    .text("chat_id", chat_id.clone())
                    .part(field_name.to_string(), part);

                if !text.is_empty() {
                    form = form.text("caption", text.to_string());
                }
                if let Some(reply_id) = reply_to {
                    form = form.text("reply_to_message_id", reply_id.to_string());
                }

                client
                    .post(format!("https://api.telegram.org/bot{}/{}", bot_token, method))
                    .multipart(form)
                    .send()
                    .await
            } else {
                let (method, field_name) = if force_document {
                    ("sendDocument", "document")
                } else {
                    match media_type {
                        "image" => ("sendPhoto", "photo"),
                        "video" => ("sendVideo", "video"),
                        "audio" => ("sendAudio", "audio"),
                        _ => ("sendDocument", "document"),
                    }
                };

                let mut body = serde_json::json!({
                    "chat_id": chat_id,
                    field_name: media_url,
                });
                if !text.is_empty() {
                    body["caption"] = serde_json::json!(text);
                }
                if let Some(reply_id) = reply_to {
                    body["reply_parameters"] = serde_json::json!({ "message_id": reply_id.parse::<i64>().unwrap_or(0) });
                }

                client
                    .post(format!("https://api.telegram.org/bot{}/{}", bot_token, method))
                    .header("Content-Type", "application/json")
                    .json(&body)
                    .send()
                    .await
            }
        } else {
            let mut body = serde_json::json!({ "chat_id": chat_id, "text": text });
            if let Some(reply_id) = reply_to {
                body["reply_parameters"] = serde_json::json!({ "message_id": reply_id.parse::<i64>().unwrap_or(0) });
            }
            client
                .post(format!("https://api.telegram.org/bot{}/sendMessage", bot_token))
                .header("Content-Type", "application/json")
                .json(&body)
                .send()
                .await
        };

        match response {
            Ok(resp) => {
                if resp.status().is_success() {
                    let resp_body: serde_json::Value = resp.json().await.unwrap_or_default();
                    let message_id = resp_body.get("result")
                        .and_then(|r| r.get("message_id"))
                        .and_then(|v| v.as_i64())
                        .map(|id| id.to_string())
                        .unwrap_or_default();

                    NodeResult::completed(serde_json::json!({
                        "messageId": message_id,
                        "success": true,
                    }))
                } else {
                    let status = resp.status();
                    let error_text = resp.text().await.unwrap_or_default();
                    tracing::error!("Telegram API error: {} - {}", status, error_text);
                    NodeResult::completed(serde_json::json!({
                        "messageId": "",
                        "success": false,
                    }))
                }
            }
            Err(e) => {
                tracing::error!("Telegram request failed: {}", e);
                NodeResult::failed(&format!("Failed to send Telegram message: {}", e))
            }
        }
    }
}

register_node!(TelegramSendNode);

//! Code Node - Execute Python code in an isolated sandbox.
//!
//! **Inputs**: Each input port becomes a Python variable with the port's name.
//! For example, if you have input ports "data" and "config", your code can
//! directly reference `data` and `config` as variables. Unconnected ports are `None`.
//!
//! **Outputs**: Return a dict where keys are output port names.
//! For example: `return {"approved": result, "rejected": None}`
//! Only ports with non-None values will continue the flow.
//!
//! **Dependencies**: Optional pip packages listed in config (one per line).
//! Pre-installed packages are available instantly. Others are installed at runtime.
//!
//! ## Security
//!
//! On Linux (production), code runs inside nsjail with:
//! - PID/mount namespace isolation
//! - Resource limits (CPU, memory, wall-clock time)
//! - Network access with internal IP blocking
//!
//! On other platforms (local dev), code runs without sandbox restrictions.

use async_trait::async_trait;
use crate::node::{Node, NodeMetadata, NodeFeatures, ExecutionContext, FieldDef};
use crate::sandbox::{SandboxExecution, SandboxResult};
use crate::{NodeResult, register_node};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use weft_core::node::SandboxSpec;

/// Code node for executing Python code.
#[derive(Default)]
pub struct CodeNode;

fn sandbox_spec() -> SandboxSpec {
    SandboxSpec {
        system_packages: vec!["ffmpeg".into()],
        cpu_limit_secs: 30,
        memory_limit_mb: 512,
        timeout_secs: 60,
        allow_network: true,
    }
}

#[async_trait]
impl Node for CodeNode {
    fn node_type(&self) -> &'static str {
        "ExecPython"
    }

    fn metadata(&self) -> NodeMetadata {
        NodeMetadata {
            label: "Code",
            inputs: vec![],
            outputs: vec![],
            features: NodeFeatures {
                canAddInputPorts: true,
                canAddOutputPorts: true,
                sandboxSpec: Some(sandbox_spec()),
                ..Default::default()
            },
            fields: vec![
                FieldDef::code("code"),
                FieldDef::code("dependencies"),
            ],
        }
    }

    async fn execute(&self, ctx: ExecutionContext) -> NodeResult {
        let code = ctx.config.get("code")
            .and_then(|v| v.as_str())
            .unwrap_or("return {}");

        let dependencies = ctx.config.get("dependencies")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        tracing::debug!("Code execution: code_len={}, deps={}", code.len(), dependencies);

        execute_python(code, dependencies, &ctx.input).await
    }
}

async fn execute_python(
    code: &str,
    dependencies: &str,
    input: &serde_json::Value,
) -> NodeResult {
    // Encode arguments as base64 for safe passing to subprocess
    let code_b64 = BASE64.encode(code.as_bytes());
    let input_json = serde_json::to_string(input).unwrap_or_else(|_| "{}".to_string());
    let input_b64 = BASE64.encode(input_json.as_bytes());

    // Parse dependencies (one per line, skip empty lines and comments)
    let deps: Vec<String> = dependencies.lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .collect();
    let deps_json = serde_json::to_string(&deps).unwrap_or_else(|_| "[]".to_string());
    let deps_b64 = BASE64.encode(deps_json.as_bytes());

    // Resolve sandbox runner script path
    let sandbox_script = resolve_script_path("sandbox_runner.py");

    let result = SandboxExecution {
        command: vec![
            "/usr/bin/python3".into(),
            sandbox_script,
            code_b64,
            input_b64,
            deps_b64,
        ],
        spec: sandbox_spec(),
    }.run().await;

    handle_sandbox_result(&result)
}

fn resolve_script_path(filename: &str) -> String {
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|p| p.to_path_buf()));

    let candidates = [
        exe_dir.as_ref().map(|d| d.join(format!("nodes/exec_python/src/{}", filename))),
        Some(std::path::PathBuf::from(format!(
            "crates/weft-nodes/src/nodes/exec_python/src/{}", filename
        ))),
    ];

    candidates.iter()
        .flatten()
        .find(|p| p.exists())
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|| filename.to_string())
}

fn handle_sandbox_result(result: &SandboxResult) -> NodeResult {
    // Log stderr lines for debugging
    for line in result.stderr.lines() {
        if line.starts_with("SANDBOX_") || line.starts_with("PIP_") {
            tracing::debug!("{}", line);
        }
    }

    if !result.success {
        let error_lines: Vec<&str> = result.stderr.lines()
            .filter(|l| !l.starts_with("SANDBOX_") && !l.starts_with("PIP_"))
            .collect();
        let error_msg = if error_lines.is_empty() {
            "Code execution failed with no error output".to_string()
        } else {
            error_lines.join("\n")
        };
        tracing::error!("Python execution failed: {}", error_msg);
        return NodeResult::failed(&format!("Python error: {}", error_msg));
    }

    parse_python_output(&result.stdout)
}

fn parse_python_output(stdout: &str) -> NodeResult {
    let result = stdout.trim();

    let output_value: serde_json::Value = if result.is_empty() {
        serde_json::json!({})
    } else {
        match serde_json::from_str(result) {
            Ok(v) => v,
            Err(e) => {
                tracing::error!("Failed to parse Python output as JSON: {}", e);
                return NodeResult::failed(&format!("Invalid output format: {}", e));
            }
        }
    };

    NodeResult::completed(output_value)
}

register_node!(CodeNode);

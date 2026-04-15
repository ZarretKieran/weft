//! Shared sandbox executor for nodes that run untrusted code.
//!
//! On Linux (production): wraps execution with nsjail for process isolation
//! (PID/network namespaces, resource limits, seccomp). Mount namespace is
//! disabled since GKE Autopilot doesn't allow SYS_ADMIN.
//!
//! On non-Linux (development): runs the command directly without isolation.
//!
//! Nodes declare a `SandboxSpec` in their features and call `SandboxExecution::run()`
//! instead of implementing their own isolation logic.

use std::process::Stdio;
use tokio::process::Command;
use tokio::sync::Semaphore;
use weft_core::node::SandboxSpec;

/// Limit concurrent sandbox executions to avoid overwhelming the pod.
/// Each execution spawns nsjail + Python. Keep low for small machines.
static SANDBOX_SEMAPHORE: Semaphore = Semaphore::const_new(5);

/// A sandboxed command execution request.
pub struct SandboxExecution {
    /// Command and arguments to run inside the sandbox (e.g., ["python3", "runner.py", ...])
    pub command: Vec<String>,
    /// Sandbox configuration from the node's features
    pub spec: SandboxSpec,
}

/// Result of a sandboxed execution.
pub struct SandboxResult {
    pub stdout: String,
    pub stderr: String,
    pub success: bool,
}

impl SandboxExecution {
    /// Run the command, isolated if on Linux, direct otherwise.
    /// Concurrency is limited by SANDBOX_SEMAPHORE to prevent pod OOM.
    pub async fn run(&self) -> SandboxResult {
        let _permit = SANDBOX_SEMAPHORE.acquire().await.expect("semaphore closed");
        if !is_sandbox_enabled() {
            // Explicitly disabled via CODE_SANDBOX_ENABLED=false
            self.run_direct().await
        } else if cfg!(target_os = "linux") {
            if !nsjail_available() {
                return SandboxResult {
                    stdout: String::new(),
                    stderr: "Sandbox execution required but nsjail is not installed. Set CODE_SANDBOX_ENABLED=false to disable sandboxing.".into(),
                    success: false,
                };
            }
            self.run_nsjail().await
        } else {
            // Non-Linux (macOS/Windows): nsjail not supported, run direct
            self.run_direct().await
        }
    }

    /// Run with nsjail isolation (Linux production).
    async fn run_nsjail(&self) -> SandboxResult {
        let mut args: Vec<String> = Vec::new();

        // Mode: execute once and exit
        args.push("--mode".into());
        args.push("o".into());

        // Resource limits
        args.push("--rlimit_cpu".into());
        args.push(self.spec.cpu_limit_secs.to_string());
        args.push("--rlimit_as".into());
        args.push(format!("{}", self.spec.memory_limit_mb));
        args.push("--time_limit".into());
        args.push(self.spec.timeout_secs.to_string());

        // PID namespace is enabled by default in nsjail (can't see host processes)

        // Mount namespace disabled: GKE Autopilot doesn't allow SYS_ADMIN capability
        // which is required for mount namespace operations. Container isolation provides
        // the filesystem boundary instead. When we move to per-execution containers (A3),
        // the container itself becomes the full sandbox and this restriction is removed.
        // TODO(A3): Remove --disable_clone_newns and filesystem restrictions when
        // per-execution containers are implemented. Python code should then have full
        // access to the container's filesystem for cross-language file sharing.
        args.push("--disable_clone_newns".into());

        // Restrict working directory to /tmp (only writable location for nobody)
        args.push("--cwd".into());
        args.push("/tmp".into());

        // nsjail clears all env vars by default (--keep_env is off).
        // Only pass what Python needs. No secrets leak.
        args.push("--env".into());
        args.push("HOME=/tmp".into());
        args.push("--env".into());
        args.push("PATH=/usr/local/bin:/usr/bin:/bin".into());
        args.push("--env".into());
        args.push("PYTHONDONTWRITEBYTECODE=1".into());

        // Run as nobody inside the jail
        args.push("--user".into());
        args.push("65534".into());
        args.push("--group".into());
        args.push("65534".into());

        // Network handling
        if !self.spec.allow_network {
            // No network at all: create a new empty network namespace
            // (nsjail enables clone_newnet by default, which gives an isolated network ns)
        } else {
            // Allow network but keep host stack (disable new network namespace)
            args.push("--disable_clone_newnet".into());
            // Internal IP blocking is handled via iptables rules set up at container startup
        }

        // Log nsjail errors to stderr (but not info-level noise)
        args.push("--log_fd".into());
        args.push("2".into());
        args.push("--verbose".into());

        // Separator between nsjail args and the actual command
        args.push("--".into());

        // The actual command to execute
        args.extend(self.command.clone());

        tracing::debug!("nsjail args: {:?}", args);

        let child = match Command::new("nsjail")
            .args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(child) => child,
            Err(e) => {
                tracing::error!("Failed to spawn nsjail: {}", e);
                return SandboxResult {
                    stdout: String::new(),
                    stderr: format!("Failed to spawn sandbox: {}", e),
                    success: false,
                };
            }
        };

        let timeout = std::time::Duration::from_secs(self.spec.timeout_secs as u64 + 5);
        match tokio::time::timeout(timeout, child.wait_with_output()).await {
            Ok(Ok(output)) => SandboxResult {
                stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
                stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
                success: output.status.success(),
            },
            Ok(Err(e)) => SandboxResult {
                stdout: String::new(),
                stderr: format!("Sandbox execution error: {}", e),
                success: false,
            },
            Err(_) => SandboxResult {
                stdout: String::new(),
                stderr: format!("Sandbox execution timed out ({}s limit)", self.spec.timeout_secs),
                success: false,
            },
        }
    }

    /// Run directly without isolation (development).
    async fn run_direct(&self) -> SandboxResult {
        if self.command.is_empty() {
            return SandboxResult {
                stdout: String::new(),
                stderr: "Empty command".into(),
                success: false,
            };
        }

        let child = match Command::new(&self.command[0])
            .args(&self.command[1..])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(child) => child,
            Err(e) => {
                return SandboxResult {
                    stdout: String::new(),
                    stderr: format!("Failed to spawn process: {}", e),
                    success: false,
                };
            }
        };

        let timeout = std::time::Duration::from_secs(self.spec.timeout_secs as u64 + 5);
        match tokio::time::timeout(timeout, child.wait_with_output()).await {
            Ok(Ok(output)) => SandboxResult {
                stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
                stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
                success: output.status.success(),
            },
            Ok(Err(e)) => SandboxResult {
                stdout: String::new(),
                stderr: format!("Execution error: {}", e),
                success: false,
            },
            Err(_) => SandboxResult {
                stdout: String::new(),
                stderr: format!("Execution timed out ({}s limit)", self.spec.timeout_secs),
                success: false,
            },
        }
    }
}

/// Check if sandboxing is enabled via environment variable.
fn is_sandbox_enabled() -> bool {
    std::env::var("CODE_SANDBOX_ENABLED")
        .map(|v| v != "false")
        .unwrap_or(true)
}

/// Check if nsjail binary is available.
fn nsjail_available() -> bool {
    use std::sync::OnceLock;
    static AVAILABLE: OnceLock<bool> = OnceLock::new();
    *AVAILABLE.get_or_init(|| {
        // Check common paths (don't use --help, some versions return non-zero)
        let found = std::path::Path::new("/usr/local/bin/nsjail").exists()
            || which_in_path("nsjail");
        if !found {
            tracing::warn!("nsjail binary not found");
        } else {
            tracing::info!("nsjail binary found, sandbox enabled");
        }
        found
    })
}

fn which_in_path(name: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| {
            std::env::split_paths(&paths)
                .any(|dir| dir.join(name).exists())
        })
        .unwrap_or(false)
}

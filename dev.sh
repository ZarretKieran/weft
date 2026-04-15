#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables from root .env
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
    echo -e "${GREEN}✓ Loaded environment from .env${NC}"
fi

# Default to local mode if not explicitly set. The Rust backend's
# `is_local_mode()` and the dashboard's `hooks.server.ts` both key
# off `DEPLOYMENT_MODE=local` to skip credit checks, JWT auth, and
# other cloud-only gates that a standalone OSS install doesn't
# have the infrastructure for. A fresh clone without .env should
# still boot cleanly, so we default here.
export DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-local}"

# Generate catalog symlinks (idempotent)
# catalog-link.sh needs Bash 4+ (associative arrays). Use Homebrew bash on macOS if available.
CATALOG_BASH="bash"
if [[ "$(uname)" == "Darwin" ]] && [[ -x /opt/homebrew/bin/bash ]]; then
    CATALOG_BASH="/opt/homebrew/bin/bash"
elif [[ "$(uname)" == "Darwin" ]] && [[ -x /usr/local/bin/bash ]]; then
    CATALOG_BASH="/usr/local/bin/bash"
fi
$CATALOG_BASH "$SCRIPT_DIR/scripts/catalog-link.sh"

# Ensure PostgreSQL is running for local dev (skipped if DATABASE_URL already set)
if [ -z "${DATABASE_URL:-}" ]; then
    echo -e "${BLUE}Setting up local PostgreSQL...${NC}"
    bash "$SCRIPT_DIR/init-db.sh"
    export DATABASE_URL="postgres://postgres:postgres@localhost:5433/weft_local"
    echo -e "${GREEN}✓ DATABASE_URL=${DATABASE_URL}${NC}"
fi

# Function to show usage
show_usage() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}   Weft Dev Script${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "Usage: ./dev.sh <command>"
    echo ""
    echo "Commands:"
    echo "  server      Start the backend (Restate + all-in-one project server) [default]"
    echo "  orchestrator  Start only the orchestrator (no node executors)"
    echo "  node-runner   Start standalone node service (configure via NODE_TYPES env)"
    echo "  dashboard   Start the frontend dashboard (SvelteKit)"
    echo "  extension   Start the browser extension dev mode (WXT)"
    echo "  all         Start both server and dashboard"
    echo "  help        Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./dev.sh server     # Start backend only"
    echo "  ./dev.sh dashboard  # Start frontend only"
    echo "  ./dev.sh all        # Start everything"
    echo ""
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if a port is in use
port_in_use() {
    lsof -i :"$1" >/dev/null 2>&1 || ss -tuln 2>/dev/null | grep -q ":$1 " || netstat -tuln 2>/dev/null | grep -q ":$1 "
}

# Function to wait for a service to be ready
wait_for_port() {
    local port=$1
    local name=$2
    local max_attempts=30
    local attempt=0
    
    echo -e "${YELLOW}Waiting for $name on port $port...${NC}"
    while ! port_in_use "$port" && [ $attempt -lt $max_attempts ]; do
        sleep 1
        attempt=$((attempt + 1))
    done
    
    if [ $attempt -eq $max_attempts ]; then
        echo -e "${RED}Timeout waiting for $name${NC}"
        return 1
    fi
    echo -e "${GREEN}$name is ready!${NC}"
}

# Detect OS and architecture for Restate binary download
detect_platform() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch=$(uname -m)
    
    case "$os" in
        linux) os="unknown-linux-musl" ;;
        darwin) os="apple-darwin" ;;
        *) echo "Unsupported OS: $os"; exit 1 ;;
    esac
    
    case "$arch" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) echo "Unsupported architecture: $arch"; exit 1 ;;
    esac
    
    echo "${arch}-${os}"
}

# ============================================
# LOCAL K8S INFRASTRUCTURE
# Auto-creates kind cluster and builds/loads sidecar images
# ============================================

KIND_CLUSTER_NAME="weft-local"

# Compute a content hash for a sidecar directory (includes sidecar source + sidecar-lib).
# Used to detect when sidecar source has changed and the image needs rebuilding.
sidecar_source_hash() {
    local sidecar_name="$1"
    local hash_input=""
    
    # Hash sidecar-specific source (Rust + JS/TS sidecars)
    # -L follows symlinks (sidecars/ entries are symlinks into catalog/)
    if [ -e "$SCRIPT_DIR/sidecars/$sidecar_name" ]; then
        hash_input+="$(find -L "$SCRIPT_DIR/sidecars/$sidecar_name" -type f \( -name '*.rs' -o -name '*.toml' -o -name '*.js' -o -name '*.ts' -o -name '*.json' \) ! -path '*/node_modules/*' | sort | xargs cat 2>/dev/null)"
    fi
    
    # Sidecars are now self-contained (no shared lib).
    
    if command_exists sha256sum; then
        echo -n "$hash_input" | sha256sum | cut -d' ' -f1
    else
        echo -n "$hash_input" | shasum -a 256 | cut -d' ' -f1
    fi
}

ensure_local_k8s_infra() {
    # 1. Ensure kind is installed
    if ! command_exists kind; then
        echo -e "${RED}kind not installed. Install it:${NC}"
        echo "  curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64"
        echo "  chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind"
        exit 1
    fi

    # 2. Ensure docker is running
    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}Docker is not running. Start Docker first.${NC}"
        exit 1
    fi

    # 3. Ensure kind cluster exists
    if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
        echo -e "${GREEN}✓ Kind cluster '${KIND_CLUSTER_NAME}' exists${NC}"
    else
        echo -e "${YELLOW}Creating kind cluster '${KIND_CLUSTER_NAME}'...${NC}"
        kind create cluster --name "$KIND_CLUSTER_NAME" --wait 60s
        echo -e "${GREEN}✓ Kind cluster created${NC}"
    fi

    # 4. Set kubectl context
    kubectl config use-context "kind-${KIND_CLUSTER_NAME}" >/dev/null 2>&1
    if ! kubectl cluster-info >/dev/null 2>&1; then
        echo -e "${RED}Cannot connect to kind cluster${NC}"
        exit 1
    fi

    # 5. Auto-discover and build sidecar images (rebuild if source changed)
    if [ -d "$SCRIPT_DIR/sidecars" ]; then
        for sidecar_dir in "$SCRIPT_DIR/sidecars"/*/; do
            [ -d "$sidecar_dir" ] || continue
            
            local sidecar_name=$(basename "$sidecar_dir")
            local dockerfile="$sidecar_dir/Dockerfile"
            
            # Skip if no Dockerfile
            if [ ! -f "$dockerfile" ]; then
                echo -e "${YELLOW}Skipping $sidecar_name (no Dockerfile found)${NC}"
                continue
            fi
            
            local image_tag="ghcr.io/weavemindai/sidecar-$sidecar_name:latest"
            local image_repo="${image_tag%%:*}"
            
            local needs_build=false
            local current_hash
            current_hash="$(sidecar_source_hash "$sidecar_name")"
            
            # Check if image exists in kind
            if docker exec "${KIND_CLUSTER_NAME}-control-plane" crictl images 2>/dev/null | grep -q "$image_repo"; then
                # Image exists, check if source changed since last build
                local stored_hash
                stored_hash="$(docker inspect --format='{{index .Config.Labels "dev.weft.source-hash"}}' "$image_tag" 2>/dev/null || echo "")"
                if [ "$stored_hash" != "$current_hash" ]; then
                    echo -e "${YELLOW}Source changed for $sidecar_name, rebuilding...${NC}"
                    needs_build=true
                else
                    echo -e "${GREEN}✓ Sidecar $sidecar_name up to date${NC}"
                fi
            else
                needs_build=true
            fi
            
            if [ "$needs_build" = true ]; then
                echo -e "${YELLOW}Building sidecar: $sidecar_name${NC}"
                docker build \
                    --label "dev.weft.source-hash=$current_hash" \
                    -t "$image_tag" \
                    -f "$dockerfile" \
                    "$SCRIPT_DIR"
                echo -e "${YELLOW}Loading $image_tag into kind...${NC}"
                kind load docker-image "$image_tag" --name "$KIND_CLUSTER_NAME"
                echo -e "${GREEN}✓ Sidecar $sidecar_name built and loaded${NC}"
                
                # Restart any running deployments that use this image so they pick up the new build
                for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
                    case "$ns" in wm-*)
                        for dep_name in $(kubectl get deploy -n "$ns" -o jsonpath="{range .items[?(@.spec.template.spec.containers[0].image==\"$image_tag\")]}{.metadata.name}{\"\\n\"}{end}" 2>/dev/null); do
                            [ -z "$dep_name" ] && continue
                            echo -e "${YELLOW}Restarting deployment $dep_name in $ns (image updated)${NC}"
                            kubectl rollout restart deploy "$dep_name" -n "$ns" 2>/dev/null || true
                        done
                        ;;
                    esac
                done
            fi
        done
    fi

    echo -e "${GREEN}✓ Local K8s infrastructure ready${NC}"
}

# ============================================
# SERVER (Backend) Functions - DISTRIBUTED MODE
# Runs all split services in parallel
# ============================================
start_server() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}   Weft Server (Distributed)${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    cd "$SCRIPT_DIR"
    
    # Load .env file if it exists
    if [ -f ".env" ]; then
        set -a
        source .env
        set +a
    fi
    
    # Configuration - Use env vars with defaults
    RESTATE_PORT="${RESTATE_PORT:-8080}"
    RESTATE_ADMIN_PORT="${RESTATE_ADMIN_PORT:-9070}"
    RESTATE_RPC_PORT="${RESTATE_RPC_PORT:-5122}"
    RESTATE_CLUSTER_NAME="${RESTATE_CLUSTER_NAME:-localcluster}"
    RESTATE_DATA_DIR="${RESTATE_DATA_DIR:-./restate-data}"
    ORCHESTRATOR_PORT="${ORCHESTRATOR_PORT:-9080}"
    NODE_RUNNER_PORT="${NODE_RUNNER_PORT:-9082}"
    
    # Track all PIDs for cleanup
    declare -a SERVICE_PIDS
    
    # Step 1: Check dependencies
    echo -e "\n${BLUE}[1/6] Checking dependencies...${NC}"
    
    # Check Rust/Cargo
    if ! command_exists cargo; then
        echo -e "${YELLOW}Cargo not found. Installing Rust via rustup...${NC}"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi
    RUST_VERSION=$(rustc --version 2>/dev/null || echo "unknown")
    echo -e "${GREEN}✓ Rust installed ($RUST_VERSION)${NC}"
    
    # Check Restate Server and CLI
    if ! command_exists restate-server || ! command_exists restate; then
        echo -e "${YELLOW}Restate not found. Installing...${NC}"
        
        if command_exists brew; then
            echo -e "${BLUE}Installing via Homebrew...${NC}"
            brew install restatedev/tap/restate-server restatedev/tap/restate
        elif command_exists npm; then
            echo -e "${BLUE}Installing via npm...${NC}"
            npm install --global @restatedev/restate-server@latest @restatedev/restate@latest
        else
            echo -e "${BLUE}Installing via binary download...${NC}"
            RESTATE_PLATFORM=$(detect_platform)
            BIN_DIR="${HOME}/.local/bin"
            mkdir -p "$BIN_DIR"
            
            cd /tmp
            curl -L --remote-name-all \
                "https://restate.gateway.scarf.sh/latest/restate-server-${RESTATE_PLATFORM}.tar.xz" \
                "https://restate.gateway.scarf.sh/latest/restate-cli-${RESTATE_PLATFORM}.tar.xz"
            
            tar -xvf "restate-server-${RESTATE_PLATFORM}.tar.xz" --strip-components=1 "restate-server-${RESTATE_PLATFORM}/restate-server"
            tar -xvf "restate-cli-${RESTATE_PLATFORM}.tar.xz" --strip-components=1 "restate-cli-${RESTATE_PLATFORM}/restate"
            
            chmod +x restate restate-server
            mv restate restate-server "$BIN_DIR/"
            
            if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
                export PATH="$BIN_DIR:$PATH"
                echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$HOME/.bashrc"
                echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$HOME/.zshrc" 2>/dev/null || true
            fi
            
            cd "$SCRIPT_DIR"
            rm -f /tmp/restate-*.tar.xz
        fi
    fi
    RESTATE_VERSION=$(restate --version 2>/dev/null || echo "unknown")
    echo -e "${GREEN}✓ Restate installed ($RESTATE_VERSION)${NC}"
    
    # Step 1b: If local K8s mode, ensure kind cluster exists and sidecar images are loaded
    if [ "$INFRASTRUCTURE_TARGET" = "local" ]; then
        echo -e "\n${BLUE}[1c/7] Ensuring local K8s infrastructure...${NC}"
        ensure_local_k8s_infra
    fi
    
    # Step 2: Build the Rust project
    echo -e "\n${BLUE}[2/7] Building Rust project...${NC}"
    cargo build --release
    echo -e "${GREEN}✓ Build complete${NC}"
    
    # Step 3: Start Restate server if not running
    echo -e "\n${BLUE}[3/6] Starting Restate server...${NC}"
    
    if port_in_use $RESTATE_PORT; then
        echo -e "${GREEN}✓ Restate server already running on port $RESTATE_PORT${NC}"
    else
        echo -e "${YELLOW}Starting Restate server on port $RESTATE_PORT...${NC}"
        # Use config file if custom ports, otherwise use defaults
        if [ "$RESTATE_PORT" != "8080" ] || [ "$RESTATE_ADMIN_PORT" != "9070" ] || [ "$RESTATE_RPC_PORT" != "5122" ]; then
            # Generate config file for custom ports
            cat > "$RESTATE_DATA_DIR.toml" << EOF
cluster-name = "$RESTATE_CLUSTER_NAME"
bind-address = "0.0.0.0:$RESTATE_RPC_PORT"
advertised-address = "http://127.0.0.1:$RESTATE_RPC_PORT/"
auto-provision = true

# Short default retention,heartbeats and list_tasks get cleaned up quickly
default-journal-retention = "10m"

[admin]
bind-address = "0.0.0.0:$RESTATE_ADMIN_PORT"

[ingress]
bind-address = "0.0.0.0:$RESTATE_PORT"

[worker]
cleanup-interval = "5m"

[metadata-client]
addresses = ["http://127.0.0.1:$RESTATE_RPC_PORT/"]
EOF
            restate-server --config-file "$RESTATE_DATA_DIR.toml" --base-dir "$RESTATE_DATA_DIR" &
        else
            restate-server --base-dir "$RESTATE_DATA_DIR" &
        fi
        RESTATE_PID=$!
        SERVICE_PIDS+=($RESTATE_PID)
        wait_for_port $RESTATE_PORT "Restate server"
        echo -e "${GREEN}✓ Restate server started (PID: $RESTATE_PID)${NC}"
    fi
    
    # Step 4: Start Orchestrator
    echo -e "\n${BLUE}[4/6] Starting Orchestrator...${NC}"
    
    if port_in_use $ORCHESTRATOR_PORT; then
        echo -e "${YELLOW}Stopping existing process on port $ORCHESTRATOR_PORT...${NC}"
        kill $(lsof -t -i:$ORCHESTRATOR_PORT) 2>/dev/null || true
        sleep 1
    fi
    
    ORCHESTRATOR_PORT=$ORCHESTRATOR_PORT RESTATE_PORT=$RESTATE_PORT RESTATE_URL="http://localhost:$RESTATE_PORT" cargo run --release --bin orchestrator &
    ORCHESTRATOR_PID=$!
    SERVICE_PIDS+=($ORCHESTRATOR_PID)
    wait_for_port $ORCHESTRATOR_PORT "Orchestrator"
    echo -e "${GREEN}✓ Orchestrator started (PID: $ORCHESTRATOR_PID)${NC}"
    
    # Step 5: Register orchestrator with Restate
    echo -e "\n${BLUE}[5/6] Registering orchestrator with Restate...${NC}"
    sleep 2
    
    # Set admin URL for restate CLI
    export RESTATE_ADMIN_URL="http://localhost:$RESTATE_ADMIN_PORT"
    
    if restate deployments register http://localhost:$ORCHESTRATOR_PORT --force --yes 2>/dev/null; then
        echo -e "${GREEN}✓ Orchestrator registered successfully${NC}"
    else
        echo -e "${YELLOW}Registration may have failed or already exists. Trying to update...${NC}"
        restate deployments register http://localhost:$ORCHESTRATOR_PORT --force --yes || true
    fi
    
    # Step 6: Start Weft API (trigger management)
    echo -e "\n${BLUE}[6/7] Starting Weft API...${NC}"
    
    WEFT_API_PORT="${WEFT_API_PORT:-3000}"
    PORT=$WEFT_API_PORT RESTATE_URL="http://localhost:$RESTATE_PORT" DASHBOARD_URL="http://localhost:5174" \
        cargo run --release --bin weft-api &
    WEFT_API_PID=$!
    SERVICE_PIDS+=($WEFT_API_PID)
    wait_for_port $WEFT_API_PORT "Weft API"
    echo -e "${GREEN}✓ Weft API started (PID: $WEFT_API_PID, port: $WEFT_API_PORT)${NC}"
    
    # Step 7: Start unified Node Runner (handles all node types)
    echo -e "\n${BLUE}[7/7] Starting Node Runner...${NC}"
    
    NODE_RUNNER_PORT="${NODE_RUNNER_PORT:-9082}"
    
    NODE_ID="node-runner-local" NODE_PORT=$NODE_RUNNER_PORT ORCHESTRATOR_URL="http://localhost:$RESTATE_PORT" \
        cargo run --release --bin node-runner &
    NODE_RUNNER_PID=$!
    SERVICE_PIDS+=($NODE_RUNNER_PID)
    
    wait_for_port $NODE_RUNNER_PORT "Node Runner"
    echo -e "${GREEN}✓ Node Runner started (PID: $NODE_RUNNER_PID, port: $NODE_RUNNER_PORT) [all node types]${NC}"
    
    # Infrastructure scan: report existing K8s resources in wm-* namespaces
    if [ "$INFRASTRUCTURE_TARGET" = "local" ]; then
        echo -e "\n${BLUE}[infra] Scanning K8s infrastructure resources...${NC}"
        (
            set +e
            resource_count=0
            for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
                case "$ns" in wm-*)
                    for dep_name in $(kubectl get deploy -n "$ns" -l "weavemind.ai/managed-by=weavemind" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
                        [ -z "$dep_name" ] && continue
                        replicas=$(kubectl get deploy "$dep_name" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null)
                        ready=$(kubectl get deploy "$dep_name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
                        echo -e "  ${BLUE}[k8s] ${dep_name} in ${ns}, replicas: ${replicas:-0}, ready: ${ready:-0}${NC}"
                        resource_count=$((resource_count + 1))
                    done
                    ;;
                esac
            done
            if [ "$resource_count" -eq 0 ]; then
                echo -e "  ${GREEN}No infrastructure resources found${NC}"
            else
                echo -e "  ${GREEN}Found $resource_count infrastructure deployment(s)${NC}"
            fi
        )
        echo -e "${GREEN}✓ Infrastructure scan complete${NC}"
    fi

    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}   All Services Running${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "  Restate Server:    http://localhost:$RESTATE_PORT"
    echo -e "  Restate Admin:     http://localhost:$RESTATE_ADMIN_PORT"
    echo -e "  Orchestrator:      http://localhost:$ORCHESTRATOR_PORT"
    echo -e "  Weft API:     http://localhost:$WEFT_API_PORT (triggers)"
    echo -e "  Node Runner:       http://localhost:$NODE_RUNNER_PORT (all node types)"

    # Port-forwarding for local K8s infra services is handled automatically
    # by infra_helpers.rs (unique hashed ports per sidecar, auto kubectl port-forward).
    if [ "$INFRASTRUCTURE_TARGET" = "local" ]; then
        echo -e "  Infra Target:      local (port-forwards managed by orchestrator)"
    fi

    echo -e "\n${YELLOW}Press Ctrl+C to stop all services${NC}"
    
    # Trap to cleanup on exit
    cleanup_server() {
        echo -e "\n${YELLOW}Shutting down all services...${NC}"
        # Graceful SIGTERM first
        for pid in "${SERVICE_PIDS[@]}"; do
            kill $pid 2>/dev/null || true
        done
        pkill -f "kubectl port-forward.*wm-" 2>/dev/null || true
        # Give processes 3s to exit gracefully
        sleep 3
        # Force-kill anything still holding our ports
        EXECUTOR_PORT="${EXECUTOR_PORT:-9081}"
        for port in $ORCHESTRATOR_PORT $EXECUTOR_PORT $RESTATE_PORT $RESTATE_ADMIN_PORT $RESTATE_RPC_PORT $WEFT_API_PORT $NODE_RUNNER_PORT; do
            local pids=$(lsof -t -i:$port 2>/dev/null || true)
            if [ -n "$pids" ]; then
                echo -e "${YELLOW}Force-killing leftover process on port $port${NC}"
                echo "$pids" | xargs kill -9 2>/dev/null || true
            fi
        done
        # Force-kill any surviving SERVICE_PIDS
        for pid in "${SERVICE_PIDS[@]}"; do
            kill -9 $pid 2>/dev/null || true
        done
        echo -e "${GREEN}All services stopped.${NC}"
    }
    trap cleanup_server EXIT
    
    # Wait for orchestrator (main process)
    wait $ORCHESTRATOR_PID
}

# ============================================
# DASHBOARD (Frontend) Functions
# ============================================
start_dashboard() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}   Weft Dashboard${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    cd "$SCRIPT_DIR/dashboard"
    
    # Configuration
    DEV_PORT=5173
    MIN_NODE_VERSION=18
    
    # Step 1: Check dependencies
    echo -e "\n${BLUE}[1/4] Checking dependencies...${NC}"
    
    # Check Node.js
    if ! command_exists node; then
        echo -e "${RED}Node.js not found. Please install Node.js first.${NC}"
        echo -e "Recommended: https://nodejs.org/ or use nvm"
        exit 1
    fi
    
    NODE_VERSION=$(node --version | sed 's/v//')
    NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)
    if [ "$NODE_MAJOR" -lt "$MIN_NODE_VERSION" ]; then
        echo -e "${RED}Node.js version $NODE_VERSION is too old. Minimum required: v$MIN_NODE_VERSION${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ Node.js installed (v$NODE_VERSION)${NC}"
    
    # Check pnpm
    if ! command_exists pnpm; then
        echo -e "${YELLOW}pnpm not found. Installing...${NC}"
        curl -fsSL https://get.pnpm.io/install.sh | sh -
        export PNPM_HOME="$HOME/.local/share/pnpm"
        export PATH="$PNPM_HOME:$PATH"
    fi
    
    if ! command_exists pnpm; then
        echo -e "${RED}pnpm installation failed. Please install manually:${NC}"
        echo -e "  curl -fsSL https://get.pnpm.io/install.sh | sh -"
        exit 1
    fi
    
    PNPM_VERSION=$(pnpm --version)
    echo -e "${GREEN}✓ pnpm installed ($PNPM_VERSION)${NC}"
    
    # Step 2: Install dependencies
    echo -e "\n${BLUE}[2/4] Installing dependencies...${NC}"
    
    if [ ! -d "node_modules" ] || [ "package.json" -nt "node_modules" ]; then
        echo -e "${YELLOW}Installing packages...${NC}"
        pnpm install --frozen-lockfile 2>/dev/null || pnpm install
        touch node_modules
    else
        echo -e "${GREEN}✓ Dependencies up to date${NC}"
    fi
    
    # Step 3: Check environment
    echo -e "\n${BLUE}[3/4] Checking environment...${NC}"
    
    if [ ! -f ".env" ] && [ -f ".env.example" ]; then
        echo -e "${YELLOW}Creating .env from .env.example...${NC}"
        cp .env.example .env
    fi
    echo -e "${GREEN}✓ Environment ready${NC}"
    
    # Step 4: Start dev server
    echo -e "\n${BLUE}[4/4] Starting development server...${NC}"
    
    if port_in_use $DEV_PORT; then
        echo -e "${YELLOW}Port $DEV_PORT is in use. Stopping existing process...${NC}"
        kill $(lsof -t -i:$DEV_PORT) 2>/dev/null || true
        sleep 2
    fi
    
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}   Dashboard starting...${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "  Dev Server:  http://localhost:$DEV_PORT"
    echo -e "\n${YELLOW}Press Ctrl+C to stop${NC}\n"
    
    pnpm dev
}

# ============================================
# EXTENSION (Browser Extension)
# ============================================
start_extension() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}   Weft Extension${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    cd "$SCRIPT_DIR/extension"
    
    # Check pnpm
    if ! command_exists pnpm; then
        echo -e "${RED}pnpm not found. Please install pnpm first.${NC}"
        exit 1
    fi
    
    # Install dependencies if needed
    if [ ! -d "node_modules" ] || [ "package.json" -nt "node_modules" ]; then
        echo -e "${YELLOW}Installing extension dependencies...${NC}"
        pnpm install
    fi
    
    echo -e "\n${BLUE}[2/2] Building extension...${NC}"
    pnpm build:firefox
    
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}   Extension built successfully!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e ""
    echo -e "To load in Firefox:"
    echo -e "  1. Open Firefox and go to ${YELLOW}about:debugging${NC}"
    echo -e "  2. Click '${YELLOW}This Firefox${NC}' in the left sidebar"
    echo -e "  3. Click '${YELLOW}Load Temporary Add-on${NC}'"
    echo -e "  4. Navigate to: ${YELLOW}$SCRIPT_DIR/extension/.output/firefox-mv2${NC}"
    echo -e "  5. Select the ${YELLOW}manifest.json${NC} file"
    echo -e ""
    echo -e "The extension icon will appear in your toolbar."
    echo -e ""
    echo -e "${YELLOW}To rebuild after changes, run: ./dev.sh extension${NC}"
}

# ============================================
# ORCHESTRATOR (No node executors)
# ============================================
start_orchestrator() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}   Weft Orchestrator${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    cd "$SCRIPT_DIR"
    
    # Check if Restate is running
    if ! port_in_use 8080; then
        echo -e "${YELLOW}Restate not running. Starting Restate first...${NC}"
        start_restate_background
        wait_for_port 8080 "Restate"
    fi
    
    echo -e "\n${BLUE}Starting Orchestrator (port 9080)...${NC}"
    ORCHESTRATOR_PORT=9080 cargo run --bin orchestrator &
    ORCHESTRATOR_PID=$!
    
    wait_for_port 9080 "Orchestrator"
    
    # Register with Restate
    echo -e "\n${BLUE}Registering orchestrator with Restate...${NC}"
    sleep 2
    curl -X POST http://localhost:9070/deployments -H 'content-type: application/json' \
        -d '{"uri": "http://localhost:9080", "force": true}' 2>/dev/null || true
    
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}   Orchestrator running!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "  Orchestrator: http://localhost:9080"
    echo -e "  Restate Admin: http://localhost:9070"
    echo -e "\n${YELLOW}Press Ctrl+C to stop${NC}\n"
    
    wait $ORCHESTRATOR_PID
}

# ============================================
# NODE-RUNNER (Standalone node service)
# ============================================
start_node_compute() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}   Weft Compute Node Service${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    cd "$SCRIPT_DIR"
    
    NODE_ID="${NODE_ID:-compute-node-local}"
    NODE_PORT="${NODE_PORT:-9081}"
    NODE_TYPES="${NODE_TYPES:-Llm,Code}"
    ORCHESTRATOR_URL="${ORCHESTRATOR_URL:-http://localhost:8080}"
    
    echo -e "\n${BLUE}Starting Node Runner (port $NODE_PORT)...${NC}"
    echo -e "  Node ID: $NODE_ID"
    echo -e "  Node Types: $NODE_TYPES"
    echo -e "  Orchestrator: $ORCHESTRATOR_URL"
    
    NODE_ID=$NODE_ID NODE_PORT=$NODE_PORT NODE_TYPES=$NODE_TYPES ORCHESTRATOR_URL=$ORCHESTRATOR_URL \
        cargo run --bin node-runner
}

# ============================================
# ALL (Both server and dashboard)
# ============================================
start_all() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}   Weft Full Stack${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${YELLOW}Starting server and dashboard...${NC}\n"
    
    # Start server in background
    start_server &
    SERVER_PID=$!
    
    # Wait for server to be ready
    sleep 10
    
    # Start dashboard in foreground
    start_dashboard
}

# ============================================
# Main entry point
# ============================================
case "${1:-server}" in
    server|"")
        start_server
        ;;
    orchestrator)
        start_orchestrator
        ;;
    node-runner)
        start_node_compute
        ;;
    dashboard)
        start_dashboard
        ;;
    extension)
        start_extension
        ;;
    all)
        start_all
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        show_usage
        exit 1
        ;;
esac

#!/bin/bash

# ===========================================
# Weft Cleanup Script
# ===========================================
# Cleans up local development services and data.
# Does NOT touch weavemind services.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env for port overrides
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# Ports (match dev.sh defaults)
RESTATE_PORT="${RESTATE_PORT:-8080}"
RESTATE_ADMIN_PORT="${RESTATE_ADMIN_PORT:-9070}"
RESTATE_RPC_PORT="${RESTATE_RPC_PORT:-5122}"
ORCHESTRATOR_PORT="${ORCHESTRATOR_PORT:-9080}"
NODE_RUNNER_PORT="${NODE_RUNNER_PORT:-9081}"
WEFT_API_PORT="${WEFT_API_PORT:-3000}"
DASHBOARD_PORT=5173

# Database (match init-db.sh)
PG_CONTAINER="weft-local-postgres"
PG_DB="weft_local"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

show_help() {
    echo "Usage: ./cleanup.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --services       Stop all services (Restate, API, orchestrator, node-runner)"
    echo "  --dashboard      Stop the dashboard dev server"
    echo "  --restate        Delete Restate data (execution history)"
    echo "  --db             Reset PostgreSQL database (drop and recreate)"
    echo "  --db-destroy     Remove PostgreSQL container entirely"
    echo "  --no-db          Stop everything + clean Restate, but keep database"
    echo "  --all            Stop everything + clean everything including database (default)"
    echo "  --help, -h       Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./cleanup.sh                  # Full cleanup"
    echo "  ./cleanup.sh --no-db          # Cleanup but keep database data"
    echo "  ./cleanup.sh --services       # Just stop services"
    echo "  ./cleanup.sh --db-destroy     # Remove PostgreSQL container and volume"
    exit 0
}

kill_port() {
    local port=$1
    local name=$2
    local pids=$(lsof -t -i:$port 2>/dev/null || true)
    if [ -n "$pids" ]; then
        echo "$pids" | xargs kill -9 2>/dev/null || true
        echo -e "${GREEN}✓${NC} Killed $name (port $port)"
        return 0
    fi
    return 1
}

# Parse arguments
STOP_SERVICES=false
STOP_DASHBOARD=false
CLEAN_RESTATE=false
CLEAN_DB=false
DESTROY_DB=false
NO_DB=false

if [ $# -eq 0 ]; then
    STOP_SERVICES=true
    STOP_DASHBOARD=true
    CLEAN_RESTATE=true
    CLEAN_DB=true
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --services)    STOP_SERVICES=true; shift ;;
        --dashboard)   STOP_DASHBOARD=true; shift ;;
        --restate)     CLEAN_RESTATE=true; shift ;;
        --db)          CLEAN_DB=true; shift ;;
        --db-destroy)  DESTROY_DB=true; shift ;;
        --no-db)       STOP_SERVICES=true; STOP_DASHBOARD=true; CLEAN_RESTATE=true; NO_DB=true; shift ;;
        --all)         STOP_SERVICES=true; STOP_DASHBOARD=true; CLEAN_RESTATE=true; CLEAN_DB=true; shift ;;
        --help|-h)     show_help ;;
        *)             echo -e "${RED}Unknown option: $1${NC}"; echo "Use --help for usage"; exit 1 ;;
    esac
done

if [ "$NO_DB" = true ]; then CLEAN_DB=false; fi

echo "========================================="
echo "   Weft Cleanup"
echo "========================================="
echo ""

# Stop services
if [ "$STOP_SERVICES" = true ]; then
    echo "Stopping services..."
    kill_port $RESTATE_PORT "Restate server" || true
    kill_port $RESTATE_ADMIN_PORT "Restate admin" || true
    kill_port $RESTATE_RPC_PORT "Restate RPC" || true
    kill_port $ORCHESTRATOR_PORT "Orchestrator" || true
    kill_port $NODE_RUNNER_PORT "Node Runner" || true
    kill_port $WEFT_API_PORT "Weft API" || true
    pkill -f "kubectl port-forward.*wm-" 2>/dev/null || true
    sleep 1
    echo -e "${GREEN}✓${NC} Services stopped"
fi

# Stop dashboard
if [ "$STOP_DASHBOARD" = true ]; then
    echo ""
    echo "Stopping dashboard..."
    kill_port $DASHBOARD_PORT "Dashboard" || true
    echo -e "${GREEN}✓${NC} Dashboard stopped"
fi

# Clean Restate data
if [ "$CLEAN_RESTATE" = true ]; then
    echo ""
    echo "Cleaning Restate data..."
    rm -rf "$SCRIPT_DIR/restate-data" "$SCRIPT_DIR/restate-data.toml"
    echo -e "${GREEN}✓${NC} Restate data removed"
fi

# Reset database (drop and recreate, keep container)
if [ "$CLEAN_DB" = true ]; then
    echo ""
    echo "Resetting database..."
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${PG_CONTAINER}$"; then
        docker exec "$PG_CONTAINER" psql -U postgres -c "DROP DATABASE IF EXISTS ${PG_DB};" 2>/dev/null || true
        docker exec "$PG_CONTAINER" psql -U postgres -c "CREATE DATABASE ${PG_DB};" 2>/dev/null || true
        echo -e "${GREEN}✓${NC} Database reset (tables will be recreated on next startup)"
    else
        echo -e "${YELLOW}⚠${NC} PostgreSQL container not running"
    fi
fi

# Destroy database (remove container and volume entirely)
if [ "$DESTROY_DB" = true ]; then
    echo ""
    echo "Destroying PostgreSQL container..."
    docker stop "$PG_CONTAINER" 2>/dev/null || true
    docker rm "$PG_CONTAINER" 2>/dev/null || true
    docker volume rm weft-local-pgdata 2>/dev/null || true
    echo -e "${GREEN}✓${NC} PostgreSQL container and volume removed"
fi

echo ""
echo "========================================="
echo "   Cleanup Complete"
echo "========================================="
echo ""
echo "To start fresh: ./dev.sh server"
echo ""

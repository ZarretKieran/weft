#!/bin/bash

# ===========================================
# Weft Local Database Initialization
# ===========================================
# This script sets up a local PostgreSQL database for development.
# It starts a Docker container and initializes the schema.
#
# Usage:
#   ./init-db.sh              # Start postgres and init schema
#   ./init-db.sh --reset      # Drop and recreate database
#
# Prerequisites:
#   - Docker installed and running

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
CONTAINER_NAME="weft-local-postgres"
DB_NAME="weft_local"
DB_USER="postgres"
DB_PASSWORD="postgres"
DB_PORT="5433"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }

echo "========================================="
echo "   Weft Local Database Init"
echo "========================================="
echo ""

# Check for Docker
if ! command -v docker &> /dev/null; then
    print_error "Docker not found. Please install Docker first."
    exit 1
fi

# Handle --reset flag
if [ "$1" == "--reset" ]; then
    print_warning "Resetting database..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
    docker volume rm weft-local-pgdata 2>/dev/null || true
    print_status "Database reset complete"
fi

# ===========================================
# Step 1: Start PostgreSQL container
# ===========================================
echo "Step 1: Starting PostgreSQL container..."

if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_status "PostgreSQL container already running"
    else
        docker start "$CONTAINER_NAME"
        print_status "Started existing PostgreSQL container"
    fi
else
    docker run -d \
        --name "$CONTAINER_NAME" \
        -e POSTGRES_USER="$DB_USER" \
        -e POSTGRES_PASSWORD="$DB_PASSWORD" \
        -e POSTGRES_DB="$DB_NAME" \
        -p "$DB_PORT:5432" \
        -v weft-local-pgdata:/var/lib/postgresql/data \
        postgres:16
    print_status "Created new PostgreSQL container"
fi

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be ready..."
for i in {1..30}; do
    if docker exec "$CONTAINER_NAME" pg_isready -U "$DB_USER" &>/dev/null; then
        print_status "PostgreSQL is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        print_error "PostgreSQL failed to start within 30 seconds"
        exit 1
    fi
    sleep 1
done

# ===========================================
# Step 2: Initialize schema
# ===========================================
echo ""
echo "Step 2: Initializing database schema..."

# Always run init SQL: all statements are idempotent
# (CREATE TABLE IF NOT EXISTS, ALTER TABLE ADD COLUMN IF NOT EXISTS, ON CONFLICT DO NOTHING)
echo "Applying schema (idempotent)..."
docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" < "$SCRIPT_DIR/init-db.sql"
print_status "Database schema up to date"

# List the tables
echo ""
echo "Tables in database:"
docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME" -c "\dt" 2>/dev/null | grep -E "^\s+public" | awk '{print "  - " $3}'

# ===========================================
# Done
# ===========================================
echo ""
echo "========================================="
echo "   Local Database Ready!"
echo "========================================="
echo ""
echo "Connection string:"
echo "  DATABASE_URL=postgres://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}"
echo ""
echo "To run weft-api locally:"
echo "  export DATABASE_URL=postgres://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}"
echo "  cargo run --bin weft-api"
echo ""

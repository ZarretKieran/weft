#!/bin/bash
# ===========================================
# WeaveMind Extension Builder
# ===========================================
# Builds, signs, and deploys the browser extension to the dashboard.
# Run this whenever you update the extension code.
#
# Supported browsers: Chrome, Firefox, Safari, Opera, Edge
# (Brave, Vivaldi, Arc use the Chrome build directly)
#
# Requirements:
#   - pnpm installed
#   - web-ext installed globally (pnpm install -g web-ext) - for Firefox signing
#   - Mozilla API keys in environment or .env.extension file - for Firefox signing
#   - macOS + Xcode CLI tools - for Safari (optional, skipped on Linux)
#
# Usage:
#   ./build-extension.sh              # Build all, sign Firefox (bumps version if needed)
#   ./build-extension.sh --skip-sign  # Build all, skip Firefox signing (use cached .xpi)
#   ./build-extension.sh --bump       # Force bump version before building

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTENSION_DIR="$SCRIPT_DIR/extension"
DASHBOARD_STATIC="$SCRIPT_DIR/dashboard/static/extensions"

SKIP_SIGN=false
FORCE_BUMP=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --skip-sign)
            SKIP_SIGN=true
            ;;
        --bump)
            FORCE_BUMP=true
            ;;
    esac
done

echo "========================================="
echo "  WeaveMind Extension Builder"
echo "========================================="

# Load environment (for Mozilla API keys)
if [ -f "$SCRIPT_DIR/.env.extension" ]; then
    echo "Loading environment from .env.extension..."
    set -a
    source "$SCRIPT_DIR/.env.extension"
    set +a
fi

# Check for required API keys (only if signing)
if [ "$SKIP_SIGN" = false ]; then
    if [ -z "$WEB_EXT_API_KEY" ] || [ -z "$WEB_EXT_API_SECRET" ]; then
        echo ""
        echo "ERROR: Mozilla API keys not found!"
        echo ""
        echo "Create $SCRIPT_DIR/.env.extension with:"
        echo "  WEB_EXT_API_KEY=user:XXXXX:XXX"
        echo "  WEB_EXT_API_SECRET=your-secret-here"
        echo ""
        echo "Get your keys from: https://addons.mozilla.org/en-US/developers/addon/api/key/"
        echo ""
        echo "Or run with --skip-sign to skip Firefox signing"
        exit 1
    fi
fi

cd "$EXTENSION_DIR"

# Get current version
CURRENT_VERSION=$(node -p "require('./package.json').version")
echo ""
echo "Current version: $CURRENT_VERSION"

# Check if we need to bump for signing
if [ "$FORCE_BUMP" = true ]; then
    echo "Bumping patch version (--bump flag)..."
    npm version patch --no-git-tag-version
elif [ "$SKIP_SIGN" = false ]; then
    # Check if this version was already signed
    EXISTING_XPI="$DASHBOARD_STATIC/weavemind-firefox.xpi"
    if [ -f "$EXISTING_XPI" ]; then
        echo "Note: Firefox .xpi already exists. Will auto-bump to avoid signing conflict."
        npm version patch --no-git-tag-version
    fi
fi

VERSION=$(node -p "require('./package.json').version")
if [ "$VERSION" != "$CURRENT_VERSION" ]; then
    echo "New version: $VERSION"
fi

echo ""
echo "Building extensions for version $VERSION..."
echo ""

# Install dependencies if needed
if [ ! -d "node_modules" ] || [ "package.json" -nt "node_modules" ]; then
    echo "Installing dependencies..."
    pnpm install
fi

# Build all browser targets
echo "Building Chrome extension (MV3)..."
pnpm build

echo "Building Firefox extension (MV2)..."
pnpm build:firefox

echo "Building Safari extension (MV2)..."
pnpm build:safari

echo "Building Opera extension (MV3)..."
pnpm build:opera

echo "Building Edge extension (MV3)..."
pnpm build:edge

# Create zip packages
echo ""
echo "Creating zip packages..."
pnpm zip
pnpm zip:firefox  # unsigned zip (for reference, signing produces .xpi)
pnpm zip:safari
pnpm zip:opera
pnpm zip:edge

# Sign Firefox extension (or skip)
if [ "$SKIP_SIGN" = true ]; then
    echo ""
    echo "Skipping Firefox signing (--skip-sign flag)"
    SIGNED_XPI=$(ls -t web-ext-artifacts/*.xpi 2>/dev/null | head -1)
    if [ -z "$SIGNED_XPI" ]; then
        # Check if there's already one in dashboard
        if [ -f "$DASHBOARD_STATIC/weavemind-firefox.xpi" ]; then
            echo "Using existing .xpi from dashboard"
            SIGNED_XPI="$DASHBOARD_STATIC/weavemind-firefox.xpi"
            SKIP_FIREFOX_COPY=true
        else
            echo "WARNING: No signed .xpi found. Firefox users won't be able to install permanently."
            SIGNED_XPI=""
        fi
    fi
else
    echo ""
    echo "Signing Firefox extension (this may take 1-2 minutes)..."
    web-ext sign \
        --source-dir .output/firefox-mv2 \
        --api-key="$WEB_EXT_API_KEY" \
        --api-secret="$WEB_EXT_API_SECRET" \
        --channel unlisted

    # Find the signed xpi
    SIGNED_XPI=$(ls -t web-ext-artifacts/*.xpi 2>/dev/null | head -1)
    if [ -z "$SIGNED_XPI" ]; then
        echo "ERROR: Signed .xpi not found in web-ext-artifacts/"
        exit 1
    fi
fi

echo ""
echo "Copying to dashboard static folder..."

# Ensure dashboard extensions folder exists
mkdir -p "$DASHBOARD_STATIC"

# Source zip names come from wxt, which derives them from
# extension/package.json's `name` field (currently `weft-extension`).
# The destination names must stay `weavemind-*` because the dashboard's
# download buttons (see dashboard/src/routes/(app)/extension/+page.svelte)
# link to those paths hardcoded.
SRC_PREFIX="weft-extension-$VERSION"

# Copy Chrome (also used by Brave, Vivaldi, Arc)
cp ".output/${SRC_PREFIX}-chrome.zip" "$DASHBOARD_STATIC/weavemind-chrome.zip"
echo "  ✓ weavemind-chrome.zip (Chrome, Brave, Vivaldi, Arc)"

# Copy signed Firefox (if available and not already there)
if [ -n "$SIGNED_XPI" ] && [ "$SKIP_FIREFOX_COPY" != "true" ]; then
    cp "$SIGNED_XPI" "$DASHBOARD_STATIC/weavemind-firefox.xpi"
    echo "  ✓ weavemind-firefox.xpi (signed)"
elif [ -f "$DASHBOARD_STATIC/weavemind-firefox.xpi" ]; then
    echo "  ✓ weavemind-firefox.xpi (existing)"
else
    echo "  ⚠ weavemind-firefox.xpi (missing - run without --skip-sign)"
fi

# Copy Safari
cp ".output/${SRC_PREFIX}-safari.zip" "$DASHBOARD_STATIC/weavemind-safari.zip"
echo "  ✓ weavemind-safari.zip"

# Copy Opera
cp ".output/${SRC_PREFIX}-opera.zip" "$DASHBOARD_STATIC/weavemind-opera.zip"
echo "  ✓ weavemind-opera.zip"

# Copy Edge
cp ".output/${SRC_PREFIX}-edge.zip" "$DASHBOARD_STATIC/weavemind-edge.zip"
echo "  ✓ weavemind-edge.zip"

echo ""
echo "========================================="
echo "  Build Complete!"
echo "========================================="
echo ""
echo "Extension v$VERSION deployed to dashboard."
echo "Files in: $DASHBOARD_STATIC"
echo ""
echo "Browser targets:"
echo "  Chrome/Brave/Vivaldi/Arc  → weavemind-chrome.zip (MV3, load unpacked)"
echo "  Firefox                   → weavemind-firefox.xpi (MV2, signed)"
echo "  Safari                    → weavemind-safari.zip (MV2, requires Xcode conversion)"
echo "  Opera                     → weavemind-opera.zip (MV3, load unpacked)"
echo "  Edge                      → weavemind-edge.zip (MV3, load unpacked)"
echo ""
echo "Safari note: On macOS, run to create Xcode project:"
echo "  xcrun safari-web-extension-converter extension/.output/safari-mv2"
echo ""
ls -lh "$DASHBOARD_STATIC"
echo ""

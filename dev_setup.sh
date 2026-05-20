#!/usr/bin/env bash
# dev_setup.sh — one-time local development environment setup.
# Run from the project root: bash dev_setup.sh
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}── $* ──${NC}"; }

# ── 1. System dependencies (macOS / Homebrew) ─────────────────────────────────
step "1/3  System dependencies"
if command -v brew >/dev/null 2>&1; then
  for pkg in libxml2 libxmlsec1 pkg-config; do
    brew list "$pkg" &>/dev/null && info "$pkg already installed." || \
      { info "Installing $pkg..."; brew install "$pkg"; }
  done
else
  warn "Homebrew not found. Install libxml2, libxmlsec1, pkg-config manually."
fi

# Ensure pkg-config can find Homebrew-installed libs (Apple Silicon + Intel)
export PKG_CONFIG_PATH
PKG_CONFIG_PATH="$(brew --prefix libxml2 2>/dev/null)/lib/pkgconfig:$(brew --prefix libxmlsec1 2>/dev/null)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# ── 2. Python virtual environment ─────────────────────────────────────────────
step "2/3  Python virtual environment"
if [ ! -d ".venv" ]; then
  python3 -m venv .venv
  info ".venv created."
else
  info ".venv already exists."
fi

info "Installing Python dependencies..."
PKG_CONFIG_PATH="$PKG_CONFIG_PATH" .venv/bin/pip install --quiet ".[dev]"
info "Dependencies installed."

# ── 3. IDP metadata ───────────────────────────────────────────────────────────
step "3/3  IDP metadata"
IDP_URL="http://localhost:8080/realms/saml-demo/protocol/saml/descriptor"
if curl -sf "$IDP_URL" > /tmp/idp_meta_check.xml 2>/dev/null && \
   grep -q "EntityDescriptor" /tmp/idp_meta_check.xml; then
  cp /tmp/idp_meta_check.xml app/saml/idp_metadata.xml
  info "IDP metadata downloaded from Keycloak → app/saml/idp_metadata.xml"
else
  warn "Keycloak not reachable at $IDP_URL"
  warn "Start the Keycloak port-forward first:"
  warn "  kubectl port-forward -n keycloak svc/keycloak 8080:8080"
  warn "Then re-run: bash dev_setup.sh"
  if [ -f app/saml/idp_metadata.xml ] && grep -q "EntityDescriptor" app/saml/idp_metadata.xml 2>/dev/null; then
    warn "Using existing app/saml/idp_metadata.xml — may be stale."
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
step "Done"
echo ""
echo -e "${GREEN}${BOLD}Setup complete. To start the app:${NC}"
echo ""
echo "  make run          # uses uvicorn with --reload"
echo ""
echo "  — or manually —"
echo "  source .venv/bin/activate"
echo "  uvicorn main:app --app-dir app --reload --port 8000"
echo ""
echo "Keep Keycloak port-forward running for SAML login to work:"
echo "  kubectl port-forward -n keycloak svc/keycloak 8080:8080"

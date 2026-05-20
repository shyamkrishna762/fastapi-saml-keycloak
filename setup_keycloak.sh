#!/usr/bin/env bash
# setup_keycloak.sh
# Configures Keycloak realm + SAML client, syncs IDP metadata to FastAPI.
# Prerequisites: both port-forwards must be active before running.
#   kubectl port-forward -n keycloak svc/keycloak 8080:8080
#   kubectl port-forward -n fastapi-saml svc/fastapi-saml 8000:8000

set -euo pipefail

KEYCLOAK_URL="http://localhost:8080"
FASTAPI_URL="http://localhost:8000"
REALM="saml-demo"
ADMIN_USER="admin"
ADMIN_PASS="admin"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}── $* ──${NC}"; }

# ── 1. Wait for Keycloak ──────────────────────────────────────────────────────
step "1/8  Waiting for Keycloak"
for i in $(seq 1 36); do
  curl -sf "$KEYCLOAK_URL/realms/master" >/dev/null 2>&1 && { info "Keycloak ready."; break; }
  [ "$i" -eq 36 ] && die "Keycloak not ready after 3 minutes."
  echo -n "." ; sleep 5
done

# ── 2. Admin token ────────────────────────────────────────────────────────────
step "2/8  Obtaining admin token"
TOKEN=$(curl -sf -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&username=$ADMIN_USER&password=$ADMIN_PASS&grant_type=password" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
[ -z "$TOKEN" ] && die "Could not get admin token."
info "Token obtained."

# ── 3. Create realm ───────────────────────────────────────────────────────────
step "3/8  Creating realm '$REALM'"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"realm\":\"$REALM\",\"enabled\":true,\"displayName\":\"SAML Demo\"}")
[ "$CODE" = "201" ] && info "Realm created." || \
[ "$CODE" = "409" ] && warn "Realm already exists — continuing." || \
  die "Create realm failed (HTTP $CODE)."

# ── 4. Fetch SP metadata from FastAPI ─────────────────────────────────────────
step "4/8  Fetching SP metadata from FastAPI"
for i in $(seq 1 20); do
  SP_META=$(curl -sf "$FASTAPI_URL/metadata" 2>/dev/null) && break
  [ "$i" -eq 20 ] && die "FastAPI /metadata not available."
  echo -n "." ; sleep 3
done
echo "$SP_META" > /tmp/sp_metadata.xml
info "SP metadata fetched ($(echo "$SP_META" | wc -c) bytes)."

# ── 5. Convert SP metadata → Keycloak client JSON ────────────────────────────
step "5/8  Converting SP metadata to Keycloak client representation"
CLIENT_JSON=$(curl -sf -X POST \
  "$KEYCLOAK_URL/admin/realms/$REALM/client-description-converter" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/xml" \
  --data-raw "$SP_META")
[ -z "$CLIENT_JSON" ] && die "client-description-converter returned empty response."
info "Conversion successful."

# ── 6. Register SAML client ───────────────────────────────────────────────────
step "6/8  Registering FastAPI as SAML client"
CODE=$(curl -s -o /tmp/kc_create_client.json -w "%{http_code}" \
  -X POST "$KEYCLOAK_URL/admin/realms/$REALM/clients" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "$CLIENT_JSON")

if [ "$CODE" = "201" ]; then
  info "SAML client created."
elif [ "$CODE" = "409" ]; then
  warn "Client already exists — continuing."
else
  warn "HTTP $CODE when creating client:"
  cat /tmp/kc_create_client.json
fi

# ── 7. Create test user ───────────────────────────────────────────────────────
step "7/8  Creating test user"
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$KEYCLOAK_URL/admin/realms/$REALM/users" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{
    "username":"testuser","email":"testuser@example.com",
    "firstName":"Test","lastName":"User",
    "enabled":true,"emailVerified":true,
    "credentials":[{"type":"password","value":"Test@1234","temporary":false}]
  }')
[ "$CODE" = "201" ] && info "Test user created  →  testuser / Test@1234" || \
[ "$CODE" = "409" ] && warn "Test user already exists." || \
  warn "Create user returned HTTP $CODE."

# ── 7b. Configure client security attributes for no-signing mode ─────────────
# - saml.client.signature=false : SP sends unsigned AuthnRequests
# - saml.assertion.signature=true: Keycloak signs assertions (verified by SP
#   using the IdP cert from idp_metadata.xml — no SP cert involved)
# - saml.server.signature=true  : Keycloak signs the Response envelope too
# - saml.encrypt=false          : no NameID / assertion encryption (no SP cert needed)
# Clear any SP signing/encryption certificates left from other configurations.
CLIENT_UUID=$(curl -sf \
  "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=http://localhost:8000/metadata" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null || echo "")

if [ -n "$CLIENT_UUID" ]; then
  curl -sf -X PUT "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_UUID" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{
      "attributes": {
        "saml.client.signature":     "false",
        "saml.assertion.signature":  "true",
        "saml.server.signature":     "true",
        "saml.encrypt":              "false",
        "saml.signing.certificate":  "",
        "saml.encryption.certificate": ""
      }
    }' >/dev/null
  info "Client security configured: no client signature, assertion signing enabled, no encryption."
else
  warn "Could not find client UUID to patch — skipping security patch."
fi

# Fix role_list mapper to emit a single <Attribute> with multiple values instead
# of one <Attribute> per role — python3-saml rejects duplicate attribute names.
ROLE_SCOPE_ID=$(curl -sf "$KEYCLOAK_URL/admin/realms/$REALM/client-scopes" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json; ids=[s['id'] for s in json.load(sys.stdin) if s['name']=='role_list']; print(ids[0] if ids else '')")
ROLE_MAPPER_ID=$(curl -sf "$KEYCLOAK_URL/admin/realms/$REALM/client-scopes/$ROLE_SCOPE_ID/protocol-mappers/models" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json; ms=json.load(sys.stdin); ids=[m['id'] for m in ms if m['name']=='role list']; print(ids[0] if ids else '')")
if [ -n "$ROLE_MAPPER_ID" ]; then
  curl -sf -X PUT \
    "$KEYCLOAK_URL/admin/realms/$REALM/client-scopes/$ROLE_SCOPE_ID/protocol-mappers/models/$ROLE_MAPPER_ID" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"id\":\"$ROLE_MAPPER_ID\",\"name\":\"role list\",\"protocol\":\"saml\",\"protocolMapper\":\"saml-role-list-mapper\",\"consentRequired\":false,\"config\":{\"single\":\"true\",\"attribute.nameformat\":\"Basic\",\"attribute.name\":\"Role\"}}" \
    >/dev/null
  info "role_list mapper: single=true (all roles in one Attribute element)."
fi

# ── 8. Download IDP metadata and push to k8s ─────────────────────────────────
step "8/8  Syncing IDP metadata → k8s ConfigMap"
IDP_META_URL="$KEYCLOAK_URL/realms/$REALM/protocol/saml/descriptor"
curl -sf "$IDP_META_URL" > /tmp/idp_metadata.xml
[ ! -s /tmp/idp_metadata.xml ] && die "IDP metadata download failed."
info "Downloaded IDP metadata from $IDP_META_URL"

kubectl create configmap keycloak-idp-metadata \
  --from-file=idp_metadata.xml=/tmp/idp_metadata.xml \
  -n fastapi-saml \
  --dry-run=client -o yaml | kubectl --context kind-agentregistry apply -f -

info "ConfigMap updated. Restarting FastAPI..."
kubectl --context kind-agentregistry rollout restart deployment/fastapi-saml -n fastapi-saml
kubectl --context kind-agentregistry rollout status deployment/fastapi-saml -n fastapi-saml --timeout=90s

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  Setup complete!                                         ║${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}${BOLD}║${NC}  Keycloak admin : http://localhost:8080/admin            ${GREEN}${BOLD}║${NC}"
echo -e "${GREEN}${BOLD}║${NC}  Realm          : $REALM                              ${GREEN}${BOLD}║${NC}"
echo -e "${GREEN}${BOLD}║${NC}  FastAPI app    : http://localhost:8000                  ${GREEN}${BOLD}║${NC}"
echo -e "${GREEN}${BOLD}║${NC}  Test login     : testuser / Test@1234                   ${GREEN}${BOLD}║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "NOTE: Re-run the FastAPI port-forward after pod restart:"
echo "  kubectl port-forward -n fastapi-saml svc/fastapi-saml 8000:8000"

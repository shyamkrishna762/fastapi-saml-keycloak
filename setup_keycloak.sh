#!/usr/bin/env bash
# setup_keycloak.sh
# Full end-to-end Keycloak + FastAPI SAML configuration.
# Run AFTER both port-forwards are active:
#   kubectl port-forward -n keycloak svc/keycloak 8080:8080
#   kubectl port-forward -n fastapi-saml svc/fastapi-saml 8000:8000

set -e

KEYCLOAK_URL="http://localhost:8080"
FASTAPI_URL="http://localhost:8000"
REALM="saml-demo"
ADMIN_USER="admin"
ADMIN_PASS="admin"

# ── colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── 1. wait for Keycloak ──────────────────────────────────────────────────────
info "Waiting for Keycloak to be ready..."
for i in $(seq 1 30); do
  if curl -sf "$KEYCLOAK_URL/realms/master" >/dev/null 2>&1; then
    info "Keycloak is ready."
    break
  fi
  [ "$i" -eq 30 ] && die "Keycloak did not become ready in time."
  sleep 5
done

# ── 2. get admin token ────────────────────────────────────────────────────────
info "Obtaining Keycloak admin token..."
TOKEN=$(curl -sf -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "username=$ADMIN_USER" \
  -d "password=$ADMIN_PASS" \
  -d "grant_type=password" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
[ -z "$TOKEN" ] && die "Failed to get admin token."
info "Token obtained."

# ── 3. create realm ───────────────────────────────────────────────────────────
info "Creating realm '$REALM'..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"realm\":\"$REALM\",\"enabled\":true,\"displayName\":\"SAML Demo\"}")

if [ "$HTTP_CODE" = "201" ]; then
  info "Realm '$REALM' created."
elif [ "$HTTP_CODE" = "409" ]; then
  warn "Realm '$REALM' already exists — continuing."
else
  die "Failed to create realm (HTTP $HTTP_CODE)."
fi

# ── 4. fetch SP metadata from FastAPI ─────────────────────────────────────────
info "Waiting for FastAPI /metadata endpoint..."
for i in $(seq 1 20); do
  if curl -sf "$FASTAPI_URL/metadata" >/dev/null 2>&1; then
    info "FastAPI is ready."
    break
  fi
  [ "$i" -eq 20 ] && die "FastAPI did not become ready."
  sleep 3
done

info "Downloading SP metadata from FastAPI..."
SP_METADATA=$(curl -sf "$FASTAPI_URL/metadata")
[ -z "$SP_METADATA" ] && die "Failed to fetch SP metadata."

# ── 5. register FastAPI as a SAML client from SP metadata ────────────────────
info "Registering FastAPI as SAML client in Keycloak (via SP metadata)..."

# Get initial access token for client registration
REG_TOKEN=$(curl -sf -X POST "$KEYCLOAK_URL/admin/realms/$REALM/clients-registrations/initial-access" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"count":1,"expiration":3600}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null || echo "")

# Use SAML entity-descriptor import (most direct path — mirrors "Import from file" in Keycloak UI)
HTTP_CODE=$(curl -s -o /tmp/kc_client_resp.json -w "%{http_code}" \
  -X POST "$KEYCLOAK_URL/admin/realms/$REALM/clients-registrations/saml2-entity-descriptor" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/xml" \
  --data-raw "$SP_METADATA")

if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
  CLIENT_ID=$(python3 -c "import sys,json; d=json.load(open('/tmp/kc_client_resp.json')); print(d.get('clientId',''))" 2>/dev/null || echo "")
  info "SAML client registered. Client ID: $CLIENT_ID"
elif [ "$HTTP_CODE" = "409" ]; then
  warn "Client already exists — continuing."
else
  warn "Client registration returned HTTP $HTTP_CODE — check /tmp/kc_client_resp.json"
  cat /tmp/kc_client_resp.json
fi

# ── 6. create a test user ─────────────────────────────────────────────────────
info "Creating test user 'testuser@example.com'..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms/$REALM/users" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "testuser",
    "email": "testuser@example.com",
    "firstName": "Test",
    "lastName": "User",
    "enabled": true,
    "emailVerified": true,
    "credentials": [{"type":"password","value":"Test@1234","temporary":false}]
  }')

if [ "$HTTP_CODE" = "201" ]; then
  info "Test user created — username: testuser / password: Test@1234"
elif [ "$HTTP_CODE" = "409" ]; then
  warn "Test user already exists."
fi

# ── 7. download IDP metadata from Keycloak ────────────────────────────────────
info "Downloading IDP metadata from Keycloak..."
curl -sf "$KEYCLOAK_URL/realms/$REALM/protocol/saml/descriptor" > /tmp/idp_metadata.xml
[ ! -s /tmp/idp_metadata.xml ] && die "IDP metadata download failed."
info "IDP metadata saved to /tmp/idp_metadata.xml"

# ── 8. update k8s ConfigMap with IDP metadata ────────────────────────────────
info "Updating Kubernetes ConfigMap 'keycloak-idp-metadata'..."
kubectl create configmap keycloak-idp-metadata \
  --from-file=idp_metadata.xml=/tmp/idp_metadata.xml \
  -n fastapi-saml \
  --dry-run=client -o yaml | kubectl apply -f -

# ── 9. restart FastAPI to pick up new IDP metadata ───────────────────────────
info "Restarting FastAPI deployment..."
kubectl rollout restart deployment/fastapi-saml -n fastapi-saml
kubectl rollout status deployment/fastapi-saml -n fastapi-saml --timeout=90s

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} Setup complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "  Keycloak Admin:  $KEYCLOAK_URL/admin  (admin / admin)"
echo "  Realm:           $REALM"
echo "  FastAPI App:     $FASTAPI_URL"
echo "  Test login:      testuser / Test@1234"
echo ""
echo "Keep both port-forwards running, then open: $FASTAPI_URL"

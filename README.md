# FastAPI SAML SSO with Keycloak

SAML 2.0 single sign-on using **Keycloak** as the Identity Provider (IdP) and **FastAPI** as the Service Provider (SP). Deployed on a local [kind](https://kind.sigs.k8s.io/) Kubernetes cluster.

---

## How it works

```
Browser ──GET /login──► FastAPI ──AuthnRequest──► Keycloak login page
                                                        │
                                               user enters credentials
                                                        │
Browser ◄──SAMLResponse POST /acs──────────── Keycloak (HTTP-POST binding)
                │
        FastAPI validates assertion
        (signature checked against idp_metadata.xml)
                │
        session cookie set ──► redirect to /profile
```

The only IdP configuration the app reads is **`app/saml/idp_metadata.xml`** — the XML descriptor downloaded from Keycloak. No manual IdP URL or certificate configuration is needed.

---

## Project structure

```
fastapi-saml/
├── app/
│   ├── main.py              # FastAPI routes: /, /login, /acs, /profile, /logout, /sls, /metadata
│   ├── saml_config.py       # Loads .env, parses idp_metadata.xml, maps roles
│   ├── templates/           # Jinja2 HTML templates
│   └── saml/
│       ├── idp_metadata.xml # Downloaded from Keycloak (replaced by setup scripts)
│       └── certs/           # SP certificate + private key (generated locally, git-ignored)
├── k8s/
│   ├── keycloak.yaml        # Keycloak namespace, Deployment, Service
│   └── fastapi.yaml         # FastAPI namespace, Deployment, Service, ConfigMaps
├── pyproject.toml           # Python dependencies
├── Dockerfile               # Multi-layer build; deps cached separately from app code
├── dev_setup.sh             # One-time local environment setup
├── Makefile                 # make setup / run / test
├── setup_keycloak.sh        # Automates Keycloak realm + client configuration
├── test_e2e.py              # End-to-end SAML flow test (10 checks)
├── .env                     # Local environment variables (git-ignored)
└── .env.example             # Template for .env
```

---

## Local setup

### Prerequisites

| Tool | Version |
|------|---------|
| Python | 3.11+ |
| Homebrew | any |
| kind | any |
| kubectl | any |
| podman or docker | any |

---

### Step 1 — Clone and configure environment

```bash
git clone https://github.com/shyamkrishna762/fastapi-saml-keycloak.git
cd fastapi-saml-keycloak

cp .env.example .env
```

Default `.env` works for local development as-is:

```dotenv
SP_ENTITY_ID=http://localhost:8000/metadata
SP_ACS_URL=http://localhost:8000/acs
SP_SLS_URL=http://localhost:8000/sls

# Attribute name in the SAML assertion that contains roles
SAML_ROLE_ATTRIBUTE=Role

# Map IdP role values to app roles  (pipe-separated  idp_role:app_role  pairs)
# Leave empty to pass all roles through unchanged
SAML_ROLE_MAP=default-roles-saml-demo:user|uma_authorization:admin
```

> **Role attribute names by IdP**
> | IdP | `SAML_ROLE_ATTRIBUTE` value |
> |-----|----------------------------|
> | Keycloak | `Role` |
> | Azure AD / Entra | `http://schemas.microsoft.com/ws/2008/06/identity/claims/role` |
> | Okta / Auth0 | `roles` |
> | AD FS | `http://schemas.xmlsoap.org/claims/Group` |

---

### Step 2 — Start the kind cluster

```bash
# Check existing clusters
kind get clusters

# Start the cluster node if it is stopped
podman start <cluster-name>-control-plane
```

---

### Step 3 — Deploy Keycloak

```bash
kubectl apply -f k8s/keycloak.yaml
kubectl rollout status deployment/keycloak -n keycloak --timeout=120s
```

---

### Step 4 — Install dependencies and generate SP certificate

```bash
make setup
```

This script (`dev_setup.sh`) does the following:

1. Installs Homebrew system libraries: `libxml2`, `libxmlsec1`, `pkg-config`, `openssl`
2. Creates `.venv` and runs `pip install ".[dev]"`
3. Generates a self-signed SP certificate at `app/saml/certs/sp.crt`
4. Downloads IDP metadata from Keycloak into `app/saml/idp_metadata.xml`

> Step 4 requires Keycloak to be running and port-forwarded. If it is not ready yet, run `make setup` again after step 6.

---

### Step 5 — Start port-forwards (two terminals)

**Terminal A — Keycloak:**
```bash
make pf-keycloak
# kubectl port-forward -n keycloak svc/keycloak 8080:8080
```

**Terminal B — FastAPI (only needed for the k8s deployment):**
```bash
make pf-fastapi
# kubectl port-forward -n fastapi-saml svc/fastapi-saml 8000:8000
```

---

### Step 6 — Configure Keycloak and sync IDP metadata

```bash
bash setup_keycloak.sh
```

This script:

1. Creates the `saml-demo` realm
2. Fetches SP metadata from `http://localhost:8000/metadata`
3. Registers FastAPI as a SAML client in Keycloak **using the SP metadata XML**
4. Disables client-signature requirement (SP sends unsigned requests)
5. Sets `role_list` mapper to `single=true` (prevents duplicate attribute error)
6. Creates a test user: `testuser` / `Test@1234`
7. Downloads IDP metadata from Keycloak → updates the k8s ConfigMap → restarts FastAPI

> After this script restarts the FastAPI pod, re-run the port-forward from Terminal B.

---

### Step 7 — Run the app locally with uvicorn

```bash
make run
# .venv/bin/uvicorn main:app --app-dir app --reload --port 8000
```

Open **http://localhost:8000** in your browser.

---

## URLs

| | URL |
|--|-----|
| FastAPI app | http://localhost:8000 |
| SP metadata | http://localhost:8000/metadata |
| Keycloak admin | http://localhost:8080/admin &nbsp; (`admin` / `admin`) |
| Keycloak realm | http://localhost:8080/realms/saml-demo |
| SAML SSO / SLO | http://localhost:8080/realms/saml-demo/protocol/saml |
| IDP metadata | http://localhost:8080/realms/saml-demo/protocol/saml/descriptor |

**Test user:** `testuser` / `Test@1234`

---

## Run the end-to-end test

```bash
make test
```

Runs `test_e2e.py` — 10 automated checks covering the full SAML flow: health, metadata, login redirect, Keycloak form submit, ACS assertion validation, profile page, and logout.

---

## Makefile targets

```
make setup        Install system deps, create .venv, generate SP cert, fetch IDP metadata
make run          Start uvicorn with --reload on :8000
make install      Re-sync dependencies after editing pyproject.toml
make test         Run end-to-end SAML test
make pf-keycloak  Port-forward Keycloak → localhost:8080
make pf-fastapi   Port-forward in-cluster FastAPI → localhost:8000
```

---

## Kubernetes deployment

```bash
# Deploy Keycloak
kubectl apply -f k8s/keycloak.yaml

# Deploy FastAPI (after building and loading the image)
podman build -t fastapi-saml:latest .
podman save fastapi-saml:latest -o /tmp/fastapi-saml.tar
podman cp /tmp/fastapi-saml.tar <kind-node>:/tmp/fastapi-saml.tar
podman exec <kind-node> ctr -n k8s.io images import /tmp/fastapi-saml.tar
kubectl apply -f k8s/fastapi.yaml

# Configure Keycloak (with both port-forwards active)
bash setup_keycloak.sh
```

---

## Environment variables reference

| Variable | Default | Description |
|----------|---------|-------------|
| `SP_ENTITY_ID` | `http://localhost:8000/metadata` | SP Entity ID registered in Keycloak |
| `SP_ACS_URL` | `http://localhost:8000/acs` | Assertion Consumer Service URL |
| `SP_SLS_URL` | `http://localhost:8000/sls` | Single Logout Service URL |
| `SAML_ROLE_ATTRIBUTE` | `Role` | SAML attribute name that contains roles |
| `SAML_ROLE_MAP` | _(empty)_ | Pipe-separated `idp_role:app_role` pairs; empty = passthrough |

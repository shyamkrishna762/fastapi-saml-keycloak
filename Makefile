PYTHON     := .venv/bin/python
UVICORN    := .venv/bin/uvicorn
APP_DIR    := app
PORT       := 8000

# Needed for Homebrew xmlsec on macOS
export PKG_CONFIG_PATH := $(shell brew --prefix libxml2 2>/dev/null)/lib/pkgconfig:$(shell brew --prefix libxmlsec1 2>/dev/null)/lib/pkgconfig:$(PKG_CONFIG_PATH)

.PHONY: setup run dev test pf-keycloak pf-fastapi help

help:
	@echo ""
	@echo "  make setup        Install deps, generate SP certs, fetch IDP metadata"
	@echo "  make run          Start FastAPI with uvicorn (auto-reload)"
	@echo "  make test         Run end-to-end SAML test"
	@echo "  make pf-keycloak  Port-forward Keycloak to localhost:8080"
	@echo "  make pf-fastapi   Port-forward in-cluster FastAPI to localhost:8000"
	@echo ""

setup:
	bash dev_setup.sh

# Re-install deps after editing pyproject.toml
install:
	PKG_CONFIG_PATH=$(PKG_CONFIG_PATH) $(PYTHON) -m pip install --quiet ".[dev]"

run: app/saml/certs/sp.crt app/saml/idp_metadata.xml
	@echo "Starting FastAPI on http://localhost:$(PORT) ..."
	$(UVICORN) main:app \
	  --app-dir $(APP_DIR) \
	  --reload \
	  --port $(PORT) \
	  --log-level info

dev: setup run

test:
	$(PYTHON) test_e2e.py

pf-keycloak:
	kubectl --context kind-agentregistry port-forward -n keycloak svc/keycloak 8080:8080

pf-fastapi:
	kubectl --context kind-agentregistry port-forward -n fastapi-saml svc/fastapi-saml 8000:8000

# Guard: remind user to run setup if venv is missing
.venv/bin/activate:
	@echo "Run 'make setup' first." && exit 1

app/saml/certs/sp.crt:
	@echo "SP certs missing — run 'make setup' first." && exit 1

app/saml/idp_metadata.xml:
	@grep -q "EntityDescriptor" app/saml/idp_metadata.xml 2>/dev/null || \
	  { echo "IDP metadata is a placeholder — run 'make setup' first."; exit 1; }

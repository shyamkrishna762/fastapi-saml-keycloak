FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    libxml2-dev \
    libxmlsec1-dev \
    libxmlsec1-openssl \
    pkg-config \
    openssl \
    && rm -rf /var/lib/apt/lists/*

# Copy only pyproject.toml first so the dependency layer is cached separately
# from the application code. Re-runs only when pyproject.toml changes.
COPY pyproject.toml .
RUN pip install --no-cache-dir .

COPY app/ .

RUN mkdir -p saml/certs && \
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout saml/certs/sp.key \
      -out saml/certs/sp.crt \
      -subj "/CN=fastapi-saml-sp/O=Demo/C=US"

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--log-level", "info"]

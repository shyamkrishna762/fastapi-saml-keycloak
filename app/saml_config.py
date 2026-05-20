import os
from pathlib import Path
from onelogin.saml2.idp_metadata_parser import OneLogin_Saml2_IdPMetadataParser

BASE_DIR = Path(__file__).parent
SAML_DIR = BASE_DIR / "saml"
CERTS_DIR = SAML_DIR / "certs"
IDP_METADATA_FILE = SAML_DIR / "idp_metadata.xml"

SP_ENTITY_ID = os.getenv("SP_ENTITY_ID", "http://localhost:8000/metadata")
SP_ACS_URL = os.getenv("SP_ACS_URL", "http://localhost:8000/acs")
SP_SLS_URL = os.getenv("SP_SLS_URL", "http://localhost:8000/sls")


def _load_cert(path: Path) -> str:
    if not path.exists():
        return ""
    content = path.read_text()
    lines = [line for line in content.splitlines() if line and not line.startswith("---")]
    return "".join(lines)


def _sp_config() -> dict:
    return {
        "entityId": SP_ENTITY_ID,
        "assertionConsumerService": {
            "url": SP_ACS_URL,
            "binding": "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST",
        },
        "singleLogoutService": {
            "url": SP_SLS_URL,
            "binding": "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect",
        },
        "NameIDFormat": "urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified",
        "x509cert": _load_cert(CERTS_DIR / "sp.crt"),
        "privateKey": _load_cert(CERTS_DIR / "sp.key"),
    }


def _idp_config() -> dict:
    if not IDP_METADATA_FILE.exists():
        raise FileNotFoundError(
            f"IDP metadata file not found at {IDP_METADATA_FILE}.\n"
            "Run setup_keycloak.sh to download and configure it."
        )
    raw = IDP_METADATA_FILE.read_text().strip()
    if not raw or raw.startswith("<!--"):
        raise ValueError(
            "IDP metadata file is a placeholder. Run setup_keycloak.sh first."
        )
    parsed = OneLogin_Saml2_IdPMetadataParser.parse(raw)
    return parsed.get("idp", {})


def get_saml_settings() -> dict:
    return {
        "strict": False,
        "debug": True,
        "sp": _sp_config(),
        "idp": _idp_config(),
        "security": {
            "nameIdEncrypted": False,
            "authnRequestsSigned": False,
            "logoutRequestSigned": False,
            "logoutResponseSigned": False,
            "signMetadata": False,
            "wantMessagesSigned": False,
            "wantAssertionsSigned": False,
            "wantNameIdEncrypted": False,
        },
    }


def get_sp_only_settings() -> dict:
    """Used by /metadata endpoint — IDP is a stub so metadata can be served before Keycloak config."""
    return {
        "strict": False,
        "debug": True,
        "sp": _sp_config(),
        "idp": {
            "entityId": "urn:placeholder",
            "singleSignOnService": {
                "url": "http://placeholder/sso",
                "binding": "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect",
            },
            "x509cert": "",
        },
    }

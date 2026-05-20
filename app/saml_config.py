import os
from pathlib import Path
from dotenv import load_dotenv, find_dotenv
from onelogin.saml2.idp_metadata_parser import OneLogin_Saml2_IdPMetadataParser

# Searches up the directory tree — finds .env in project root whether running
# locally with uvicorn or inside the Docker container.
load_dotenv(find_dotenv(usecwd=True))

BASE_DIR = Path(__file__).parent
SAML_DIR = BASE_DIR / "saml"
IDP_METADATA_FILE = SAML_DIR / "idp_metadata.xml"

SP_ENTITY_ID = os.getenv("SP_ENTITY_ID", "http://localhost:8000/metadata")
SP_ACS_URL = os.getenv("SP_ACS_URL", "http://localhost:8000/acs")
SP_SLS_URL = os.getenv("SP_SLS_URL", "http://localhost:8000/sls")

# Role attribute name as it appears in the SAML assertion.
# Keycloak default: "Role"
# Azure AD / Entra: "http://schemas.microsoft.com/ws/2008/06/identity/claims/role"
# Okta / Auth0: "roles" or "groups"
SAML_ROLE_ATTRIBUTE = os.getenv("SAML_ROLE_ATTRIBUTE", "Role")

# Optional role-value mapping: pipe-separated idp_role:app_role pairs.
# Example: "default-roles-saml-demo:user|uma_authorization:admin"
# If empty → all IdP roles are stored as-is (passthrough).
# If set   → only listed roles are kept; unlisted roles are dropped.
# Using "|" as pair separator so role names that contain commas (e.g. LDAP DNs) are safe.
_ROLE_MAP_RAW = os.getenv("SAML_ROLE_MAP", "").strip()


def get_role_map() -> dict[str, str]:
    if not _ROLE_MAP_RAW:
        return {}
    result: dict[str, str] = {}
    for pair in _ROLE_MAP_RAW.split("|"):
        pair = pair.strip()
        if ":" in pair:
            idp_role, app_role = pair.split(":", 1)
            result[idp_role.strip()] = app_role.strip()
    return result


def map_roles(raw_roles: list[str]) -> list[str]:
    """
    Map IdP role values to application roles.
    - No SAML_ROLE_MAP set  → return raw_roles unchanged.
    - SAML_ROLE_MAP set     → keep only roles present in the map, return their mapped values.
      Deduplicates so two IdP roles that map to the same app role appear once.
    """
    role_map = get_role_map()
    if not role_map:
        return list(raw_roles)
    seen: set[str] = set()
    mapped: list[str] = []
    for role in raw_roles:
        app_role = role_map.get(role)
        if app_role and app_role not in seen:
            mapped.append(app_role)
            seen.add(app_role)
    return mapped


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


def _security_settings() -> dict:
    return {
        "nameIdEncrypted": False,
        "authnRequestsSigned": False,
        "logoutRequestSigned": False,
        "logoutResponseSigned": False,
        "signMetadata": False,
        "wantMessagesSigned": False,
        "wantAssertionsSigned": True,   # validate IdP signature using cert from idp_metadata.xml
        "wantNameIdEncrypted": False,
        "wantAssertionsEncrypted": False,
    }


def get_saml_settings() -> dict:
    return {
        "strict": False,
        "debug": True,
        "sp": _sp_config(),
        "idp": _idp_config(),
        "security": _security_settings(),
    }


def get_sp_only_settings() -> dict:
    """Used by /metadata endpoint — IDP is a stub so metadata can be served before Keycloak config.
    Security settings are shared so the metadata reflects the real SP capabilities
    (AuthnRequestsSigned, WantAssertionsSigned, encryption KeyDescriptor)."""
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
        "security": _security_settings(),
    }

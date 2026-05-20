import secrets
from typing import Optional
from urllib.parse import urlparse

from fastapi import FastAPI, Request, Response, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from onelogin.saml2.auth import OneLogin_Saml2_Auth
from onelogin.saml2.settings import OneLogin_Saml2_Settings

from saml_config import get_saml_settings, get_sp_only_settings, SAML_ROLE_ATTRIBUTE, map_roles

app = FastAPI(title="FastAPI SAML SSO")
templates = Jinja2Templates(directory="templates")

# In-memory session store — use Redis/DB in production
_sessions: dict[str, dict] = {}


# ── helpers ──────────────────────────────────────────────────────────────────

def _session_id(request: Request) -> Optional[str]:
    return request.cookies.get("session_id")


def _get_session(request: Request) -> Optional[dict]:
    sid = _session_id(request)
    return _sessions.get(sid) if sid else None


async def _build_saml_req(request: Request) -> dict:
    form_data: dict = {}
    if request.method == "POST":
        form = await request.form()
        form_data = dict(form)
    host = request.headers.get("host", "localhost:8000")
    return {
        "https": "on" if request.url.scheme == "https" else "off",
        "http_host": host,
        "script_name": request.url.path,
        "server_port": str(request.url.port or 8000),
        "get_data": dict(request.query_params),
        "post_data": form_data,
    }


def _make_auth(req: dict) -> OneLogin_Saml2_Auth:
    return OneLogin_Saml2_Auth(req, old_settings=get_saml_settings())


def _safe_redirect(url: Optional[str], fallback: str = "/") -> str:
    if not url:
        return fallback
    parsed = urlparse(url)
    # Only allow relative redirects
    return url if not parsed.netloc else fallback


# ── routes ───────────────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    session = _get_session(request)
    return templates.TemplateResponse("index.html", {
        "request": request,
        "user": session.get("nameid") if session else None,
    })


@app.get("/login")
async def login(request: Request):
    req = await _build_saml_req(request)
    try:
        auth = _make_auth(req)
    except (FileNotFoundError, ValueError) as exc:
        raise HTTPException(status_code=503, detail=str(exc))
    return RedirectResponse(auth.login())


@app.post("/acs")
async def acs(request: Request):
    req = await _build_saml_req(request)
    auth = _make_auth(req)
    auth.process_response()

    errors = auth.get_errors()
    if errors:
        reason = auth.get_last_error_reason()
        raise HTTPException(status_code=400, detail=f"SAML error: {errors} — {reason}")

    if not auth.is_authenticated():
        raise HTTPException(status_code=401, detail="Authentication failed")

    attributes = dict(auth.get_attributes())
    raw_roles: list[str] = attributes.get(SAML_ROLE_ATTRIBUTE, [])
    mapped_roles = map_roles(raw_roles)

    sid = secrets.token_urlsafe(32)
    _sessions[sid] = {
        "nameid": auth.get_nameid(),
        "attributes": attributes,
        "roles": mapped_roles,
        "raw_roles": raw_roles,
        "session_index": auth.get_session_index(),
    }

    relay_state = req["post_data"].get("RelayState", "/profile")
    redirect_url = _safe_redirect(relay_state, "/profile")

    resp = RedirectResponse(url=redirect_url, status_code=303)
    resp.set_cookie("session_id", sid, httponly=True, samesite="lax")
    return resp


@app.get("/profile", response_class=HTMLResponse)
async def profile(request: Request):
    session = _get_session(request)
    if not session:
        return RedirectResponse("/login")
    return templates.TemplateResponse("profile.html", {
        "request": request,
        "nameid": session["nameid"],
        "attributes": session["attributes"],
        "roles": session.get("roles", []),
        "raw_roles": session.get("raw_roles", []),
        "role_attribute": SAML_ROLE_ATTRIBUTE,
    })


@app.get("/logout")
async def logout(request: Request):
    req = await _build_saml_req(request)
    session = _get_session(request)
    sid = _session_id(request)

    try:
        auth = _make_auth(req)
        name_id = session.get("nameid") if session else None
        session_index = session.get("session_index") if session else None
        slo_url = auth.logout(name_id=name_id, session_index=session_index)
    except Exception:
        slo_url = "/"

    if sid and sid in _sessions:
        del _sessions[sid]

    resp = RedirectResponse(slo_url)
    resp.delete_cookie("session_id")
    return resp


@app.get("/sls")
async def sls(request: Request):
    req = await _build_saml_req(request)
    auth = _make_auth(req)

    sid = _session_id(request)
    if sid and sid in _sessions:
        del _sessions[sid]

    redirect_url = auth.process_slo(delete_session_cb=lambda: None)
    errors = auth.get_errors()
    if errors:
        raise HTTPException(status_code=400, detail=f"SLO error: {errors}")

    resp = RedirectResponse(redirect_url or "/")
    resp.delete_cookie("session_id")
    return resp


@app.get("/metadata")
async def metadata():
    """Serve SP metadata XML — register this in Keycloak as a SAML client."""
    settings = OneLogin_Saml2_Settings(settings=get_sp_only_settings(), sp_validation_only=True)
    xml = settings.get_sp_metadata()
    errors = settings.validate_metadata(xml)
    if errors:
        raise HTTPException(status_code=500, detail=f"Metadata error: {errors}")
    return Response(content=xml, media_type="application/xml")

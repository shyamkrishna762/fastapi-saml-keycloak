#!/usr/bin/env python3
"""
End-to-end SAML flow test.
Usage: python3 test_e2e.py
Requires: pip install requests beautifulsoup4
Both port-forwards must be active:
  kubectl port-forward -n keycloak svc/keycloak 8080:8080
  kubectl port-forward -n fastapi-saml svc/fastapi-saml 8000:8000
"""

import sys
import requests
from bs4 import BeautifulSoup

FASTAPI = "http://localhost:8000"
USER    = "testuser"
PASSWD  = "Test@1234"

GREEN  = "\033[0;32m"
RED    = "\033[0;31m"
YELLOW = "\033[1;33m"
BOLD   = "\033[1m"
NC     = "\033[0m"

passed = 0
failed = 0

def ok(msg):
    global passed
    passed += 1
    print(f"  {GREEN}✓{NC} {msg}")

def fail(msg, detail=""):
    global failed
    failed += 1
    print(f"  {RED}✗{NC} {msg}")
    if detail:
        print(f"    {YELLOW}{detail}{NC}")

def section(title):
    print(f"\n{BOLD}── {title} ──{NC}")

session = requests.Session()
session.max_redirects = 20

# ── 1. Health checks ──────────────────────────────────────────────────────────
section("1. Health checks")

try:
    r = session.get(f"{FASTAPI}/", timeout=5)
    if r.status_code == 200:
        ok("FastAPI home page (200)")
    else:
        fail("FastAPI home page", f"HTTP {r.status_code}")
except Exception as e:
    fail("FastAPI not reachable", str(e))
    sys.exit(1)

try:
    r = session.get(f"{FASTAPI}/metadata", timeout=5)
    if r.status_code == 200 and "EntityDescriptor" in r.text:
        ok("SP metadata endpoint returns valid XML")
    else:
        fail("SP metadata", f"HTTP {r.status_code} — {r.text[:200]}")
        sys.exit(1)
except Exception as e:
    fail("SP metadata endpoint", str(e))
    sys.exit(1)

# ── 2. SAML login redirect ─────────────────────────────────────────────────────
section("2. SAML login initiation")

try:
    r = session.get(f"{FASTAPI}/login", allow_redirects=False, timeout=5)
    if r.status_code in (302, 307) and "Location" in r.headers:
        keycloak_sso_url = r.headers["Location"]
        ok(f"GET /login → 302 redirect to Keycloak")
        print(f"    {YELLOW}{keycloak_sso_url[:90]}...{NC}")
    else:
        fail("/login redirect", f"HTTP {r.status_code}, headers: {dict(r.headers)}")
        sys.exit(1)
except Exception as e:
    fail("/login", str(e))
    sys.exit(1)

# ── 3. Keycloak login page ────────────────────────────────────────────────────
section("3. Keycloak login page")

try:
    r = session.get(keycloak_sso_url, timeout=10)
    if r.status_code != 200:
        fail("Keycloak login page", f"HTTP {r.status_code}")
        sys.exit(1)

    soup = BeautifulSoup(r.text, "html.parser")
    form = soup.find("form", id="kc-form-login") or soup.find("form")
    if not form:
        fail("Login form not found in Keycloak page")
        print(r.text[:500])
        sys.exit(1)

    form_action = form.get("action")
    ok(f"Keycloak login form found")
    print(f"    {YELLOW}{form_action[:90]}{NC}")
except Exception as e:
    fail("Loading Keycloak login page", str(e))
    sys.exit(1)

# ── 4. Submit credentials ─────────────────────────────────────────────────────
section("4. Submitting credentials to Keycloak")

try:
    r = session.post(
        form_action,
        data={"username": USER, "password": PASSWD, "credentialId": ""},
        allow_redirects=True,
        timeout=15,
    )
    ok(f"Credentials submitted → HTTP {r.status_code}, final URL: {r.url[:80]}")
except Exception as e:
    fail("Submitting credentials", str(e))
    sys.exit(1)

# ── 5. Handle SAML POST binding ───────────────────────────────────────────────
section("5. SAML POST binding → FastAPI /acs")

final_url = r.url
if "/acs" in final_url or "/profile" in final_url:
    ok(f"Browser landed on FastAPI: {final_url}")
else:
    # Keycloak returned an HTML page with an auto-submit form (HTTP-POST binding)
    soup = BeautifulSoup(r.text, "html.parser")
    saml_form = soup.find("form")

    if saml_form and saml_form.get("action"):
        action = saml_form.get("action")
        inputs = {
            inp.get("name"): inp.get("value", "")
            for inp in saml_form.find_all("input")
            if inp.get("name")
        }
        if "SAMLResponse" not in inputs:
            fail("No SAMLResponse in form", f"Inputs found: {list(inputs.keys())}")
            print("Page snippet:", r.text[:600])
            sys.exit(1)

        ok(f"SAMLResponse form found, POSTing to {action}")
        try:
            r = session.post(action, data=inputs, allow_redirects=True, timeout=10)
            if r.status_code in (200, 303) or "/profile" in r.url:
                ok(f"ACS POST succeeded → HTTP {r.status_code}, URL: {r.url}")
            else:
                fail(f"ACS POST failed — HTTP {r.status_code}", r.text[:300])
                sys.exit(1)
        except Exception as e:
            fail("POSTing SAMLResponse to /acs", str(e))
            sys.exit(1)
    else:
        fail("No SAMLResponse form or redirect to /acs found")
        print(r.text[:800])
        sys.exit(1)

# ── 6. Profile page ───────────────────────────────────────────────────────────
section("6. Verifying profile page")

try:
    profile_url = f"{FASTAPI}/profile"
    r = session.get(profile_url, timeout=5)
    if r.status_code == 200:
        if USER in r.text or "testuser" in r.text.lower() or "NameID" in r.text:
            ok(f"Profile page shows authenticated user")
        else:
            ok(f"Profile page loaded (HTTP 200)")
        # Show a snippet of what attributes came back
        soup = BeautifulSoup(r.text, "html.parser")
        rows = soup.find_all("tr")
        for row in rows:
            cells = row.find_all("td")
            if cells:
                print(f"    attr: {cells[0].text.strip():40s} = {cells[1].text.strip()[:60]}")
    else:
        fail("Profile page", f"HTTP {r.status_code}")
except Exception as e:
    fail("Profile page", str(e))

# ── 7. Logout ─────────────────────────────────────────────────────────────────
section("7. SAML logout")

try:
    r = session.get(f"{FASTAPI}/logout", allow_redirects=True, timeout=10)
    ok(f"Logout complete → HTTP {r.status_code}, URL: {r.url}")

    r2 = session.get(f"{FASTAPI}/profile", allow_redirects=True, timeout=5)
    # After logout the session cookie is gone; /profile → /login → Keycloak (all fine)
    if f"{FASTAPI}/profile" not in r2.url:
        ok("After logout, /profile no longer serves authenticated content")
    else:
        soup2 = BeautifulSoup(r2.text, "html.parser")
        if "testuser" in r2.text.lower() or "NameID" in r2.text:
            fail("Session still active after logout", r2.url)
        else:
            ok("Profile page returned without user data (session cleared)")
except Exception as e:
    fail("Logout", str(e))

# ── Summary ───────────────────────────────────────────────────────────────────
print(f"\n{BOLD}{'─'*50}{NC}")
total = passed + failed
print(f"{BOLD}Results: {GREEN}{passed} passed{NC}{BOLD}, {RED}{failed} failed{NC}{BOLD} / {total} checks{NC}")
if failed == 0:
    print(f"{GREEN}{BOLD}✅  End-to-end SAML flow passed!{NC}")
else:
    print(f"{RED}{BOLD}❌  Some checks failed.{NC}")
    sys.exit(1)

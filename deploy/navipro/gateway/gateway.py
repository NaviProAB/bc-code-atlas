"""Sign-in gateway in front of the bc-code-atlas aggregator.

The atlas servers have no login of their own. This gateway is the only thing
exposed to the internet; it checks every request and forwards the allowed ones
to the aggregator on 127.0.0.1.

A caller sends `Authorization: Bearer <token>`, where the token is either:

* a **GitHub token** of a person who is a member of an allowed organization
  (NaviProAB). The gateway asks GitHub who the token belongs to and whether
  that login is a member, and remembers the answer for a few minutes.
* a **service key** issued to a system that has no personal GitHub login
  (GitHub Monitor, the Evolve agent). Keys live in a file on the server as
  SHA-256 hashes, one per service, so a key can be revoked on its own.

Nothing but who called, which tool, the status and the duration is logged.
Query text is never logged.
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import hmac
import json
import logging
import os
import time
from pathlib import Path

import httpx
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

UPSTREAM = os.environ.get("ATLAS_UPSTREAM", "http://127.0.0.1:8800").rstrip("/")
ALLOWED_ORGS = [o.strip() for o in os.environ.get("ATLAS_GITHUB_ORGS", "NaviProAB").split(",") if o.strip()]
KEYS_FILE = Path(os.environ.get("ATLAS_SERVICE_KEYS_FILE", "/etc/bcatlas/service-keys.json"))
GITHUB_API = os.environ.get("ATLAS_GITHUB_API", "https://api.github.com").rstrip("/")
ALLOW_TTL_S = float(os.environ.get("ATLAS_ALLOW_TTL_SECONDS", "600"))
DENY_TTL_S = float(os.environ.get("ATLAS_DENY_TTL_SECONDS", "60"))
MAX_BODY_BYTES = int(os.environ.get("ATLAS_MAX_BODY_BYTES", str(1024 * 1024)))

log = logging.getLogger("bcatlas.gateway")

# Hop-by-hop headers, plus the ones the gateway must not pass on: the caller's
# credential never reaches the atlas servers.
_DROP_REQUEST = {"authorization", "host", "content-length", "connection", "keep-alive", "transfer-encoding",
                 "upgrade", "proxy-authorization", "te", "trailer", "cookie", "x-atlas-caller"}
_DROP_RESPONSE = {"content-length", "connection", "keep-alive", "transfer-encoding", "upgrade", "content-encoding"}


def _sha256(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


class ServiceKeys:
    """{"services": {"github-monitor": {"sha256": "<hex>"}, ...}}, reloaded when the file changes."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._mtime = -1.0
        self._by_hash: dict[str, str] = {}

    def lookup(self, token: str) -> str | None:
        self._reload()
        digest = _sha256(token)
        found = None
        # Compare against every key so timing does not reveal which one matched.
        for known, name in self._by_hash.items():
            if hmac.compare_digest(known, digest):
                found = name
        return found

    def _reload(self) -> None:
        try:
            mtime = self._path.stat().st_mtime
        except OSError:
            self._by_hash, self._mtime = {}, -1.0
            return
        if mtime == self._mtime:
            return
        try:
            data = json.loads(self._path.read_text(encoding="utf-8"))
            self._by_hash = {str(v["sha256"]).lower(): name for name, v in data.get("services", {}).items()}
            self._mtime = mtime
            log.info("loaded %d service key(s)", len(self._by_hash))
        except (OSError, ValueError, KeyError, TypeError) as exc:
            log.error("cannot read service keys file: %s", exc)


class GitHubMembers:
    """Is the owner of this GitHub token a member of an allowed organization?"""

    def __init__(self, client: httpx.AsyncClient) -> None:
        self._client = client
        self._cache: dict[str, tuple[float, str | None]] = {}
        self._locks: dict[str, asyncio.Lock] = {}

    async def caller(self, token: str) -> str | None:
        key = _sha256(token)
        hit = self._cache.get(key)
        if hit and hit[0] > time.monotonic():
            return hit[1]
        lock = self._locks.setdefault(key, asyncio.Lock())
        async with lock:
            hit = self._cache.get(key)
            if hit and hit[0] > time.monotonic():
                return hit[1]
            try:
                who = await self._ask_github(token)
            except httpx.HTTPError as exc:
                # GitHub unreachable: refuse, and do not remember the refusal.
                log.warning("GitHub check failed: %s", type(exc).__name__)
                return None
            self._cache[key] = (time.monotonic() + (ALLOW_TTL_S if who else DENY_TTL_S), who)
            if len(self._cache) > 5000:
                now = time.monotonic()
                self._cache = {k: v for k, v in self._cache.items() if v[0] > now}
            self._locks.pop(key, None)
            return who

    async def _ask_github(self, token: str) -> str | None:
        headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "bc-code-atlas-gateway"}
        r = await self._client.get(f"{GITHUB_API}/user", headers=headers)
        if r.status_code != 200:
            return None
        login = r.json().get("login")
        if not login:
            return None
        for org in ALLOWED_ORGS:
            # 204 = member. A token that cannot see the organization gets 302 or 404.
            m = await self._client.get(f"{GITHUB_API}/orgs/{org}/members/{login}", headers=headers, follow_redirects=False)
            if m.status_code == 204:
                return f"github:{login}"
        log.info("refused github:%s (not a member of %s)", login, ",".join(ALLOWED_ORGS))
        return None


def _tool_name(body: bytes) -> str:
    """The MCP method (and tool, for tools/call) of a request, for the access log."""
    try:
        msg = json.loads(body)
        if isinstance(msg, list):
            msg = msg[0] if msg else {}
        method = str(msg.get("method", "-"))
        if method == "tools/call":
            return f"tools/call:{msg.get('params', {}).get('name', '-')}"
        return method
    except (ValueError, AttributeError, TypeError):
        return "-"


def _unauthorized(detail: str) -> JSONResponse:
    return JSONResponse(
        {"error": "unauthorized", "detail": detail},
        status_code=401,
        headers={"WWW-Authenticate": 'Bearer realm="bc-code-atlas"'},
    )


def create_app() -> Starlette:
    github_client = httpx.AsyncClient(timeout=10.0)
    upstream_client = httpx.AsyncClient(timeout=httpx.Timeout(connect=5.0, read=3600.0, write=30.0, pool=10.0))
    keys = ServiceKeys(KEYS_FILE)
    members = GitHubMembers(github_client)

    async def healthz(_: Request) -> Response:
        return JSONResponse({"status": "ok"})

    async def proxy(request: Request) -> Response:
        started = time.monotonic()
        auth = request.headers.get("authorization", "")
        scheme, _, token = auth.partition(" ")
        token = token.strip()
        if scheme.lower() != "bearer" or not token:
            return _unauthorized("Send 'Authorization: Bearer <token>': a GitHub token of an organization member, or a service key.")
        caller = keys.lookup(token) or await members.caller(token)
        if not caller:
            return _unauthorized("The token is not a service key and does not belong to a member of an allowed GitHub organization.")
        if not caller.startswith("github:"):
            caller = f"service:{caller}"

        body = await request.body()
        if len(body) > MAX_BODY_BYTES:
            return JSONResponse({"error": "request too large"}, status_code=413)
        headers = {k: v for k, v in request.headers.items() if k.lower() not in _DROP_REQUEST}
        headers["x-atlas-caller"] = caller
        url = f"{UPSTREAM}{request.url.path}"
        if request.url.query:
            url += f"?{request.url.query}"
        try:
            upstream_request = upstream_client.build_request(request.method, url, headers=headers, content=body)
            upstream = await upstream_client.send(upstream_request, stream=True)
        except httpx.HTTPError as exc:
            log.error("%s %s -> upstream unavailable (%s)", caller, _tool_name(body), type(exc).__name__)
            return JSONResponse({"error": "atlas backend unavailable"}, status_code=502)

        async def stream():
            try:
                async for chunk in upstream.aiter_raw():
                    yield chunk
            finally:
                await upstream.aclose()
                log.info("%s %s %s -> %d in %.0f ms", caller, request.method, _tool_name(body),
                         upstream.status_code, (time.monotonic() - started) * 1000)

        out_headers = {k: v for k, v in upstream.headers.items() if k.lower() not in _DROP_RESPONSE}
        return StreamingResponse(stream(), status_code=upstream.status_code, headers=out_headers)

    @contextlib.asynccontextmanager
    async def lifespan(_: Starlette):
        yield
        await github_client.aclose()
        await upstream_client.aclose()

    return Starlette(
        routes=[
            Route("/healthz", healthz, methods=["GET"]),
            Route("/{path:path}", proxy, methods=["GET", "POST", "DELETE"]),
        ],
        lifespan=lifespan,
    )


app = create_app()

if __name__ == "__main__":
    import uvicorn

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)  # one line per request is enough: ours
    uvicorn.run(app, host=os.environ.get("ATLAS_GATEWAY_HOST", "127.0.0.1"),
                port=int(os.environ.get("ATLAS_GATEWAY_PORT", "8790")), access_log=False)

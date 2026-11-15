"""Gateway tests against a fake GitHub and a fake atlas backend (no network)."""

from __future__ import annotations

import hashlib
import importlib
import json
import sys
from pathlib import Path

import httpx
import pytest
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

MEMBER, OUTSIDER, SERVICE_KEY = "ghp_member", "ghp_outsider", "svc-key-123"
seen_upstream: list[dict] = []
github_calls: list[str] = []


async def _gh_user(request: Request) -> Response:
    github_calls.append("user")
    token = request.headers["authorization"].removeprefix("Bearer ")
    login = {MEMBER: "alice", OUTSIDER: "mallory"}.get(token)
    return JSONResponse({"login": login}) if login else JSONResponse({"message": "Bad credentials"}, status_code=401)


async def _gh_member(request: Request) -> Response:
    ok = request.path_params["org"] == "NaviProAB" and request.path_params["login"] == "alice"
    return Response(status_code=204 if ok else 404)


async def _atlas(request: Request) -> Response:
    seen_upstream.append({"headers": dict(request.headers), "body": (await request.body()).decode()})
    return JSONResponse({"jsonrpc": "2.0", "id": 1, "result": {"ok": True}}, headers={"mcp-session-id": "s1"})


fake_github = Starlette(routes=[Route("/user", _gh_user), Route("/orgs/{org}/members/{login}", _gh_member)])
fake_atlas = Starlette(routes=[Route("/{path:path}", _atlas, methods=["GET", "POST", "DELETE"])])


@pytest.fixture
async def client(tmp_path, monkeypatch):
    keys = tmp_path / "keys.json"
    keys.write_text(json.dumps({"services": {"github-monitor": {"sha256": hashlib.sha256(SERVICE_KEY.encode()).hexdigest()}}}))
    monkeypatch.setenv("ATLAS_SERVICE_KEYS_FILE", str(keys))
    monkeypatch.setenv("ATLAS_GITHUB_ORGS", "NaviProAB")
    monkeypatch.setenv("ATLAS_GITHUB_API", "http://github.test")
    monkeypatch.setenv("ATLAS_UPSTREAM", "http://atlas.test")

    real_client = httpx.AsyncClient

    def routed(*args, **kwargs):
        # Every client the gateway creates talks to the fakes instead of the network.
        async def handler(request: httpx.Request) -> httpx.Response:
            target = fake_github if request.url.host == "github.test" else fake_atlas
            async with real_client(transport=httpx.ASGITransport(app=target), base_url=str(request.url.copy_with(path="/", query=None))) as c:
                r = await c.request(request.method, request.url, headers=request.headers, content=request.content)
                # A stream, as a real network response is: the gateway reads it with aiter_raw().
                headers = {k: v for k, v in r.headers.items() if k.lower() != "content-length"}
                return httpx.Response(r.status_code, headers=headers, stream=httpx.ByteStream(r.content))
        return real_client(transport=httpx.MockTransport(handler))

    monkeypatch.setattr(httpx, "AsyncClient", routed)
    import gateway
    importlib.reload(gateway)
    seen_upstream.clear()
    github_calls.clear()
    async with real_client(transport=httpx.ASGITransport(app=gateway.app), base_url="http://gw") as c:
        yield c


BODY = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "bcatlas_search", "arguments": {"query": "x"}}}


async def test_no_token_is_refused(client):
    r = await client.post("/mcp", json=BODY)
    assert r.status_code == 401 and "Bearer" in r.headers["www-authenticate"]
    assert not seen_upstream


async def test_org_member_is_forwarded_without_their_token(client):
    r = await client.post("/mcp", json=BODY, headers={"Authorization": f"Bearer {MEMBER}"})
    assert r.status_code == 200 and r.json()["result"]["ok"] is True
    assert r.headers["mcp-session-id"] == "s1"
    sent = seen_upstream[0]["headers"]
    assert "authorization" not in sent
    assert sent["x-atlas-caller"] == "github:alice"
    assert json.loads(seen_upstream[0]["body"]) == BODY


async def test_non_member_is_refused(client):
    r = await client.post("/mcp", json=BODY, headers={"Authorization": f"Bearer {OUTSIDER}"})
    assert r.status_code == 401 and not seen_upstream


async def test_invalid_token_is_refused(client):
    r = await client.post("/mcp", json=BODY, headers={"Authorization": "Bearer nonsense"})
    assert r.status_code == 401 and not seen_upstream


async def test_service_key_is_accepted_without_asking_github(client):
    r = await client.post("/mcp", json=BODY, headers={"Authorization": f"Bearer {SERVICE_KEY}"})
    assert r.status_code == 200
    assert seen_upstream[0]["headers"]["x-atlas-caller"] == "service:github-monitor"
    assert not github_calls


async def test_membership_is_cached(client):
    for _ in range(3):
        assert (await client.post("/mcp", json=BODY, headers={"Authorization": f"Bearer {MEMBER}"})).status_code == 200
    assert github_calls == ["user"]


async def test_caller_cannot_forge_identity_header(client):
    await client.post("/mcp", json=BODY, headers={"Authorization": f"Bearer {MEMBER}", "X-Atlas-Caller": "service:admin"})
    assert seen_upstream[0]["headers"]["x-atlas-caller"] == "github:alice"


async def test_healthz_is_open(client):
    r = await client.get("/healthz")
    assert r.status_code == 200 and r.json() == {"status": "ok"}

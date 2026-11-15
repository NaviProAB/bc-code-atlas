# Navipro's hosted bc-code-atlas

This branch (`navipro`) is Navipro's fork of
[StefanMaron/bc-code-atlas](https://github.com/StefanMaron/bc-code-atlas) plus what is
needed to run it in Navipro's Azure subscription with sign-in. Everything Navipro added is
in this folder; the rest of the repository is upstream, unchanged.

- **Endpoint:** `https://navipro-bc-atlas.swedencentral.cloudapp.azure.com/mcp`
- **Who may use it:** members of the `NaviProAB` GitHub organization, and systems that hold
  a service key.
- **What it serves:** Microsoft's Business Central source and documentation only. No
  customer code is indexed.

## How a request gets in

```
MCP client ──HTTPS──▶ Caddy (:443, Let's Encrypt)
                         └─▶ gateway (:8790)   checks the Bearer token
                                └─▶ aggregator (:8800) ─▶ search / graph / registry / build
```

Only Caddy listens on the internet. The gateway (`gateway/gateway.py`) accepts
`Authorization: Bearer <token>` where the token is one of:

| Token | For | How it is checked |
|---|---|---|
| A GitHub token | People | GitHub says who owns the token and whether that login is a member of `NaviProAB`. The answer is cached for 10 minutes. The token is never forwarded or logged. |
| A service key | GitHub Monitor, the Evolve agent, CI | Compared with the SHA-256 hashes in `/etc/bcatlas/service-keys.json`. The keys themselves are in Key Vault. |

The log has one line per request: caller, MCP method or tool, status, duration. Query text
is not logged.

## Use it

**Claude Code** (the AL profile does this for you; by hand it is):

```bash
claude mcp add --transport http bc-code-atlas https://navipro-bc-atlas.swedencentral.cloudapp.azure.com/mcp --header "Authorization: Bearer $(gh auth token)"
```

**A service:** read its key from Key Vault and send it as the Bearer token.

```bash
az keyvault secret show --vault-name <vault> --name atlas-key-github-monitor --query value -o tsv
```

`gh auth token` must belong to an organization member and carry the `read:org` scope, which
`gh auth login` grants by default.

## Deploy

```powershell
az group create -n rg-bc-atlas -l swedencentral --subscription "Betala per användning"
az deployment group create -g rg-bc-atlas -f main.bicep `
  -p sshPublicKey="$(Get-Content ~/.ssh/bcatlas.pub)" keyVaultAdminObjectId=$(az ad signed-in-user show --query id -o tsv)
```

The VM clones this branch at first boot and runs `setup-vm.sh`, which installs everything
and starts the first index. That index runs on CPU and takes many hours; until it is done
the endpoint answers `502` to signed-in callers. Follow it with:

```powershell
az vm run-command invoke -g rg-bc-atlas -n vm-bcatlas --command-id RunShellScript `
  --scripts "journalctl -u bcatlas-firstindex -n 20 --no-pager; systemctl is-active bcatlas.target"
```

Port 22 is closed. Manage the VM with `az vm run-command` or the serial console.

## Service keys

```powershell
./New-ServiceKey.ps1 -Name github-monitor       # issue or replace
./New-ServiceKey.ps1 -Name evolve-agent -Remove # revoke
```

## Other versions and countries

The default corpus is W1 version 28 (upstream's default). Any other (country, version) is
built on request through the server's own tools and stays warm until it has been idle for a
while:

```
bcatlas_resolve_version(country="se", spec="28")   → commit_sha
bcatlas_request_version(country="se", spec="28")   → queued / in_progress / ready
bcatlas_search(query="...", country="se", version="<commit_sha>")
```

On this CPU-only VM a first build of a new country takes hours; a version close to one that
is already built is much faster.

## Keep it current

```bash
git fetch upstream && git merge upstream/master   # on the navipro branch, then push
```

Then on the VM: `git pull`, `setup-vm.sh <hostname>`, `systemctl restart bcatlas.target`.
A restart of the search backend reprocesses the corpus, which takes one to two hours on
CPU before search answers again.

## Cost and size

The VM starts as `Standard_D8s_v5` (8 cores, 32 GB), sized for the first index, and
**resizes itself** to `scaleDownTo` (default `Standard_D4s_v5`, 4 cores, 16 GB) when that
index is done:

- `first-index.sh` writes `/var/lib/bcatlas/indexed` when the index and the graph are built.
- `bcatlas-scaledown.path` sees the file and starts `scale-down.sh`, which asks Azure to
  resize the VM using the VM's own identity (Virtual Machine Contributor on this VM only).
- Azure restarts the VM; the services start again by themselves. It runs once
  (`/var/lib/bcatlas/scaled-down`).

Check it, or resize by hand:

```powershell
az vm run-command invoke -g rg-bc-atlas -n vm-bcatlas --command-id RunShellScript `
  --scripts "bash /opt/bcatlas/bc-code-atlas/deploy/navipro/scale-down.sh Standard_D4s_v5 --check"
az vm resize -g rg-bc-atlas -n vm-bcatlas --size Standard_D4s_v5
```

After the restart the search backend reprocesses the corpus before it answers, which takes
longer on four cores. If serving several countries needs more memory than 16 GB, resize up.

## Tests

```bash
cd gateway && uv run pytest
```

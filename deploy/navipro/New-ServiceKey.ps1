<#
.SYNOPSIS
  Issue (or replace) a service key for a system that has no personal GitHub login,
  for example GitHub Monitor or the Evolve agent.

.DESCRIPTION
  - Generates a random key on this machine.
  - Stores the key in Key Vault as secret "atlas-key-<name>". It is not printed.
  - Sends only the key's SHA-256 hash to the VM (/etc/bcatlas/service-keys.json).
    The gateway picks the change up by itself; nothing restarts.

  The caller then sends:  Authorization: Bearer <the key from Key Vault>

.EXAMPLE
  ./New-ServiceKey.ps1 -Name github-monitor
.EXAMPLE
  ./New-ServiceKey.ps1 -Name evolve-agent -Remove      # revoke
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9][a-z0-9-]{1,40}$')] [string] $Name,
    [string] $ResourceGroup = 'rg-bc-atlas',
    [string] $VmName = 'vm-bcatlas',
    [string] $Subscription = '',
    [switch] $Remove
)

$ErrorActionPreference = 'Stop'
$sub = @(); if ($Subscription) { $sub = @('--subscription', $Subscription) }

$kv = az keyvault list -g $ResourceGroup @sub --query '[0].name' -o tsv
if (-not $kv) { throw "No Key Vault found in $ResourceGroup." }
$secretName = "atlas-key-$Name"

if ($Remove) {
    $py = "import json,sys; p='/etc/bcatlas/service-keys.json'; d=json.load(open(p)); d['services'].pop('$Name', None); json.dump(d, open(p,'w'), indent=1)"
} else {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $key = 'bca_' + ([Convert]::ToBase64String($bytes) -replace '[+/=]', '')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)) | ForEach-Object { $_.ToString('x2') })

    # Through a file, so the key never appears on a command line or in shell history.
    $tmp = New-TemporaryFile
    try {
        [IO.File]::WriteAllText($tmp, $key)
        az keyvault secret set --vault-name $kv --name $secretName --file $tmp --encoding utf-8 @sub --query id -o tsv | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not store the key in Key Vault.' }
    } finally { Remove-Item $tmp -Force }
    $key = $null
    $py = "import json,sys; p='/etc/bcatlas/service-keys.json'; d=json.load(open(p)); d['services']['$Name']={'sha256':'$hash'}; json.dump(d, open(p,'w'), indent=1)"
}

az vm run-command invoke -g $ResourceGroup -n $VmName @sub --command-id RunShellScript `
    --scripts "python3 -c `"$py`" && chown root:bcatlas /etc/bcatlas/service-keys.json && chmod 640 /etc/bcatlas/service-keys.json && python3 -c `"import json; print(sorted(json.load(open('/etc/bcatlas/service-keys.json'))['services']))`"" `
    --query 'value[0].message' -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Could not update the key list on the VM.' }

if ($Remove) {
    az keyvault secret delete --vault-name $kv --name $secretName @sub --query id -o tsv 2>$null | Out-Null
    Write-Host "Revoked service key '$Name'."
} else {
    Write-Host "Service key '$Name' issued. Read it with:"
    Write-Host "  az keyvault secret show --vault-name $kv --name $secretName --query value -o tsv"
}

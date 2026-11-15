#!/usr/bin/env bash
# Resizes this VM to a smaller size once the first index is done. The first index
# wants cores; serving does not, and the VM runs around the clock.
#
# Run as root by bcatlas-scaledown.service, which bcatlas-scaledown.path starts
# when /var/lib/bcatlas/indexed appears. The VM calls Azure with its own managed
# identity, which main.bicep allows to change this one VM and nothing else.
# Azure restarts the VM to apply the size; the services come back by themselves.
#
#   scale-down.sh <size>            resize (once: leaves /var/lib/bcatlas/scaled-down)
#   scale-down.sh <size> --check    only show the current size and whether the call is allowed
set -euo pipefail

TARGET="${1:?usage: scale-down.sh <vm-size> [--check]}"
CHECK="${2:-}"
MARKER=/var/lib/bcatlas/scaled-down
API=2024-07-01
IMDS=http://169.254.169.254/metadata

meta() { curl -sf -H Metadata:true "$IMDS/instance/compute/$1?api-version=2021-02-01&format=text"; }
SUB=$(meta subscriptionId); RG=$(meta resourceGroupName); NAME=$(meta name)
TOKEN=$(curl -sf -H Metadata:true "$IMDS/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
URL="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Compute/virtualMachines/$NAME?api-version=$API"

CURRENT=$(curl -sf -H "Authorization: Bearer $TOKEN" "$URL" | python3 -c 'import json,sys; print(json.load(sys.stdin)["properties"]["hardwareProfile"]["vmSize"])')
echo "$(date -Is) $NAME is $CURRENT; target $TARGET"

if [ "$CHECK" = "--check" ]; then
  echo "check only: the VM can read its own definition, so the identity and role are in place"
  exit 0
fi
if [ "$CURRENT" = "$TARGET" ]; then
  date -Is > "$MARKER"
  echo "already $TARGET; nothing to do"
  exit 0
fi

# Write the marker first: the resize restarts the VM, possibly before this script
# gets to its next line, and it must not run again after the reboot.
date -Is > "$MARKER"
STATUS=$(curl -s -o /tmp/scale-down.json -w '%{http_code}' -X PATCH "$URL" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"properties\":{\"hardwareProfile\":{\"vmSize\":\"$TARGET\"}}}")
if [ "$STATUS" -ge 200 ] && [ "$STATUS" -lt 300 ]; then
  echo "$(date -Is) resize to $TARGET accepted (HTTP $STATUS); Azure will restart the VM"
else
  rm -f "$MARKER"
  echo "$(date -Is) resize refused (HTTP $STATUS): $(head -c 400 /tmp/scale-down.json)" >&2
  exit 1
fi

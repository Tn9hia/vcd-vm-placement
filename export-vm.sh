#!/bin/bash

# ── Credentials ───────────────────────────────────────────────────────────────
[ -f ".env" ] && source .env

if [ -z "${VCLOUD_USER:-}" ] || [ -z "${VCLOUD_PASS:-}" ] || [ -z "${BASE_URL:-}" ]; then
  echo "ERROR: VCLOUD_USER, VCLOUD_PASS, and BASE_URL must be set (env vars or .env file)"
  exit 1
fi

tempDir="./export-vm"

# ── Auth ──────────────────────────────────────────────────────────────────────
credentials=$(printf '%s:%s' "$VCLOUD_USER" "$VCLOUD_PASS" | base64)
token=$(curl --request POST \
  --url "$BASE_URL/api/sessions" \
  --header 'accept: application/*+json;version=37.0' \
  --header "authorization: Basic $credentials" -I -s \
  | grep -i '^x-vcloud-authorization:' | awk '{print $2}' | tr -d '\r')

if [ -z "$token" ]; then
  echo "ERROR: Failed to get authentication token. Check credentials."
  exit 1
fi

mkdir -p "$tempDir"

# ── Functions ─────────────────────────────────────────────────────────────────
getListVm() {
  local orgId=$1
  local orgName=$2

  curl --request GET \
    --url "$BASE_URL/api/query?type=vm&page=1&pageSize=100" \
    --header 'accept: application/*+json;version=37.0' \
    --header "x-vcloud-authorization: $token" \
    --header "x-vmware-vcloud-tenant-context: $orgId" -s | \
    jq --arg orgName "$orgName" '[.record[] | select(.vdcName != "Catalogs02" and .vdcName != "Catalogs" and .vdcName != "VTDC-TKG-CSE") | {
      "vm-name": .name,
      "vmId": (.href | split("/") | last | split("-") | .[1:] | join("-")),
      "vmSizingPolicyId": .vmSizingPolicyId,
      "vmPlacementPolicyId": .vmPlacementPolicyId,
      "orgName": $orgName,
      "vdcName": .vdcName,
      "status": .status
    }]'
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo "Org Name,VDC Name,VM Name,VM Placement,VM Sizing,Power" > all-vm-cloud2.csv

while read -r line; do
  orgId=$(echo "$line" | awk '{print $1}')
  orgName=$(echo "$line" | awk '{print $2}' | xargs)

  echo "Processing $orgName..." >&2

  vms=$(getListVm "$orgId" "$orgName")
  vmCount=$(echo "$vms" | jq 'length')

  if [[ "$vmCount" -eq 0 ]]; then
    echo "$orgName,,,,," >> all-vm-cloud2.csv
  else
    echo "$vms" | jq -r '.[] | [
      .orgName // "",
      .vdcName // "",
      ."vm-name" // "",
      .vmPlacementPolicyId // "",
      .vmSizingPolicyId // "",
      .status // ""
    ] | @csv' >> all-vm-cloud2.csv
  fi

done < org-id-input.txt

echo "Done! Check all-vm-cloud2.csv"

#!/bin/bash

# ── Credentials ───────────────────────────────────────────────────────────────
[ -f ".env" ] && source .env

if [ -z "${VCLOUD_USER:-}" ] || [ -z "${VCLOUD_PASS:-}" ] || [ -z "${BASE_URL:-}" ]; then
  echo "ERROR: VCLOUD_USER, VCLOUD_PASS, and BASE_URL must be set (env vars or .env file)"
  exit 1
fi

tempDir="./export-vdc-placement"

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
getVdcComputePolicies() {
  local orgId=$1
  local vdcId=$2
  local vdcName=$3

  curl --request GET \
    --url "$BASE_URL/api/admin/vdc/$vdcId/computePolicies" \
    --header 'accept: application/*+json;version=37.0' \
    --header "x-vcloud-authorization: $token" \
    --header "x-vmware-vcloud-tenant-context: $orgId" -s | \
    jq --arg vdcName "$vdcName" '[{
      vdcName: $vdcName,
      PlacementReference: [.vdcComputePolicyReference[].name]
    }]'
}

getListVdc() {
  local orgId=$1

  curl --request GET \
    --url "$BASE_URL/api/query?type=orgVdc&page=1&pageSize=100" \
    --header 'accept: application/*+json;version=37.0' \
    --header "x-vcloud-authorization: $token" \
    --header "x-vmware-vcloud-tenant-context: $orgId" -s | \
    jq '[.record[] | {"name": .name, "vdcId": (.href | split("/") | last)}]'
}

# ── Main ──────────────────────────────────────────────────────────────────────
while read -r line; do
  orgId=$(echo "$line" | awk '{print $1}')
  orgName=$(echo "$line" | awk '{print $2}')
  vdcs=$(getListVdc "$orgId")

  # FIX: iterate each VDC individually with '.[]'
  echo "$vdcs" | jq -c '.[]' | while read -r vdc; do
    vdcName=$(echo "$vdc" | jq -r '.name')
    vdcId=$(echo "$vdc" | jq -r '.vdcId')
    vdcComputePolicies=$(getVdcComputePolicies "$orgId" "$vdcId" "$vdcName")
    echo "$vdcComputePolicies" > "$tempDir/$vdcName-vdc-policy.json"
    echo "Exported $vdcName-vdc-policy.json"
  done

done < org-id-input.txt

cat "$tempDir"/*vdc-policy.json | jq -s 'add' > ./merged-policy.json

echo "Completed export all vdc compute policies"

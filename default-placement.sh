#!/bin/bash

# ── Credentials ───────────────────────────────────────────────────────────────
# Set env vars or create a .env file (see .env.example)
[ -f ".env" ] && source .env

if [ -z "${VCLOUD_USER:-}" ] || [ -z "${VCLOUD_PASS:-}" ] || [ -z "${BASE_URL:-}" ]; then
  echo "ERROR: VCLOUD_USER, VCLOUD_PASS, and BASE_URL must be set (env vars or .env file)"
  exit 1
fi

tempDir="./default-placement"

# ── Auth ──────────────────────────────────────────────────────────────────────
credentials=$(printf '%s:%s' "$VCLOUD_USER" "$VCLOUD_PASS" | base64)
token=$(curl -s --request POST \
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
getDefaultComputePolicy() {
  local vdcId=$1
  curl -s --request GET \
    --url "$BASE_URL/api/admin/vdc/$vdcId" \
    --header 'accept: application/*+json;version=37.0' \
    --header "x-vcloud-authorization: $token" \
    | jq '[.defaultComputePolicy | {"id": (.id | split(":") | last), "name": .name}]'
}

# ── Main ──────────────────────────────────────────────────────────────────────
while read -r line; do
  vdcId=$(echo "$line" | awk '{print $1}')
  vdcName=$(echo "$line" | awk '{print $2}')

  defaultComputePolicy=$(getDefaultComputePolicy "$vdcId")
  value=$(echo "$defaultComputePolicy" | jq -r '.[0].name')
  echo "$vdcName $value"

done < org-id.txt

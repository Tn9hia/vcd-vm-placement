#!/bin/bash

# ── Config ────────────────────────────────────────────────────────────────────
TEMP_DIR="./temp"
HOSTS_FILE="./hosts-vcenter.txt"
ORG_INPUT="./org-id-input.txt"
DRY_RUN=false

for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# ── Credentials ───────────────────────────────────────────────────────────────
# Set env vars or create a .env file (see .env.example)
[ -f ".env" ] && source .env

if [ -z "${VCLOUD_USER:-}" ] || [ -z "${VCLOUD_PASS:-}" ] || [ -z "${BASE_URL:-}" ]; then
  echo "ERROR: VCLOUD_USER, VCLOUD_PASS, and BASE_URL must be set (env vars or .env file)"
  exit 1
fi

# ── Logging ───────────────────────────────────────────────────────────────────
mkdir -p "$TEMP_DIR"
LOG_FILE="$TEMP_DIR/run-$(date '+%Y%m%d-%H%M%S').log"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

# ── Auth ──────────────────────────────────────────────────────────────────────
credentials=$(printf '%s:%s' "$VCLOUD_USER" "$VCLOUD_PASS" | base64)
token=$(curl --request POST \
  --url "$BASE_URL/api/sessions" \
  --header 'accept: application/*+json;version=37.0' \
  --header "authorization: Basic $credentials" -I -s \
  | grep -i '^x-vcloud-authorization:' | awk '{print $2}' | tr -d '\r')

if [ -z "$token" ]; then
  log "ERROR: Failed to get authentication token. Check credentials."
  exit 1
fi

log "Authentication successful"
[ "$DRY_RUN" = true ] && log "[DRY RUN] No changes will be applied"

# ── Functions ─────────────────────────────────────────────────────────────────

getListVdc() {
  local orgId=$1
  curl --request GET \
    --url "$BASE_URL/api/query?type=orgVdc&page=1&pageSize=100" \
    --header 'accept: application/*+json;version=37.0' \
    --header "x-vcloud-authorization: $token" \
    --header "x-vmware-vcloud-tenant-context: $orgId" -s | \
    jq '[.record[] | {"name": .name, "vdcId": (.href | split("/") | last)}]'
}

# Fetch all VMs for an org in one pass (called once per org, not per VDC)
getListVm() {
  local orgId=$1

  local listVm
  listVm=$(curl --request GET \
    --url "$BASE_URL/api/query?type=vm&page=1&pageSize=100" \
    --header 'accept: application/*+json;version=37.0' \
    --header "x-vcloud-authorization: $token" \
    --header "x-vmware-vcloud-tenant-context: $orgId" -s | \
    jq '[.record[] | select(.vdcName != "Catalogs02" and .vdcName != "Catalogs" and .vdcName != "VTDC-TKG-CSE") | {
      "vm-name": .name,
      "vmId": (.href | split("/") | last | split("-") | .[1:] | join("-")),
      "vmSizingPolicyId": .vmSizingPolicyId,
      "vmPlacementPolicyId": .vmPlacementPolicyId,
      "vdcName": .vdcName
    }]')

  # Enrich each VM with its current host (one API call per VM)
  echo "$listVm" | jq -c '.[]' | while read -r vm; do
    local vmId
    vmId=$(echo "$vm" | jq -r '.vmId')
    local vmHost
    vmHost=$(curl --request GET \
      --url "$BASE_URL/api/query?type=adminVM&page=1&pageSize=100&filter=id%3D%3D${vmId}" \
      --header 'accept: application/*+json;version=37.0' \
      --header "x-vcloud-authorization: $token" \
      --header "x-vmware-vcloud-tenant-context: $orgId" -s \
      | jq -r '.record[0].hostName // empty')
    echo "$vm" | jq --arg host "$vmHost" '. + {host: $host}'
  done | jq -s '.'
}

getOrgComputePolicies() {
  local orgId=$1
  local vdcId=$2
  curl --request GET \
    --url "$BASE_URL/api/admin/vdc/$vdcId/computePolicies" \
    --header 'accept: application/*+json;version=37.0' \
    --header "x-vcloud-authorization: $token" \
    --header "x-vmware-vcloud-tenant-context: $orgId" -s | \
    jq -c '[.vdcComputePolicyReference[] | {"vdcComputePolicyName": .name, "vdcComputePolicyId": (.id | split(":") | last)}]'
}

updateOrgComputePolicies() {
  local orgId=$1
  local vdcId=$2
  local mergedFile=$3

  local json_body
  json_body=$(jq -Rn '
    {
      vdcComputePolicyReference: (
        [inputs | select(length > 0)]
        | map({ id: ("urn:vcloud:vdcComputePolicy:" + .) })
      )
    }
  ' < "$mergedFile")

  curl --request PUT \
    --url "$BASE_URL/api/admin/vdc/$vdcId/computePolicies" \
    --header 'accept: application/*+json;version=37.0' \
    --header 'content-type: application/vnd.vmware.vcloud.vdcComputePolicyReferences+json' \
    --header "x-vcloud-authorization: $token" \
    --header "x-vmware-vcloud-tenant-context: $orgId" \
    --data "$json_body" -s -o /dev/null
}

updateVmPlacementPolicy() {
  local orgId=$1
  local vmId=$2
  local vmName=$3
  local placementPolicyId=$4

  local xml
  xml=$(cat <<EOF
<root:Vm xmlns:root="http://www.vmware.com/vcloud/v1.5"
         xmlns:ns8="http://schemas.dmtf.org/ovf/envelope/1"
         xmlns:ns9="http://www.vmware.com/schema/ovf"
         name="$vmName">
  <root:ComputePolicy>
    <root:VmPlacementPolicy href="urn:vcloud:vdcComputePolicy:$placementPolicyId" />
    <root:VmSizingPolicy href="" />
  </root:ComputePolicy>
</root:Vm>
EOF
)
  curl -s -o /dev/null --request POST \
    --url "$BASE_URL/api/vApp/vm-$vmId/action/reconfigureVm" \
    --header 'accept: application/*+json;version=37.0' \
    --header 'content-type: application/*+xml;charset=UTF-8' \
    --header "x-vcloud-authorization: $token" \
    --header "x-vmware-vcloud-tenant-context: $orgId" \
    --data "$xml"
}

# ── Main ──────────────────────────────────────────────────────────────────────

while read -r line; do
  orgId=$(echo "$line" | awk '{print $1}')
  orgName=$(echo "$line" | awk '{print $2}')

  log "Processing org: $orgName ($orgId)"

  vdcs=$(getListVdc "$orgId")

  # FIX: fetch all VMs once per org instead of once per VDC
  log "  Fetching VM list for org $orgName..."
  allVms=$(getListVm "$orgId")

  # FIX: iterate each VDC individually with '.[]'
  echo "$vdcs" | jq -c '.[]' | while read -r vdc; do
    # FIX: extract single object fields with '.name' not '.[].name'
    vdcName=$(echo "$vdc" | jq -r '.name')
    vdcId=$(echo "$vdc" | jq -r '.vdcId')

    log "  VDC: $vdcName ($vdcId)"

    # Filter VMs for this specific VDC
    vms=$(echo "$allVms" | jq --arg vdc "$vdcName" '[.[] | select(.vdcName == $vdc)]')

    orgComputePolicies=$(getOrgComputePolicies "$orgId" "$vdcId")

    # FIX: temp files scoped per VDC to avoid cross-VDC pollution
    orgPolicyFile="$TEMP_DIR/$orgName-$vdcId-org.txt"
    vmPolicyFile="$TEMP_DIR/$orgName-$vdcId-vm.txt"
    mergedFile="$TEMP_DIR/$orgName-$vdcId-merged.txt"

    echo "$orgComputePolicies" | jq -r '.[].vdcComputePolicyId' | sort | uniq > "$orgPolicyFile"

    # FIX: write (not append) to vmPolicyFile on each VDC iteration
    echo "$vms" | jq -r '.[].host' | while read -r ip; do
      awk -v ip="$ip" '$1 == ip {print $3}' "$HOSTS_FILE"
    done | sort | uniq > "$vmPolicyFile"

    sort "$orgPolicyFile" "$vmPolicyFile" | uniq > "$mergedFile"

    if diff -q "$orgPolicyFile" "$mergedFile" > /dev/null 2>&1; then
      log "  Skip: VDC $vdcName already has all required compute policies"
    else
      if [ "$DRY_RUN" = true ]; then
        log "  [DRY RUN] Would update compute policies for VDC $vdcName"
      else
        updateOrgComputePolicies "$orgId" "$vdcId" "$mergedFile"
        log "  Updated compute policies for VDC $vdcName"
      fi
    fi

    echo "$vms" | jq -c '.[]' | while read -r vm; do
      vmId=$(echo "$vm" | jq -r '.vmId')
      vmName=$(echo "$vm" | jq -r '."vm-name"')
      host=$(echo "$vm" | jq -r '.host')
      hostPolicyId=$(awk -v ip="$host" '$1 == ip {print $3}' "$HOSTS_FILE")

      if [ -z "$hostPolicyId" ]; then
        log "  WARN: No policy mapping for host $host (vm: $vmName) — skipping"
        continue
      fi

      vmPlacementPolicy=$(echo "$vm" | jq -r '.vmPlacementPolicyId')
      vmSizingPolicy=$(echo "$vm" | jq -r '.vmSizingPolicyId')

      if [ "$vmPlacementPolicy" = "$hostPolicyId" ] && [ "$vmSizingPolicy" = "null" ]; then
        log "  Skip: $vmName (policy already matched)"
        continue
      fi

      if [ "$DRY_RUN" = true ]; then
        log "  [DRY RUN] Would update placement policy: $vmName → $hostPolicyId"
      else
        updateVmPlacementPolicy "$orgId" "$vmId" "$vmName" "$hostPolicyId"
        log "  Updated placement policy: $vmName → $hostPolicyId"
      fi
    done

    # FIX: clean up VDC-scoped temp files
    rm -f "$orgPolicyFile" "$vmPolicyFile" "$mergedFile"

    sleep 2
    log "  Done VDC $vdcName, waiting 2s before next VDC"
  done

done < "$ORG_INPUT"

log "Finished. Full log: $LOG_FILE"

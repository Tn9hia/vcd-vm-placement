#! /bin/bash

# Declare basic information
baseURL='https://cloud2.viettelidc.com.vn'
tempDir="./export-vm"
# Create authen token

token=$(curl --request POST \
  --url https://cloud2.viettelidc.com.vn/api/sessions \
  --header 'accept: application/*+json;version=37.0' \
  --header 'authorization: Basic bmdoaWFsdEBzeXN0ZW06TGUwOTAzOTA4Mjg1QA==' -I -s |grep authorization |awk '{print $2}')

# Create a temp folder to store running data
mkdir -p "$tempDir"

getListVm() {
	local orgId=$1
	local orgName=$2
	
	listVm=$(curl --request GET \
	--url "$baseURL/api/query?type=vm&page=1&pageSize=100" \
	--header 'accept: application/*+json;version=37.0' \
	--header "x-vcloud-authorization: $token" \
	--header "x-vmware-vcloud-tenant-context: $orgId" -s | \
		jq --arg orgName "$orgName" '[.record[] | select(.vdcName != "Catalogs02" and .vdcName != "Catalogs" and .vdcName != "VTDC-TKG-CSE") | { "vm-name": .name, "vmId": (.href | split("/") | last | split("-") | .[1:] | join("-")), "vmSizingPolicyId": .vmSizingPolicyId, "vmPlacementPolicyId": .vmPlacementPolicyId, "orgName": $orgName, "vdcName": .vdcName, "status": .status}]')
	
	echo $listVm
}

# Header
echo "Org Name,VDC Name,VM Name,VM Placement,VM Sizing,Power" > all-vm-cloud2.csv

while read -r line; do 
	orgId=$(echo $line | awk '{print $1}')
	orgName=$(echo $line | awk '{print $2}' | xargs)
	
	echo "Processing $orgName..." >&2
	
	# Get VM information
	vms=$(getListVm $orgId $orgName)
	
	# Check if empty
	vmCount=$(echo "$vms" | jq 'length')
	
	if [[ "$vmCount" -eq 0 ]]; then
		# Org không có VM → ghi placeholder row với các field trống
		echo "$orgName,,,,," >> all-vm-cloud2.csv
	else
		# Có VM → convert bình thường
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
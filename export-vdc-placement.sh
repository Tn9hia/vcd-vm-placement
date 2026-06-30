#! /bin/bash

# Declare basic information
baseURL='https://cloud2.viettelidc.com.vn'
tempDir="./export-vdc-placement"
# Create authen token

token=$(curl --request POST \
  --url https://cloud2.viettelidc.com.vn/api/sessions \
  --header 'accept: application/*+json;version=37.0' \
  --header 'authorization: Basic bmdoaWFsdEBzeXN0ZW06TGUwOTAzOTA4Mjg1QA==' -I -s |grep authorization |awk '{print $2}')

# Create a temp folder to store running data
mkdir -p "$tempDir"

# Get org compute policies
getVdcComputePolicies() {
	local orgId=$1
	local vdcId=$2
	local vdcName=$3

	# Get org compute policies
	orgComputePolicies=$(curl --request GET \
	--url "$baseURL/api/admin/vdc/$vdcId/computePolicies" \
	--header 'accept: application/*+json;version=37.0' \
	--header "x-vcloud-authorization: $token" \
	--header "x-vmware-vcloud-tenant-context: $orgId" -s  | \
		jq --arg vdcName "$vdcName" '
		[
		{
			vdcName: $vdcName,
			PlacementReference: [.vdcComputePolicyReference[].name]
		}
		]')
	
	echo $orgComputePolicies
}

# Get list vdc
getListVdc() {
	local orgs=$1

	listOrgs=$(curl --request GET \
	--url "$baseURL/api/query?type=orgVdc&page=1&pageSize=100" \
	--header 'accept: application/*+json;version=37.0' \
	--header "x-vcloud-authorization: $token" \
	--header "x-vmware-vcloud-tenant-context: $orgs" -s | \
	  jq '[.record[] | {"name": .name, "vdcId": (.href | split("/") | last)}]')

	echo $listOrgs
}

while read -r line; do 
	orgId=$(echo $line | awk '{print $1}')
	orgName=$(echo $line | awk '{print $2}')
	vdcs=$(getListVdc $orgId)

	# For each vdc, get vdc compute policies and save to file
	echo $vdcs | jq -c '.' | while read -r vdc; do
		vdcName=$(echo "$vdc" | jq -r '.[].name')
		vdcId=$(echo "$vdc" | jq -r '.[].vdcId')
		vdcComputePolicies=$(getVdcComputePolicies $orgId $vdcId $vdcName)
		echo $vdcComputePolicies > "$tempDir/$vdcName-vdc-policy.json"
		echo "Exported $vdcName-vdc-policy.json"
	done

done < org-id-input.txt

# Merge org compute policies
cat $tempDir/*vdc-policy.json | jq -s 'add' > ./merged-policy.json

echo "Completed export all vdc compute policies"
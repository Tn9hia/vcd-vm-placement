#! /bin/bash

# Declare basic information
baseURL='https://cloud2.viettelidc.com.vn'
tempDir="./default-placement"
# Create authen token

token=$(curl -s --request POST \
  --url https://cloud2.viettelidc.com.vn/api/sessions \
  --header 'accept: application/*+json;version=37.0' \
  --header 'authorization: Basic bmdoaWFsdEBzeXN0ZW06TGUwOTAzOTA4Mjg1QA==' -I -s |grep authorization |awk '{print $2}')

# Create a temp folder to store running data
mkdir -p "$tempDir"

getDefaultComputePolicy() {
	local vdcId=$1
	result=$(curl -s --request GET \
	--url "$baseURL/api/admin/vdc/$vdcId" \
	--header 'accept: application/*+json;version=37.0' \
	--header "x-vcloud-authorization: $token" | jq '[.defaultComputePolicy | {"id": (.id | split(":") | last), "name": .name}]')
	echo $result
}

# Get vdc from file
while read -r line; do 
	vdcId=$(echo $line | awk '{print $1}')
	vdcName=$(echo $line | awk '{print $2}')

	# Get default compute policy
	defaultComputePolicy=$(getDefaultComputePolicy $vdcId)
	value=$(echo $defaultComputePolicy | jq -r '.[0].name')
	echo "$vdcName $value"

done <org-id.txt
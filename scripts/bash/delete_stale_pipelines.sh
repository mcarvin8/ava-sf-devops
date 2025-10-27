#!/bin/bash
################################################################################
# Script: delete_stale_pipelines.sh
# Description: Deletes old GitLab CI/CD pipelines that are older than 6 months
#              to reduce clutter and storage usage. Uses GitLab REST API to 
#              fetch and delete pipelines in batches.
# Usage: Called from scheduled CI/CD pipeline
# Dependencies: curl, jq
# Environment Variables Required:
#   - OWNER_PAT_VALUE: GitLab personal access token with API access
#   - CI_SERVER_HOST, CI_PROJECT_ID
################################################################################
page=1
per_page=100
updated_before=$(date -d "6 months ago" +%Y-%m-%d)
json_file="pipelines.json"
txt_file="pipeline-rest-api-ids.txt"

while true; do
    response=$(curl --header "PRIVATE-TOKEN: ${OWNER_PAT_VALUE}" "https://${CI_SERVER_HOST}/api/v4/projects/${CI_PROJECT_ID}/pipelines?updated_before=${updated_before}T00:00:00Z&page=$page&per_page=$per_page")
    
    # Check if the response is an empty JSON array "[]"
    if [ "$response" == "[]" ]; then
        break
    fi

    echo "$response" | jq . >> $json_file
    ((page++))
done

# format file to contain required URL for GitLab REST API
cat "$json_file" | jq -r '.[] | .id' >> $txt_file
sed -i "s/^/https:\/\/${CI_SERVER_HOST}\/api\/v4\/projects\/${CI_PROJECT_ID}\/pipelines\//" $txt_file

while read b; do
    echo "Attemping to delete pipeline $b"
    curl --request "DELETE" "$b?private_token=${OWNER_PAT_VALUE}"
done <$txt_file

rm $txt_file
rm $json_file

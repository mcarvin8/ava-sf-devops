#!/bin/bash
curl --request DELETE --header "PRIVATE-TOKEN: $PROJECT_TOKEN" "https://${CI_SERVER_HOST}/api/v4/projects/${CI_PROJECT_ID}/repository/merged_branches"

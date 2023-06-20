#!bin/bash
# Script which uses the GitLab API to push new branches, merge requests, and commits to a Salesforce repo
# Ensure the project access token (PROJECT_TOKEN) and personal access token (PERSONAL_TOKEN) are active
# This script can be used in any SFDX repository as long as unique tokens are stored as CI/CD variables
# version variable is set by "api_version.py"
source_branch="${CI_COMMIT_REF_NAME}"
new_branch="update_${source_branch}_to_api_version_${version}"
input_file="sfdx-project.json"
# Update sfdx-project.json file on a new branch created from the source branch using the personal token
# Commits cannot be made using the project access token
# Reference - https://docs.gitlab.com/ee/api/commits.html#create-a-commit-with-multiple-files-and-actions
curl --request POST \
     --form "branch=${branch_name}" \
     --form "start_branch=${source_branch}" \
     --form "commit_message=Update source API version to ${version}" \
     --form "actions[][action]=update" \
     --form "actions[][file_path]=${input_file}" \
     --form "actions[][content]=<${input_file}" \
     --form "actions[][action]=chmod" \
     --form "actions[][file_path]=${input_file}" \
     --form "actions[][execute_filemode]=true" \
     --header "PRIVATE-TOKEN: ${PERSONAL_TOKEN}" \
     "https://${CI_SERVER_HOST}/api/v4/projects/${CI_PROJECT_ID}/repository/commits"
# Create merge request into the source branch with project access token
# Reference - https://docs.gitlab.com/ee/api/merge_requests.html#create-mr
curl --request POST \
     --data "source_branch=${new_branch}&target_branch=${source_branch}&title=Change ${source_branch} Source API Version to ${version}" \
     --header "PRIVATE-TOKEN: ${PROJECT_TOKEN}" \
     "https://${CI_SERVER_HOST}/api/v4/projects/${CI_PROJECT_ID}/merge_requests"

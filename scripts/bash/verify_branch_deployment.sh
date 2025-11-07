#!/bin/bash
################################################################################
# Script: verify_branch_deployment.sh
# Description: Verifies if the source branch in a merge request (open against
#              the default branch) has been successfully merged & deployed into
#              fullqa and develop branches. Posts a comment to the MR with the
#              verification results.
# Usage: Called automatically from GitLab CI/CD pipeline
# Dependencies: git, curl, jq (optional, for JSON parsing)
# Environment Variables Required:
#   - CI_MERGE_REQUEST_IID: Merge request IID
#   - CI_MERGE_REQUEST_SOURCE_BRANCH_NAME: Source branch name
#   - CI_MERGE_REQUEST_TARGET_BRANCH_NAME: Target branch name (should be default)
#   - CI_PROJECT_ID: GitLab project ID
#   - CI_SERVER_HOST: GitLab server host
#   - CI_PROJECT_PATH: Project path (e.g., group/project)
#   - MAINTAINER_PAT_VALUE: Project access token for API authentication
#   - CI_DEFAULT_BRANCH: Default branch name (e.g., main, master)
################################################################################
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check if a variable is set
check_required_var() {
    local var_name=$1
    if [[ -z "${!var_name:-}" ]]; then
        print_status "$RED" "Error: Required environment variable $var_name is not set"
        exit 1
    fi
}

# Validate required environment variables
print_status "$YELLOW" "Validating required environment variables..."
check_required_var "CI_MERGE_REQUEST_IID"
check_required_var "CI_MERGE_REQUEST_SOURCE_BRANCH_NAME"
check_required_var "CI_MERGE_REQUEST_TARGET_BRANCH_NAME"
check_required_var "CI_PROJECT_ID"
check_required_var "CI_SERVER_HOST"
check_required_var "CI_PROJECT_PATH"
check_required_var "MAINTAINER_PAT_VALUE"
check_required_var "CI_DEFAULT_BRANCH"

# Verify this is a merge request against the default branch
if [[ "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" != "$CI_DEFAULT_BRANCH" ]]; then
    print_status "$YELLOW" "Skipping verification: MR is not targeting the default branch ($CI_DEFAULT_BRANCH)"
    exit 0
fi

print_status "$GREEN" "Starting branch deployment verification..."
print_status "$YELLOW" "Source branch: $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME"
print_status "$YELLOW" "Target branch: $CI_MERGE_REQUEST_TARGET_BRANCH_NAME"
print_status "$YELLOW" "Merge Request IID: $CI_MERGE_REQUEST_IID"

# Fetch all branches to ensure we have the latest information
print_status "$YELLOW" "Fetching all branches..."
git fetch --all --quiet

# Get the latest commit SHA from the source branch
SOURCE_BRANCH_SHA=$(git rev-parse "origin/$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" 2>/dev/null || echo "")
if [[ -z "$SOURCE_BRANCH_SHA" ]]; then
    print_status "$RED" "Error: Could not find source branch origin/$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME"
    exit 1
fi

print_status "$YELLOW" "Source branch SHA: $SOURCE_BRANCH_SHA"

# Check if source branch commits exist in fullqa and develop branches
check_branch_merged() {
    local target_branch=$1
    local source_sha=$2
    local branch_exists=false
    local is_merged=false
    local merge_commit_sha=""
    
    # Check if branch exists
    if git show-ref --verify --quiet "refs/remotes/origin/$target_branch"; then
        branch_exists=true
        # Check if the source commit exists in the target branch
        if git merge-base --is-ancestor "$source_sha" "origin/$target_branch" 2>/dev/null; then
            is_merged=true
            # Find the merge commit that first introduced the source SHA
            # We need to find the actual merge commit that contains the source SHA
            # First try to find merge commits, then fall back to any commit that contains the source SHA
            merge_commit_sha=$(git log --format="%H" --merges "origin/$target_branch" --ancestry-path "$source_sha" 2>/dev/null | tail -1 || \
                git log --format="%H" "origin/$target_branch" --ancestry-path "$source_sha" 2>/dev/null | tail -1 || \
                git rev-parse "origin/$target_branch" 2>/dev/null || echo "")
        fi
    fi
    
    echo "$branch_exists|$is_merged|$merge_commit_sha"
}

# Function to check deployment job status via GitLab API
check_deployment_job_status() {
    local commit_sha=$1
    local job_name=$2
    local access_token=$3
    local project_id=$4
    local server_host=$5
    
    if [[ -z "$commit_sha" ]]; then
        echo "unknown"
        return
    fi
    
    # Remove trailing slash from server host
    local server_host_clean=$(echo "$server_host" | sed 's|/$||')
    local api_url="https://${server_host_clean}/api/v4/projects/${project_id}/pipelines"
    
    # Get pipelines for this commit SHA
    local pipelines_response
    pipelines_response=$(curl -s -w "\n%{http_code}" \
        -H "PRIVATE-TOKEN: ${access_token}" \
        "${api_url}?sha=${commit_sha}&per_page=10" 2>/dev/null)
    
    local pipelines_body=$(echo "$pipelines_response" | sed '$d')
    local pipelines_status=$(echo "$pipelines_response" | tail -n1)
    
    if [[ "$pipelines_status" -lt 200 || "$pipelines_status" -ge 300 ]]; then
        echo "api_error"
        return
    fi
    
    # Find the most recent pipeline that has the deploy job
    if command -v jq &> /dev/null; then
        local pipeline_count
        pipeline_count=$(echo "$pipelines_body" | jq 'length' 2>/dev/null || echo "0")
        
        if [[ "$pipeline_count" -eq 0 ]]; then
            echo "no_pipeline"
            return
        fi
        
        # Check each pipeline (up to 10) to find one with the deploy job
        local pipeline_index=0
        local job_status=""
        while [[ $pipeline_index -lt $pipeline_count && $pipeline_index -lt 10 ]]; do
            local pipeline_id
            pipeline_id=$(echo "$pipelines_body" | jq -r ".[$pipeline_index].id // empty" 2>/dev/null)
            
            if [[ -z "$pipeline_id" ]]; then
                ((pipeline_index++))
                continue
            fi
            
            # Get jobs for this pipeline
            local jobs_url="https://${server_host_clean}/api/v4/projects/${project_id}/pipelines/${pipeline_id}/jobs"
            local jobs_response
            jobs_response=$(curl -s -w "\n%{http_code}" \
                -H "PRIVATE-TOKEN: ${access_token}" \
                "${jobs_url}" 2>/dev/null)
            
            local jobs_body=$(echo "$jobs_response" | sed '$d')
            local jobs_status=$(echo "$jobs_response" | tail -n1)
            
            if [[ "$jobs_status" -ge 200 && "$jobs_status" -lt 300 ]]; then
                # Find the specific job
                job_status=$(echo "$jobs_body" | jq -r ".[] | select(.name == \"${job_name}\") | .status // empty" 2>/dev/null)
                
                if [[ -n "$job_status" ]]; then
                    # Found the job, return its status
                    echo "$job_status"
                    return
                fi
            fi
            
            ((pipeline_index++))
        done
        
        # If we checked all pipelines and didn't find the job
        if [[ -z "$job_status" ]]; then
            echo "job_not_found"
        else
            echo "$job_status"
        fi
    else
        # Fallback without jq - try to parse JSON manually (basic check)
        if echo "$pipelines_body" | grep -q "\"id\""; then
            echo "unknown"  # Can't parse without jq
        else
            echo "no_pipeline"
        fi
    fi
}

# Verify fullqa branch
print_status "$YELLOW" "Checking fullqa branch..."
FULLQA_RESULT=$(check_branch_merged "fullqa" "$SOURCE_BRANCH_SHA")
FULLQA_EXISTS=$(echo "$FULLQA_RESULT" | cut -d'|' -f1)
FULLQA_MERGED=$(echo "$FULLQA_RESULT" | cut -d'|' -f2)
FULLQA_MERGE_COMMIT=$(echo "$FULLQA_RESULT" | cut -d'|' -f3)

# Verify develop branch
print_status "$YELLOW" "Checking develop branch..."
DEVELOP_RESULT=$(check_branch_merged "develop" "$SOURCE_BRANCH_SHA")
DEVELOP_EXISTS=$(echo "$DEVELOP_RESULT" | cut -d'|' -f1)
DEVELOP_MERGED=$(echo "$DEVELOP_RESULT" | cut -d'|' -f2)
DEVELOP_MERGE_COMMIT=$(echo "$DEVELOP_RESULT" | cut -d'|' -f3)

# Remove trailing slash from CI_SERVER_HOST for API calls
CI_SERVER_HOST_CLEAN=$(echo "$CI_SERVER_HOST" | sed 's|/$||')

# Function to find commits with successful deploy jobs
# Checks multiple commits that contain the source SHA until we find one with a successful deploy
# Returns: "status|commit_sha" format
find_deploy_job_status() {
    local target_branch=$1
    local source_sha=$2
    local job_name=$3
    local access_token=$4
    local project_id=$5
    local server_host=$6
    local source_branch_name=$7  # Source branch name for matching commit messages
    
    # Get commits on the target branch and check if they contain the source SHA
    local commits
    commits=$(git log --format="%H" "origin/$target_branch" 2>/dev/null || echo "")
    
    if [[ -z "$commits" ]]; then
        echo "no_commits|"
        return
    fi
    
    # First pass: Check merge commits that mention the source branch in the commit message
    # These are the commits that actually merged the source branch
    while IFS= read -r commit_sha; do
        if [[ -z "$commit_sha" ]]; then
            continue
        fi
        
        # Check if this commit contains the source SHA and is a merge commit
        if git merge-base --is-ancestor "$source_sha" "$commit_sha" 2>/dev/null; then
            # Check if it's a merge commit (has more than one parent)
            local parent_count
            parent_count=$(git cat-file -p "$commit_sha" 2>/dev/null | grep -c "^parent " || echo "0")
            if [[ "$parent_count" -gt 1 ]]; then
                # Check if commit message mentions the source branch name
                # Match the branch name more precisely to avoid matching similar branch names
                # Look for patterns like "origin/branch" or "'branch'" in commit messages
                local commit_msg
                commit_msg=$(git log -1 --format="%B" "$commit_sha" 2>/dev/null || echo "")
                # Escape special characters in branch name for regex matching
                local escaped_branch
                escaped_branch=$(printf '%s\n' "$source_branch_name" | sed 's/[[\.*^$()+?{|]/\\&/g')
                # Match branch name as part of "origin/branch" pattern (most common in merge commits)
                # or as a whole word (using word boundaries, but handle hyphens specially)
                if echo "$commit_msg" | grep -qiE "origin/${escaped_branch}(['\"]| |\$|/)" || \
                   echo "$commit_msg" | grep -qiE "(^|[^0-9A-Za-z-])${escaped_branch}([^0-9A-Za-z-]|\$)"; then
                    print_status "$YELLOW" "  Checking merge commit $commit_sha (merged source branch)..." >&2
                    local job_status
                    job_status=$(check_deployment_job_status "$commit_sha" "$job_name" "$access_token" "$project_id" "$server_host" 2>/dev/null)
                    
                    # If we found the job (regardless of status), return it with the commit SHA
                    if [[ "$job_status" != "job_not_found" && "$job_status" != "no_pipeline" && "$job_status" != "api_error" && "$job_status" != "unknown" && -n "$job_status" ]]; then
                        echo "$job_status|$commit_sha"
                        return
                    fi
                fi
            fi
        fi
    done <<< "$commits"
    
    # Second pass: Check all merge commits that contain the source SHA
    while IFS= read -r commit_sha; do
        if [[ -z "$commit_sha" ]]; then
            continue
        fi
        
        # Check if this commit contains the source SHA and is a merge commit
        if git merge-base --is-ancestor "$source_sha" "$commit_sha" 2>/dev/null; then
            # Check if it's a merge commit (has more than one parent)
            local parent_count
            parent_count=$(git cat-file -p "$commit_sha" 2>/dev/null | grep -c "^parent " || echo "0")
            if [[ "$parent_count" -gt 1 ]]; then
                print_status "$YELLOW" "  Checking merge commit $commit_sha (contains source SHA)..." >&2
                local job_status
                job_status=$(check_deployment_job_status "$commit_sha" "$job_name" "$access_token" "$project_id" "$server_host" 2>/dev/null)
                
                # If we found the job (regardless of status), return it with the commit SHA
                if [[ "$job_status" != "job_not_found" && "$job_status" != "no_pipeline" && "$job_status" != "api_error" && "$job_status" != "unknown" && -n "$job_status" ]]; then
                    echo "$job_status|$commit_sha"
                    return
                fi
            fi
        fi
    done <<< "$commits"
    
    # Third pass: If no merge commit had the deploy job, check all commits that contain the source SHA
    while IFS= read -r commit_sha; do
        if [[ -z "$commit_sha" ]]; then
            continue
        fi
        
        # Check if this commit contains the source SHA
        if git merge-base --is-ancestor "$source_sha" "$commit_sha" 2>/dev/null; then
            print_status "$YELLOW" "  Checking commit $commit_sha (contains source SHA)..." >&2
            local job_status
            job_status=$(check_deployment_job_status "$commit_sha" "$job_name" "$access_token" "$project_id" "$server_host" 2>/dev/null)
            
            # If we found the job (regardless of status), return it with the commit SHA
            if [[ "$job_status" != "job_not_found" && "$job_status" != "no_pipeline" && "$job_status" != "api_error" && "$job_status" != "unknown" && -n "$job_status" ]]; then
                echo "$job_status|$commit_sha"
                return
            fi
        fi
    done <<< "$commits"
    
    # If we checked all commits and didn't find the job
    echo "job_not_found|"
}

# Check deployment job status if branches are merged
# We check multiple commits that contain the source SHA to find the one with the deploy job
FULLQA_DEPLOY_STATUS=""
DEVELOP_DEPLOY_STATUS=""

FULLQA_DEPLOY_COMMIT=""
DEVELOP_DEPLOY_COMMIT=""

if [[ "$FULLQA_EXISTS" == "true" && "$FULLQA_MERGED" == "true" ]]; then
    print_status "$YELLOW" "Searching for deploy:fullqa job in commits containing source SHA..."
    FULLQA_RESULT=$(find_deploy_job_status "fullqa" "$SOURCE_BRANCH_SHA" "deploy:fullqa" "$MAINTAINER_PAT_VALUE" "$CI_PROJECT_ID" "$CI_SERVER_HOST" "$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" 2>&1 | grep -v "Checking commit" | tail -1)
    FULLQA_DEPLOY_STATUS=$(echo "$FULLQA_RESULT" | cut -d'|' -f1)
    FULLQA_DEPLOY_COMMIT=$(echo "$FULLQA_RESULT" | cut -d'|' -f2)
    print_status "$YELLOW" "  deploy:fullqa status: $FULLQA_DEPLOY_STATUS"
    if [[ -n "$FULLQA_DEPLOY_COMMIT" ]]; then
        print_status "$YELLOW" "  deploy:fullqa commit: $FULLQA_DEPLOY_COMMIT"
    fi
fi

if [[ "$DEVELOP_EXISTS" == "true" && "$DEVELOP_MERGED" == "true" ]]; then
    print_status "$YELLOW" "Searching for deploy:dev job in commits containing source SHA..."
    DEVELOP_RESULT=$(find_deploy_job_status "develop" "$SOURCE_BRANCH_SHA" "deploy:dev" "$MAINTAINER_PAT_VALUE" "$CI_PROJECT_ID" "$CI_SERVER_HOST" "$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" 2>&1 | grep -v "Checking commit" | tail -1)
    DEVELOP_DEPLOY_STATUS=$(echo "$DEVELOP_RESULT" | cut -d'|' -f1)
    DEVELOP_DEPLOY_COMMIT=$(echo "$DEVELOP_RESULT" | cut -d'|' -f2)
    print_status "$YELLOW" "  deploy:dev status: $DEVELOP_DEPLOY_STATUS"
    if [[ -n "$DEVELOP_DEPLOY_COMMIT" ]]; then
        print_status "$YELLOW" "  deploy:dev commit: $DEVELOP_DEPLOY_COMMIT"
    fi
fi

# Build the comment message (using actual newlines)
COMMENT_BODY="## Branch Deployment Verification

**Source Branch:** \`$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME\`
**Source SHA:** \`$SOURCE_BRANCH_SHA\`
**Target Branch:** \`$CI_MERGE_REQUEST_TARGET_BRANCH_NAME\`

### Verification Results

"

# FullQA status
if [[ "$FULLQA_EXISTS" == "true" ]]; then
    if [[ "$FULLQA_MERGED" == "true" ]]; then
        if [[ "$FULLQA_DEPLOY_STATUS" == "success" ]]; then
            if [[ -n "$FULLQA_DEPLOY_COMMIT" ]]; then
                COMMENT_BODY+=":white_check_mark: **fullqa**: Merged and deployed successfully (commit: \`${FULLQA_DEPLOY_COMMIT:0:8}\`)"$'\n'
            else
                COMMENT_BODY+=":white_check_mark: **fullqa**: Merged and deployed successfully"$'\n'
            fi
            print_status "$GREEN" "✓ fullqa: Merged and deployed successfully"
        elif [[ "$FULLQA_DEPLOY_STATUS" == "failed" ]]; then
            if [[ -n "$FULLQA_DEPLOY_COMMIT" ]]; then
                COMMENT_BODY+=":x: **fullqa**: Merged but deployment failed (commit: \`${FULLQA_DEPLOY_COMMIT:0:8}\`)"$'\n'
            else
                COMMENT_BODY+=":x: **fullqa**: Merged but deployment failed"$'\n'
            fi
            print_status "$RED" "✗ fullqa: Merged but deployment failed"
        elif [[ "$FULLQA_DEPLOY_STATUS" == "running" || "$FULLQA_DEPLOY_STATUS" == "pending" ]]; then
            COMMENT_BODY+=":hourglass: **fullqa**: Merged, deployment in progress"$'\n'
            print_status "$YELLOW" "⏳ fullqa: Merged, deployment in progress"
        elif [[ "$FULLQA_DEPLOY_STATUS" == "job_not_found" ]]; then
            COMMENT_BODY+=":warning: **fullqa**: Merged but deploy job not found"$'\n'
            print_status "$YELLOW" "⚠ fullqa: Merged but deploy job not found"
        elif [[ "$FULLQA_DEPLOY_STATUS" == "no_pipeline" ]]; then
            COMMENT_BODY+=":warning: **fullqa**: Merged but no pipeline found"$'\n'
            print_status "$YELLOW" "⚠ fullqa: Merged but no pipeline found"
        else
            COMMENT_BODY+=":question: **fullqa**: Merged, deployment status unknown ($FULLQA_DEPLOY_STATUS)"$'\n'
            print_status "$YELLOW" "? fullqa: Merged, deployment status unknown"
        fi
    else
        COMMENT_BODY+=":x: **fullqa**: Not merged"$'\n'
        print_status "$RED" "✗ fullqa: Not merged"
    fi
else
    COMMENT_BODY+=":warning: **fullqa**: Branch does not exist"$'\n'
    print_status "$YELLOW" "⚠ fullqa: Branch does not exist"
fi

# Develop status
if [[ "$DEVELOP_EXISTS" == "true" ]]; then
    if [[ "$DEVELOP_MERGED" == "true" ]]; then
        if [[ "$DEVELOP_DEPLOY_STATUS" == "success" ]]; then
            if [[ -n "$DEVELOP_DEPLOY_COMMIT" ]]; then
                COMMENT_BODY+=":white_check_mark: **develop**: Merged and deployed successfully (commit: \`${DEVELOP_DEPLOY_COMMIT:0:8}\`)"$'\n'
            else
                COMMENT_BODY+=":white_check_mark: **develop**: Merged and deployed successfully"$'\n'
            fi
            print_status "$GREEN" "✓ develop: Merged and deployed successfully"
        elif [[ "$DEVELOP_DEPLOY_STATUS" == "failed" ]]; then
            if [[ -n "$DEVELOP_DEPLOY_COMMIT" ]]; then
                COMMENT_BODY+=":x: **develop**: Merged but deployment failed (commit: \`${DEVELOP_DEPLOY_COMMIT:0:8}\`)"$'\n'
            else
                COMMENT_BODY+=":x: **develop**: Merged but deployment failed"$'\n'
            fi
            print_status "$RED" "✗ develop: Merged but deployment failed"
        elif [[ "$DEVELOP_DEPLOY_STATUS" == "running" || "$DEVELOP_DEPLOY_STATUS" == "pending" ]]; then
            COMMENT_BODY+=":hourglass: **develop**: Merged, deployment in progress"$'\n'
            print_status "$YELLOW" "⏳ develop: Merged, deployment in progress"
        elif [[ "$DEVELOP_DEPLOY_STATUS" == "job_not_found" ]]; then
            COMMENT_BODY+=":warning: **develop**: Merged but deploy job not found"$'\n'
            print_status "$YELLOW" "⚠ develop: Merged but deploy job not found"
        elif [[ "$DEVELOP_DEPLOY_STATUS" == "no_pipeline" ]]; then
            COMMENT_BODY+=":warning: **develop**: Merged but no pipeline found"$'\n'
            print_status "$YELLOW" "⚠ develop: Merged but no pipeline found"
        else
            COMMENT_BODY+=":question: **develop**: Merged, deployment status unknown ($DEVELOP_DEPLOY_STATUS)"$'\n'
            print_status "$YELLOW" "? develop: Merged, deployment status unknown"
        fi
    else
        COMMENT_BODY+=":x: **develop**: Not merged"$'\n'
        print_status "$RED" "✗ develop: Not merged"
    fi
else
    COMMENT_BODY+=":warning: **develop**: Branch does not exist"$'\n'
    print_status "$YELLOW" "⚠ develop: Branch does not exist"
fi

COMMENT_BODY+=$'\n'"---"$'\n'
COMMENT_BODY+="*This verification was performed automatically by the CI/CD pipeline.*"

# Prepare JSON payload for GitLab API
# Use jq if available for proper JSON encoding, otherwise use printf
if command -v jq &> /dev/null; then
    JSON_PAYLOAD=$(jq -n --arg body "$COMMENT_BODY" '{body: $body}')
else
    # Fallback: manual JSON encoding (escape backslashes, quotes, and newlines)
    ESCAPED_BODY=$(printf '%s' "$COMMENT_BODY" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/\r/\\r/g')
    JSON_PAYLOAD="{\"body\":\"$ESCAPED_BODY\"}"
fi

# GitLab API endpoint for posting a comment to a merge request
API_URL="https://${CI_SERVER_HOST_CLEAN}/api/v4/projects/${CI_PROJECT_ID}/merge_requests/${CI_MERGE_REQUEST_IID}/notes"

print_status "$YELLOW" "Posting comment to merge request..."
print_status "$YELLOW" "API URL: $API_URL"

# Post comment to GitLab MR using project access token
HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD" \
    "$API_URL" 2>&1)

HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)

if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
    print_status "$GREEN" "✓ Successfully posted comment to merge request (HTTP $HTTP_STATUS)"
    if command -v jq &> /dev/null; then
        COMMENT_ID=$(echo "$HTTP_BODY" | jq -r '.id // empty')
        if [[ -n "$COMMENT_ID" ]]; then
            print_status "$GREEN" "Comment ID: $COMMENT_ID"
        fi
    fi
else
    print_status "$RED" "✗ Failed to post comment to merge request (HTTP $HTTP_STATUS)"
    print_status "$RED" "Response: $HTTP_BODY"
    exit 1
fi

# Summary
print_status "$GREEN" "\n=== Verification Summary ==="
if [[ "$FULLQA_EXISTS" == "true" && "$FULLQA_MERGED" == "true" && "$FULLQA_DEPLOY_STATUS" == "success" ]] && \
   [[ "$DEVELOP_EXISTS" == "true" && "$DEVELOP_MERGED" == "true" && "$DEVELOP_DEPLOY_STATUS" == "success" ]]; then
    print_status "$GREEN" "✓ All branches verified and deployed successfully!"
    exit 0
elif [[ "$FULLQA_EXISTS" == "true" && "$FULLQA_MERGED" == "true" ]] && \
     [[ "$DEVELOP_EXISTS" == "true" && "$DEVELOP_MERGED" == "true" ]]; then
    print_status "$YELLOW" "⚠ Branches merged but deployments may not be complete"
    exit 0
else
    print_status "$YELLOW" "⚠ Some branches are not yet merged or deployed"
    exit 0
fi

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
git config user.name "${MAINTAINER_PAT_NAME}"
git config user.email "${MAINTAINER_PAT_USER_NAME}@noreply.${CI_SERVER_HOST}"

# Get the latest commit SHA from the source branch
SOURCE_BRANCH_SHA=$(git rev-parse "origin/$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" 2>/dev/null || echo "")
if [[ -z "$SOURCE_BRANCH_SHA" ]]; then
    print_status "$RED" "Error: Could not find source branch origin/$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME"
    exit 1
fi

print_status "$YELLOW" "Source branch SHA: $SOURCE_BRANCH_SHA"

# Function to check how old the source branch is relative to the default branch
# Returns: "status|age_days|merge_base_sha" format
# status: "recent" if <= 30 days, "old" if > 30 days, "error" if unable to determine
check_branch_age() {
    local source_branch=$1
    local default_branch=$2
    local max_age_days=${3:-30}  # Default to 30 days
    
    # Find the merge base (common ancestor) between source and default branch
    local merge_base_sha
    merge_base_sha=$(git merge-base "origin/$source_branch" "origin/$default_branch" 2>/dev/null || echo "")
    
    if [[ -z "$merge_base_sha" ]]; then
        echo "error|0|"
        return
    fi
    
    # Get the commit timestamp (Unix timestamp in seconds)
    local commit_timestamp
    commit_timestamp=$(git log -1 --format="%ct" "$merge_base_sha" 2>/dev/null || echo "")
    
    if [[ -z "$commit_timestamp" ]]; then
        echo "error|0|$merge_base_sha"
        return
    fi
    
    # Get current timestamp (Unix timestamp in seconds)
    # Works on Linux, macOS, and Git Bash on Windows
    local current_timestamp
    if command -v date &> /dev/null; then
        # Try UTC first (more reliable), fallback to local time
        current_timestamp=$(date -u +%s 2>/dev/null || date +%s 2>/dev/null || echo "")
    else
        # Fallback: use epoch time calculation if date command is not available
        echo "error|0|$merge_base_sha"
        return
    fi
    
    if [[ -z "$current_timestamp" ]]; then
        echo "error|0|$merge_base_sha"
        return
    fi
    
    # Calculate age in days
    local age_seconds=$((current_timestamp - commit_timestamp))
    local age_days=$((age_seconds / 86400))  # 86400 seconds in a day
    
    # Determine status
    local status="recent"
    if [[ $age_days -gt $max_age_days ]]; then
        status="old"
    fi
    
    echo "$status|$age_days|$merge_base_sha"
}

# Check branch age relative to default branch
print_status "$YELLOW" "Checking source branch age relative to default branch..."
BRANCH_AGE_RESULT=$(check_branch_age "$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" "$CI_DEFAULT_BRANCH" 30)
BRANCH_AGE_STATUS=$(echo "$BRANCH_AGE_RESULT" | cut -d'|' -f1)
BRANCH_AGE_DAYS=$(echo "$BRANCH_AGE_RESULT" | cut -d'|' -f2)
BRANCH_MERGE_BASE_SHA=$(echo "$BRANCH_AGE_RESULT" | cut -d'|' -f3)

if [[ "$BRANCH_AGE_STATUS" == "recent" ]]; then
    print_status "$GREEN" "✓ Source branch is recent (created from default branch $BRANCH_AGE_DAYS days ago)"
elif [[ "$BRANCH_AGE_STATUS" == "old" ]]; then
    print_status "$RED" "✗ Source branch is old (created from default branch $BRANCH_AGE_DAYS days ago)"
else
    print_status "$YELLOW" "⚠ Could not determine branch age"
fi

# Function to check if source branch name contains valid Jira project key
# Returns: "status" format
# status: "valid" if contains valid Jira key, "invalid_bar" if contains BAR, "invalid_no_key" if no valid key found
check_branch_name() {
    local branch_name=$1
    local branch_lower=$(echo "$branch_name" | tr '[:upper:]' '[:lower:]')
    
    # Check if branch contains BAR (release team project) - fail if found
    if [[ "$branch_lower" == *"bar"* ]]; then
        echo "invalid_bar"
        return
    fi
    
    # Check if branch contains any valid Jira project keys (case insensitive)
    local valid_keys=("q2c" "storm" "shield" "sfxpro" "leadz" "avatechtdr")
    for key in "${valid_keys[@]}"; do
        if [[ "$branch_lower" == *"$key"* ]]; then
            echo "valid"
            return
        fi
    done
    
    # No valid key found
    echo "invalid_no_key"
}

# Check branch name for valid Jira project key
print_status "$YELLOW" "Checking source branch name for valid Jira project key..."
BRANCH_NAME_STATUS=$(check_branch_name "$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME")

if [[ "$BRANCH_NAME_STATUS" == "valid" ]]; then
    print_status "$GREEN" "✓ Source branch name contains valid Jira project key"
elif [[ "$BRANCH_NAME_STATUS" == "invalid_bar" ]]; then
    print_status "$RED" "✗ Source branch name contains BAR (release team project)"
else
    print_status "$RED" "✗ Source branch name does not contain a valid Jira project key (q2c, storm, shield, sfxpro, leadz, avatechtdr)"
fi

# Function to check if source branch contains merges from fullqa or develop branches
# Returns: "status|offending_commits" format
# status: "clean" if no forbidden merges found, "forbidden_merge" if found, "error" if unable to check
check_forbidden_merges() {
    local source_branch=$1
    local default_branch=$2
    local forbidden_branches=("fullqa" "develop")
    local offending_commits=()
    
    # Check commit messages on the source branch for forbidden merge patterns
    # Only check commits that are on the source branch but NOT on the default branch
    # This avoids flagging old commits that were already merged into default
    # Look for patterns like "Merge fullqa into", "merge origin/fullqa into", etc.
    # We only want to catch merges FROM fullqa/develop INTO the source branch, not the reverse
    for forbidden_branch in "${forbidden_branches[@]}"; do
        # Search for merge commits that mention the forbidden branch being merged INTO something
        # Patterns: "Merge fullqa into", "merge origin/fullqa into", "Merge branch 'fullqa' into"
        # We use --merges to only check actual merge commits
        # The pattern ensures the forbidden branch comes before "into" (meaning it's being merged in)
        # Use "origin/$default_branch..origin/$source_branch" to only check commits unique to source branch
        local matching_commits
        matching_commits=$(git log --format="%H" --merges --grep="[Mm]erge.*$forbidden_branch.*into\|[Mm]erge.*origin/$forbidden_branch.*into\|[Mm]erge.*branch.*['\"]$forbidden_branch.*into" "origin/$default_branch..origin/$source_branch" 2>/dev/null || echo "")
        
        if [[ -n "$matching_commits" ]]; then
            # Add matching commits to offending commits list
            while IFS= read -r commit; do
                if [[ -n "$commit" ]]; then
                    offending_commits+=("$commit")
                fi
            done <<< "$matching_commits"
        fi
    done
    
    # Return results
    if [[ ${#offending_commits[@]} -gt 0 ]]; then
        # Join offending commits with comma
        local commits_str
        commits_str=$(IFS=','; echo "${offending_commits[*]}")
        echo "forbidden_merge|$commits_str"
    else
        echo "clean|"
    fi
}

# Check for forbidden merges (fullqa/develop into source branch)
print_status "$YELLOW" "Checking for forbidden merges (fullqa/develop into source branch)..."
FORBIDDEN_MERGE_RESULT=$(check_forbidden_merges "$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" "$CI_DEFAULT_BRANCH")
FORBIDDEN_MERGE_STATUS=$(echo "$FORBIDDEN_MERGE_RESULT" | cut -d'|' -f1)
FORBIDDEN_MERGE_COMMITS=$(echo "$FORBIDDEN_MERGE_RESULT" | cut -d'|' -f2)

if [[ "$FORBIDDEN_MERGE_STATUS" == "clean" ]]; then
    print_status "$GREEN" "✓ No forbidden merges found (source branch does not merge fullqa/develop)"
elif [[ "$FORBIDDEN_MERGE_STATUS" == "forbidden_merge" ]]; then
    print_status "$RED" "✗ Forbidden merges detected! Source branch contains merge commits from fullqa/develop"
    if [[ -n "$FORBIDDEN_MERGE_COMMITS" ]]; then
        print_status "$RED" "  Offending commit(s): $FORBIDDEN_MERGE_COMMITS"
    fi
else
    print_status "$YELLOW" "⚠ Could not check for forbidden merges"
fi

# Function to check for merge conflicts between source and target branch
# Returns: "status|conflicted_files" format
# status: "no_conflicts" if no conflicts, "acceptable_conflicts" if only manifest/package.xml, "conflicts" if other conflicts, "error" if unable to check
check_merge_conflicts() {
    local source_branch=$1
    local target_branch=$2
    local current_branch=""
    local conflicted_files=()
    
    # Save current branch/HEAD position
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
    
    # Check if source branch exists
    if ! git show-ref --verify --quiet "refs/remotes/origin/$source_branch" 2>/dev/null; then
        echo "error|Source branch not found"
        return
    fi
    
    # Check if target branch exists
    if ! git show-ref --verify --quiet "refs/remotes/origin/$target_branch" 2>/dev/null; then
        echo "error|Target branch not found"
        return
    fi
    
    # Checkout target branch (detached HEAD is fine for testing)
    # This simulates merging source branch INTO target branch (main/default)
    if ! git checkout -q "origin/$target_branch" 2>/dev/null; then
        echo "error|Could not checkout target branch"
        return
    fi
    
    # Attempt merge with --no-commit and --no-ff to detect conflicts without committing
    # Merge source branch INTO target branch (simulating the actual MR merge)
    # Capture stderr to check for merge messages, but don't fail on merge conflicts
    local merge_output
    merge_output=$(git merge --no-commit --no-ff "origin/$source_branch" 2>&1)
    local merge_exit_code=$?
    
    # Check if merge succeeded (exit code 0 means success, no conflicts)
    if [[ $merge_exit_code -eq 0 ]]; then
        # Merge succeeded, no conflicts
        git merge --abort 2>/dev/null || true
        # Restore original position
        git checkout -q "$current_branch" 2>/dev/null || true
        echo "no_conflicts|"
        return
    fi
    
    # Merge failed, check for conflicts
    # Get list of unmerged (conflicted) files
    # git ls-files -u shows unmerged files (conflicts)
    local unmerged_files
    unmerged_files=$(git ls-files -u 2>/dev/null | awk '{print $4}' | sort -u 2>/dev/null || echo "")
    
    # If no unmerged files found, check if we're in a merge state
    if [[ -z "$unmerged_files" ]]; then
        # Check if we're actually in a merge state
        if [[ -f ".git/MERGE_HEAD" ]]; then
            # We're in a merge state but no conflicts detected - this shouldn't happen
            # Abort and return error
            git merge --abort 2>/dev/null || true
            git checkout -q "$current_branch" 2>/dev/null || true
            echo "error|Merge failed but no conflicts detected"
            return
        else
            # Not in merge state, might be a different error
            git merge --abort 2>/dev/null || true
            git checkout -q "$current_branch" 2>/dev/null || true
            echo "error|Merge failed: $merge_output"
            return
        fi
    fi
    
    # Check if conflicts are only in manifest/package.xml
    local only_package_xml=true
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            conflicted_files+=("$file")
            # If file is not manifest/package.xml, mark as not acceptable
            if [[ "$file" != "manifest/package.xml" ]]; then
                only_package_xml=false
            fi
        fi
    done <<< "$unmerged_files"
    
    # Abort the merge
    git merge --abort 2>/dev/null || true
    
    # Restore original position
    git checkout -q "$current_branch" 2>/dev/null || true
    
    # Return results
    if [[ "$only_package_xml" == "true" && ${#conflicted_files[@]} -gt 0 ]]; then
        # Join conflicted files with comma
        local files_str
        files_str=$(IFS=','; echo "${conflicted_files[*]}")
        echo "acceptable_conflicts|$files_str"
    elif [[ ${#conflicted_files[@]} -gt 0 ]]; then
        # Join conflicted files with comma
        local files_str
        files_str=$(IFS=','; echo "${conflicted_files[*]}")
        echo "conflicts|$files_str"
    else
        echo "no_conflicts|"
    fi
}

# Check for merge conflicts between source and target branch
print_status "$YELLOW" "Checking for merge conflicts between source and target branch..."
MERGE_CONFLICT_RESULT=$(check_merge_conflicts "$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME")
MERGE_CONFLICT_STATUS=$(echo "$MERGE_CONFLICT_RESULT" | cut -d'|' -f1)
MERGE_CONFLICT_FILES=$(echo "$MERGE_CONFLICT_RESULT" | cut -d'|' -f2)

if [[ "$MERGE_CONFLICT_STATUS" == "no_conflicts" ]]; then
    print_status "$GREEN" "✓ No merge conflicts between source and target branch"
elif [[ "$MERGE_CONFLICT_STATUS" == "acceptable_conflicts" ]]; then
    print_status "$GREEN" "✓ Merge conflicts found, but only in manifest/package.xml (acceptable)"
elif [[ "$MERGE_CONFLICT_STATUS" == "conflicts" ]]; then
    print_status "$RED" "✗ Merge conflicts detected between source and target branch"
    if [[ -n "$MERGE_CONFLICT_FILES" ]]; then
        print_status "$RED" "  Conflicted file(s): $MERGE_CONFLICT_FILES"
    fi
else
    print_status "$YELLOW" "⚠ Could not check for merge conflicts: $MERGE_CONFLICT_FILES"
fi

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

# Check production validation job status (test:predeploy:prd) for the source branch commit
print_status "$YELLOW" "Checking production validation job (test:predeploy:prd) for source branch commit..."
PREDEPLOY_PRD_STATUS=$(check_deployment_job_status "$SOURCE_BRANCH_SHA" "test:predeploy:prd" "$MAINTAINER_PAT_VALUE" "$CI_PROJECT_ID" "$CI_SERVER_HOST_CLEAN")

if [[ "$PREDEPLOY_PRD_STATUS" == "success" ]]; then
    print_status "$GREEN" "✓ Production validation (test:predeploy:prd) passed"
elif [[ "$PREDEPLOY_PRD_STATUS" == "failed" ]]; then
    print_status "$RED" "✗ Production validation (test:predeploy:prd) failed"
elif [[ "$PREDEPLOY_PRD_STATUS" == "running" || "$PREDEPLOY_PRD_STATUS" == "pending" ]]; then
    print_status "$YELLOW" "⏳ Production validation (test:predeploy:prd) in progress"
elif [[ "$PREDEPLOY_PRD_STATUS" == "job_not_found" ]]; then
    print_status "$YELLOW" "⚠ Production validation (test:predeploy:prd) job not found"
elif [[ "$PREDEPLOY_PRD_STATUS" == "no_pipeline" ]]; then
    print_status "$YELLOW" "⚠ Production validation (test:predeploy:prd) - no pipeline found"
elif [[ "$PREDEPLOY_PRD_STATUS" == "api_error" ]]; then
    print_status "$YELLOW" "⚠ Production validation (test:predeploy:prd) - API error"
else
    print_status "$YELLOW" "? Production validation (test:predeploy:prd) status unknown ($PREDEPLOY_PRD_STATUS)"
fi

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

# Branch name check
if [[ "$BRANCH_NAME_STATUS" == "valid" ]]; then
    COMMENT_BODY+="- :white_check_mark: **Branch Name**: Source branch contains valid Jira project key"$'\n'
elif [[ "$BRANCH_NAME_STATUS" == "invalid_bar" ]]; then
    COMMENT_BODY+="- :x: **Branch Name**: Source branch contains BAR (release team project)"$'\n'
else
    COMMENT_BODY+="- :x: **Branch Name**: Source branch does not contain a valid Jira project key (q2c, storm, shield, sfxpro, leadz, avatechtdr)"$'\n'
fi

# Branch age check
if [[ "$BRANCH_AGE_STATUS" == "recent" ]]; then
    COMMENT_BODY+="- :white_check_mark: **Branch Age**: Source branch created from default branch $BRANCH_AGE_DAYS days ago (within 30 days)"$'\n'
elif [[ "$BRANCH_AGE_STATUS" == "old" ]]; then
    COMMENT_BODY+="- :x: **Branch Age**: Source branch created from default branch $BRANCH_AGE_DAYS days ago (over 30 days old)"$'\n'
else
    COMMENT_BODY+="- :warning: **Branch Age**: Could not determine branch age"$'\n'
fi

# Forbidden merge check
if [[ "$FORBIDDEN_MERGE_STATUS" == "clean" ]]; then
    COMMENT_BODY+="- :white_check_mark: **Forbidden Merges**: No merges from fullqa/develop into source branch"$'\n'
elif [[ "$FORBIDDEN_MERGE_STATUS" == "forbidden_merge" ]]; then
    if [[ -n "$FORBIDDEN_MERGE_COMMITS" ]]; then
        # Format commit SHAs (first 8 chars) for display
        commit_list=""
        IFS=',' read -ra COMMITS <<< "$FORBIDDEN_MERGE_COMMITS"
        for commit in "${COMMITS[@]}"; do
            if [[ -n "$commit_list" ]]; then
                commit_list+=", "
            fi
            commit_list+="\`${commit:0:8}\`"
        done
        COMMENT_BODY+="- :x: **Forbidden Merges**: Source branch contains merge commits from fullqa/develop (commit(s): $commit_list)"$'\n'
    else
        COMMENT_BODY+="- :x: **Forbidden Merges**: Source branch contains merge commits from fullqa/develop"$'\n'
    fi
else
    COMMENT_BODY+="- :warning: **Forbidden Merges**: Could not check for forbidden merges"$'\n'
fi

# Merge conflict check
if [[ "$MERGE_CONFLICT_STATUS" == "no_conflicts" ]]; then
    COMMENT_BODY+="- :white_check_mark: **Merge Conflicts**: No conflicts between source and target branch"$'\n'
elif [[ "$MERGE_CONFLICT_STATUS" == "acceptable_conflicts" ]]; then
    COMMENT_BODY+="- :white_check_mark: **Merge Conflicts**: Conflicts found, but only in manifest/package.xml (acceptable)"$'\n'
elif [[ "$MERGE_CONFLICT_STATUS" == "conflicts" ]]; then
    if [[ -n "$MERGE_CONFLICT_FILES" ]]; then
        # Format file names for display
        file_list=""
        IFS=',' read -ra FILES <<< "$MERGE_CONFLICT_FILES"
        for file in "${FILES[@]}"; do
            if [[ -n "$file_list" ]]; then
                file_list+=", "
            fi
            file_list+="\`$file\`"
        done
        COMMENT_BODY+="- :x: **Merge Conflicts**: Conflicts detected between source and target branch (file(s): $file_list)"$'\n'
    else
        COMMENT_BODY+="- :x: **Merge Conflicts**: Conflicts detected between source and target branch"$'\n'
    fi
else
    COMMENT_BODY+="- :warning: **Merge Conflicts**: Could not check for merge conflicts"$'\n'
fi

# Production validation check
if [[ "$PREDEPLOY_PRD_STATUS" == "success" ]]; then
    COMMENT_BODY+="- :white_check_mark: **Production Validation**: test:predeploy:prd job passed"$'\n'
elif [[ "$PREDEPLOY_PRD_STATUS" == "failed" ]]; then
    COMMENT_BODY+="- :x: **Production Validation**: test:predeploy:prd job failed"$'\n'
elif [[ "$PREDEPLOY_PRD_STATUS" == "running" || "$PREDEPLOY_PRD_STATUS" == "pending" ]]; then
    COMMENT_BODY+="- :hourglass: **Production Validation**: test:predeploy:prd job in progress"$'\n'
elif [[ "$PREDEPLOY_PRD_STATUS" == "job_not_found" ]]; then
    COMMENT_BODY+="- :warning: **Production Validation**: test:predeploy:prd job not found"$'\n'
elif [[ "$PREDEPLOY_PRD_STATUS" == "no_pipeline" ]]; then
    COMMENT_BODY+="- :warning: **Production Validation**: test:predeploy:prd - no pipeline found"$'\n'
elif [[ "$PREDEPLOY_PRD_STATUS" == "api_error" ]]; then
    COMMENT_BODY+="- :warning: **Production Validation**: test:predeploy:prd - API error"$'\n'
else
    COMMENT_BODY+="- :question: **Production Validation**: test:predeploy:prd status unknown ($PREDEPLOY_PRD_STATUS)"$'\n'
fi

# FullQA status
if [[ "$FULLQA_EXISTS" == "true" ]]; then
    if [[ "$FULLQA_MERGED" == "true" ]]; then
        if [[ "$FULLQA_DEPLOY_STATUS" == "success" ]]; then
            if [[ -n "$FULLQA_DEPLOY_COMMIT" ]]; then
                COMMENT_BODY+="- :white_check_mark: **fullqa**: Merged and deployed successfully (commit: \`${FULLQA_DEPLOY_COMMIT:0:8}\`)"$'\n'
            else
                COMMENT_BODY+="- :white_check_mark: **fullqa**: Merged and deployed successfully"$'\n'
            fi
            print_status "$GREEN" "✓ fullqa: Merged and deployed successfully"
        elif [[ "$FULLQA_DEPLOY_STATUS" == "failed" ]]; then
            if [[ -n "$FULLQA_DEPLOY_COMMIT" ]]; then
                COMMENT_BODY+="- :x: **fullqa**: Merged but deployment failed (commit: \`${FULLQA_DEPLOY_COMMIT:0:8}\`)"$'\n'
            else
                COMMENT_BODY+="- :x: **fullqa**: Merged but deployment failed"$'\n'
            fi
            print_status "$RED" "✗ fullqa: Merged but deployment failed"
        elif [[ "$FULLQA_DEPLOY_STATUS" == "running" || "$FULLQA_DEPLOY_STATUS" == "pending" ]]; then
            COMMENT_BODY+="- :hourglass: **fullqa**: Merged, deployment in progress"$'\n'
            print_status "$YELLOW" "⏳ fullqa: Merged, deployment in progress"
        elif [[ "$FULLQA_DEPLOY_STATUS" == "job_not_found" ]]; then
            COMMENT_BODY+="- :warning: **fullqa**: Merged but deploy job not found"$'\n'
            print_status "$YELLOW" "⚠ fullqa: Merged but deploy job not found"
        elif [[ "$FULLQA_DEPLOY_STATUS" == "no_pipeline" ]]; then
            COMMENT_BODY+="- :warning: **fullqa**: Merged but no pipeline found"$'\n'
            print_status "$YELLOW" "⚠ fullqa: Merged but no pipeline found"
        else
            COMMENT_BODY+="- :question: **fullqa**: Merged, deployment status unknown ($FULLQA_DEPLOY_STATUS)"$'\n'
            print_status "$YELLOW" "? fullqa: Merged, deployment status unknown"
        fi
    else
        COMMENT_BODY+="- :x: **fullqa**: Not merged"$'\n'
        print_status "$RED" "✗ fullqa: Not merged"
    fi
else
    COMMENT_BODY+="- :warning: **fullqa**: Branch does not exist"$'\n'
    print_status "$YELLOW" "⚠ fullqa: Branch does not exist"
fi

# Develop status
if [[ "$DEVELOP_EXISTS" == "true" ]]; then
    if [[ "$DEVELOP_MERGED" == "true" ]]; then
        if [[ "$DEVELOP_DEPLOY_STATUS" == "success" ]]; then
            if [[ -n "$DEVELOP_DEPLOY_COMMIT" ]]; then
                COMMENT_BODY+="- :white_check_mark: **develop**: Merged and deployed successfully (commit: \`${DEVELOP_DEPLOY_COMMIT:0:8}\`)"$'\n'
            else
                COMMENT_BODY+="- :white_check_mark: **develop**: Merged and deployed successfully"$'\n'
            fi
            print_status "$GREEN" "✓ develop: Merged and deployed successfully"
        elif [[ "$DEVELOP_DEPLOY_STATUS" == "failed" ]]; then
            if [[ -n "$DEVELOP_DEPLOY_COMMIT" ]]; then
                COMMENT_BODY+="- :x: **develop**: Merged but deployment failed (commit: \`${DEVELOP_DEPLOY_COMMIT:0:8}\`)"$'\n'
            else
                COMMENT_BODY+="- :x: **develop**: Merged but deployment failed"$'\n'
            fi
            print_status "$RED" "✗ develop: Merged but deployment failed"
        elif [[ "$DEVELOP_DEPLOY_STATUS" == "running" || "$DEVELOP_DEPLOY_STATUS" == "pending" ]]; then
            COMMENT_BODY+="- :hourglass: **develop**: Merged, deployment in progress"$'\n'
            print_status "$YELLOW" "⏳ develop: Merged, deployment in progress"
        elif [[ "$DEVELOP_DEPLOY_STATUS" == "job_not_found" ]]; then
            COMMENT_BODY+="- :warning: **develop**: Merged but deploy job not found"$'\n'
            print_status "$YELLOW" "⚠ develop: Merged but deploy job not found"
        elif [[ "$DEVELOP_DEPLOY_STATUS" == "no_pipeline" ]]; then
            COMMENT_BODY+="- :warning: **develop**: Merged but no pipeline found"$'\n'
            print_status "$YELLOW" "⚠ develop: Merged but no pipeline found"
        else
            COMMENT_BODY+="- :question: **develop**: Merged, deployment status unknown ($DEVELOP_DEPLOY_STATUS)"$'\n'
            print_status "$YELLOW" "? develop: Merged, deployment status unknown"
        fi
    else
        COMMENT_BODY+="- :x: **develop**: Not merged"$'\n'
        print_status "$RED" "✗ develop: Not merged"
    fi
else
    COMMENT_BODY+="- :warning: **develop**: Branch does not exist"$'\n'
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

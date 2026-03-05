#!/bin/bash
################################################################################
# Script: verify_branch_compliance_sbx.sh
# Description: For MRs targeting fullqa or develop, verifies the source branch
#              follows process: created from main, not stale, and does not
#              contain merges from fullqa/develop. Posts a comment to the MR.
#              Use this to catch compliance issues earlier (on fullqa/develop
#              MRs) before the main MR verification runs.
# Usage: Called from GitLab CI when MR target is fullqa or develop
# Dependencies: git, curl, jq (optional)
# Environment Variables Required:
#   - CI_COMMIT_SHA (commit that triggered pipeline; avoids race when new commits are pushed),
#     CI_MERGE_REQUEST_IID, CI_MERGE_REQUEST_SOURCE_BRANCH_NAME,
#     CI_MERGE_REQUEST_TARGET_BRANCH_NAME, CI_PROJECT_ID, CI_SERVER_HOST,
#     CI_PROJECT_PATH, MAINTAINER_PAT_VALUE, CI_DEFAULT_BRANCH
################################################################################
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

check_required_var() {
    local var_name=$1
    if [[ -z "${!var_name:-}" ]]; then
        print_status "$RED" "Error: Required environment variable $var_name is not set"
        exit 1
    fi
}

# Only run when MR targets fullqa or develop
if [[ "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" != "fullqa" && "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" != "develop" ]]; then
    print_status "$YELLOW" "Skipping: MR target is not fullqa or develop (target: $CI_MERGE_REQUEST_TARGET_BRANCH_NAME)"
    exit 0
fi

print_status "$YELLOW" "Validating required environment variables..."
check_required_var "CI_COMMIT_SHA"
check_required_var "CI_MERGE_REQUEST_IID"
check_required_var "CI_MERGE_REQUEST_SOURCE_BRANCH_NAME"
check_required_var "CI_MERGE_REQUEST_TARGET_BRANCH_NAME"
check_required_var "CI_PROJECT_ID"
check_required_var "CI_SERVER_HOST"
check_required_var "CI_PROJECT_PATH"
check_required_var "MAINTAINER_PAT_VALUE"
check_required_var "CI_DEFAULT_BRANCH"

print_status "$GREEN" "Starting MR branch compliance check (fullqa/develop)..."
print_status "$YELLOW" "Source: $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME → Target: $CI_MERGE_REQUEST_TARGET_BRANCH_NAME"

git fetch --all --quiet
if [[ -n "${MAINTAINER_PAT_NAME:-}" ]]; then
    git config user.name "${MAINTAINER_PAT_NAME}"
fi
if [[ -n "${MAINTAINER_PAT_USER_NAME:-}" ]]; then
    git config user.email "${MAINTAINER_PAT_USER_NAME}@noreply.${CI_SERVER_HOST}"
fi

# Use CI_COMMIT_SHA (commit that triggered this pipeline) to avoid race condition:
# if a user pushes a new commit while this pipeline runs, we must verify THIS commit, not the latest.
SOURCE_BRANCH_SHA="${CI_COMMIT_SHA}"
if ! git rev-parse --verify "$SOURCE_BRANCH_SHA" >/dev/null 2>&1; then
    print_status "$RED" "Error: Commit $SOURCE_BRANCH_SHA (CI_COMMIT_SHA) not found in repository"
    exit 1
fi

# Save current branch/HEAD for later restoration (package check)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")

# Package check settings (identical to PRD)
PACKAGE_CHECK_STAGE="deploy"
PACKAGE_CHECK_ENVIRONMENT="production"
PACKAGE_XML_PATH="manifest/package.xml"
PACKAGE_CHECK_SCRIPT="scripts/python/package_check.py"
PACKAGE_CHECK_STATUS=""
PACKAGE_CHECK_OUTPUT=""
PACKAGE_CHECK_WARNINGS=""

# Branch age relative to main (default branch)
# Returns: "status|age_days|merge_base_sha"
# source_rev: commit SHA (e.g. CI_COMMIT_SHA)
check_branch_age() {
    local source_rev=$1
    local default_branch=$2
    local max_age_days=${3:-30}

    local merge_base_sha
    merge_base_sha=$(git merge-base "$source_rev" "origin/$default_branch" 2>/dev/null || echo "")
    if [[ -z "$merge_base_sha" ]]; then
        echo "error|0|"
        return
    fi

    local commit_timestamp
    commit_timestamp=$(git log -1 --format="%ct" "$merge_base_sha" 2>/dev/null || echo "")
    if [[ -z "$commit_timestamp" ]]; then
        echo "error|0|$merge_base_sha"
        return
    fi

    local current_timestamp
    current_timestamp=$(date -u +%s 2>/dev/null || date +%s 2>/dev/null || echo "")
    if [[ -z "$current_timestamp" ]]; then
        echo "error|0|$merge_base_sha"
        return
    fi

    local age_seconds=$((current_timestamp - commit_timestamp))
    local age_days=$((age_seconds / 86400))
    local status="recent"
    [[ $age_days -gt $max_age_days ]] && status="old"
    echo "$status|$age_days|$merge_base_sha"
}

# Forbidden merges: fullqa/develop merged INTO source branch
# Returns: "status|offending_commits"
# source_rev: commit SHA (e.g. CI_COMMIT_SHA)
check_forbidden_merges() {
    local source_rev=$1
    local default_branch=$2
    local forbidden_branches=("fullqa" "develop")
    local offending_commits=()

    for forbidden_branch in "${forbidden_branches[@]}"; do
        local matching_commits
        matching_commits=$(git log --format="%H" --merges --grep="[Mm]erge.*$forbidden_branch.*into\|[Mm]erge.*origin/$forbidden_branch.*into\|[Mm]erge.*branch.*['\"]$forbidden_branch.*into" "origin/$default_branch..$source_rev" 2>/dev/null || echo "")
        if [[ -n "$matching_commits" ]]; then
            while IFS= read -r commit; do
                [[ -n "$commit" ]] && offending_commits+=("$commit")
            done <<< "$matching_commits"
        fi
    done

    if [[ ${#offending_commits[@]} -gt 0 ]]; then
        echo "forbidden_merge|$(IFS=','; echo "${offending_commits[*]}")"
    else
        echo "clean|"
    fi
}

# Detect whether source commit was created from main vs develop/fullqa.
# Only considers NEW commits on the source branch (main..source) to avoid false
# positives when main has old merge commits from develop/fullqa in its history.
# We branched from develop/fullqa iff the source has commits from that branch
# that main does NOT have (i.e. merge-base(source, develop) is not in main).
# Returns: "main" | "develop" | "fullqa" | "unknown"
# source_rev: commit SHA (e.g. CI_COMMIT_SHA)
check_branch_origin() {
    local source_rev=$1
    local default_branch=$2
    local main_ref="origin/$default_branch"

    # Branch point: where source diverged from main
    local base_main
    base_main=$(git merge-base "$source_rev" "$main_ref" 2>/dev/null || echo "")
    [[ -z "$base_main" ]] && echo "unknown" && return

    # Check develop: we branched from develop iff source has develop commits that main doesn't have.
    # merge-base(source, develop) not ancestor of main => we have develop-specific history.
    if git show-ref --verify --quiet "refs/remotes/origin/develop" 2>/dev/null; then
        local base_dev
        base_dev=$(git merge-base "$source_rev" "origin/develop" 2>/dev/null || echo "")
        if [[ -n "$base_dev" ]] && ! git merge-base --is-ancestor "$base_dev" "$main_ref" 2>/dev/null; then
            echo "develop"
            return
        fi
    fi

    # Check fullqa: same logic
    if git show-ref --verify --quiet "refs/remotes/origin/fullqa" 2>/dev/null; then
        local base_fq
        base_fq=$(git merge-base "$source_rev" "origin/fullqa" 2>/dev/null || echo "")
        if [[ -n "$base_fq" ]] && ! git merge-base --is-ancestor "$base_fq" "$main_ref" 2>/dev/null; then
            echo "fullqa"
            return
        fi
    fi

    echo "main"
}

# Branch name: valid Jira project key (same as main script)
check_branch_name() {
    local branch_name=$1
    local branch_lower
    branch_lower=$(echo "$branch_name" | tr '[:upper:]' '[:lower:]')
    if [[ "$branch_lower" == *"bar"* ]]; then
        echo "invalid_bar"
        return
    fi
    local valid_keys=("q2c" "storm" "shield" "sfxpro" "leadz" "avatechtdr" "catalyst")
    for key in "${valid_keys[@]}"; do
        if [[ "$branch_lower" == *"$key"* ]]; then
            echo "valid"
            return
        fi
    done
    echo "invalid_no_key"
}

# ---- Run checks (reference branch = main / default) ----
MAIN_BRANCH="$CI_DEFAULT_BRANCH"

print_status "$YELLOW" "Checking branch age relative to $MAIN_BRANCH..."
BRANCH_AGE_RESULT=$(check_branch_age "$SOURCE_BRANCH_SHA" "$MAIN_BRANCH" 30)
BRANCH_AGE_STATUS=$(echo "$BRANCH_AGE_RESULT" | cut -d'|' -f1)
BRANCH_AGE_DAYS=$(echo "$BRANCH_AGE_RESULT" | cut -d'|' -f2)

if [[ "$BRANCH_AGE_STATUS" == "recent" ]]; then
    print_status "$GREEN" "✓ Source branch is recent (from $MAIN_BRANCH $BRANCH_AGE_DAYS days ago)"
elif [[ "$BRANCH_AGE_STATUS" == "old" ]]; then
    print_status "$RED" "✗ Source branch is old (from $MAIN_BRANCH $BRANCH_AGE_DAYS days ago)"
else
    print_status "$YELLOW" "⚠ Could not determine branch age"
fi

print_status "$YELLOW" "Checking branch name for valid Jira project key..."
BRANCH_NAME_STATUS=$(check_branch_name "$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME")
if [[ "$BRANCH_NAME_STATUS" == "valid" ]]; then
    print_status "$GREEN" "✓ Branch name contains valid Jira project key"
elif [[ "$BRANCH_NAME_STATUS" == "invalid_bar" ]]; then
    print_status "$RED" "✗ Branch name contains BAR"
else
    print_status "$RED" "✗ Branch name missing valid Jira key (q2c, storm, shield, sfxpro, leadz, catalyst, avatechtdr)"
fi

print_status "$YELLOW" "Checking for forbidden merges (fullqa/develop into source)..."
FORBIDDEN_RESULT=$(check_forbidden_merges "$SOURCE_BRANCH_SHA" "$MAIN_BRANCH")
FORBIDDEN_STATUS=$(echo "$FORBIDDEN_RESULT" | cut -d'|' -f1)
FORBIDDEN_COMMITS=$(echo "$FORBIDDEN_RESULT" | cut -d'|' -f2)

if [[ "$FORBIDDEN_STATUS" == "clean" ]]; then
    print_status "$GREEN" "✓ No merges from fullqa/develop into source branch"
elif [[ "$FORBIDDEN_STATUS" == "forbidden_merge" ]]; then
    print_status "$RED" "✗ Source branch contains merge(s) from fullqa/develop"
    [[ -n "$FORBIDDEN_COMMITS" ]] && print_status "$RED" "  Commit(s): $FORBIDDEN_COMMITS"
else
    print_status "$YELLOW" "⚠ Could not check for forbidden merges"
fi

print_status "$YELLOW" "Checking if branch was created from $MAIN_BRANCH (not develop/fullqa)..."
BRANCH_ORIGIN=$(check_branch_origin "$SOURCE_BRANCH_SHA" "$MAIN_BRANCH")
if [[ "$BRANCH_ORIGIN" == "main" ]]; then
    print_status "$GREEN" "✓ Branch was created from $MAIN_BRANCH"
elif [[ "$BRANCH_ORIGIN" == "develop" ]]; then
    print_status "$RED" "✗ Branch was created from develop (not $MAIN_BRANCH). Re-create from $MAIN_BRANCH."
elif [[ "$BRANCH_ORIGIN" == "fullqa" ]]; then
    print_status "$RED" "✗ Branch was created from fullqa (not $MAIN_BRANCH). Re-create from $MAIN_BRANCH."
else
    print_status "$YELLOW" "⚠ Could not determine branch origin"
fi

# ============================================================================
# PACKAGE.XML CHECK (identical to PRD)
# ============================================================================
print_status "$YELLOW" ""
print_status "$YELLOW" "=== Running Package.xml Compliance Check ==="

print_status "$YELLOW" "Checking out latest commit on source branch ($SOURCE_BRANCH_SHA) for package check..."
if ! git rev-parse --verify "$SOURCE_BRANCH_SHA" >/dev/null 2>&1; then
    print_status "$RED" "Error: Source branch commit $SOURCE_BRANCH_SHA no longer available"
    git checkout -q "$CURRENT_BRANCH" 2>/dev/null || true
    exit 1
fi

if ! git checkout -q "$SOURCE_BRANCH_SHA" 2>/dev/null; then
    print_status "$RED" "Error: Could not checkout source branch commit $SOURCE_BRANCH_SHA"
    git checkout -q "$CURRENT_BRANCH" 2>/dev/null || true
    exit 1
fi

CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_SHA" != "$SOURCE_BRANCH_SHA" ]]; then
    print_status "$RED" "Error: Failed to checkout source branch commit. Expected $SOURCE_BRANCH_SHA, got $CURRENT_SHA"
    git checkout -q "$CURRENT_BRANCH" 2>/dev/null || true
    exit 1
fi
print_status "$GREEN" "✓ Checked out source branch commit $SOURCE_BRANCH_SHA"

if [[ ! -f "$PACKAGE_XML_PATH" ]]; then
    print_status "$RED" "✗ Package.xml not found at $PACKAGE_XML_PATH"
    PACKAGE_CHECK_STATUS="error"
    PACKAGE_CHECK_OUTPUT="Package.xml file not found"
else
    print_status "$YELLOW" "Found package.xml at $PACKAGE_XML_PATH"
    if [[ ! -f "$PACKAGE_CHECK_SCRIPT" ]]; then
        print_status "$RED" "✗ Package check script not found at $PACKAGE_CHECK_SCRIPT"
        PACKAGE_CHECK_STATUS="error"
        PACKAGE_CHECK_OUTPUT="Package check script not found"
    elif ! command -v python3 &> /dev/null; then
        print_status "$RED" "✗ python3 not found in PATH"
        PACKAGE_CHECK_STATUS="error"
        PACKAGE_CHECK_OUTPUT="python3 not available"
    else
        print_status "$YELLOW" "Running package_check.py..."
        PACKAGE_CHECK_OUTPUT=$(python3 "$PACKAGE_CHECK_SCRIPT" \
            -x "$PACKAGE_XML_PATH" \
            -s "$PACKAGE_CHECK_STAGE" \
            -e "$PACKAGE_CHECK_ENVIRONMENT" 2>&1)
        PACKAGE_CHECK_EXIT_CODE=$?
        PACKAGE_CHECK_WARNINGS=$(echo "$PACKAGE_CHECK_OUTPUT" | grep -i "WARNING:" || echo "")

        if [[ $PACKAGE_CHECK_EXIT_CODE -eq 0 ]]; then
            print_status "$GREEN" "✓ Package.xml compliance check passed"
            PACKAGE_CHECK_STATUS="success"
        else
            print_status "$RED" "✗ Package.xml compliance check failed"
            PACKAGE_CHECK_STATUS="failed"
        fi
    fi
fi

print_status "$YELLOW" "Restoring original branch position..."
git checkout -q "$CURRENT_BRANCH" 2>/dev/null || true

# Predeploy job check: test:predeploy:fullqa or test:predeploy:dev depending on MR target
CI_SERVER_HOST_CLEAN="${CI_SERVER_HOST%/}"

check_deployment_job_status() {
    local commit_sha=$1
    local job_name=$2
    local access_token=$3
    local project_id=$4
    local server_host=$5
    [[ -z "$commit_sha" ]] && echo "unknown" && return
    local server_host_clean="${server_host%/}"
    local api_url="https://${server_host_clean}/api/v4/projects/${project_id}/pipelines"
    local pipelines_response
    pipelines_response=$(curl -s -w "\n%{http_code}" -H "PRIVATE-TOKEN: ${access_token}" "${api_url}?sha=${commit_sha}&per_page=10" 2>/dev/null)
    local pipelines_body=$(echo "$pipelines_response" | sed '$d')
    local pipelines_status=$(echo "$pipelines_response" | tail -n1)
    if [[ "$pipelines_status" -lt 200 || "$pipelines_status" -ge 300 ]]; then
        echo "api_error"
        return
    fi
    if command -v jq &> /dev/null; then
        local pipeline_count
        pipeline_count=$(echo "$pipelines_body" | jq 'length' 2>/dev/null || echo "0")
        [[ "$pipeline_count" -eq 0 ]] && echo "no_pipeline" && return
        local pipeline_index=0
        local job_status=""
        while [[ $pipeline_index -lt $pipeline_count && $pipeline_index -lt 10 ]]; do
            local pipeline_id
            pipeline_id=$(echo "$pipelines_body" | jq -r ".[$pipeline_index].id // empty" 2>/dev/null)
            if [[ -n "$pipeline_id" ]]; then
                local jobs_url="https://${server_host_clean}/api/v4/projects/${project_id}/pipelines/${pipeline_id}/jobs"
                local jobs_response
                jobs_response=$(curl -s -w "\n%{http_code}" -H "PRIVATE-TOKEN: ${access_token}" "$jobs_url" 2>/dev/null)
                local jobs_body=$(echo "$jobs_response" | sed '$d')
                local jobs_status=$(echo "$jobs_response" | tail -n1)
                if [[ "$jobs_status" -ge 200 && "$jobs_status" -lt 300 ]]; then
                    job_status=$(echo "$jobs_body" | jq -r ".[] | select(.name == \"${job_name}\") | .status // empty" 2>/dev/null)
                    if [[ -n "$job_status" ]]; then
                        echo "$job_status"
                        return
                    fi
                fi
            fi
            pipeline_index=$((pipeline_index + 1))
        done
        echo "job_not_found"
    else
        echo "$pipelines_body" | grep -q '"id"' && echo "unknown" || echo "no_pipeline"
    fi
}

if [[ "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" == "fullqa" ]]; then
    PREDEPLOY_JOB_NAME="test:predeploy:fullqa"
else
    PREDEPLOY_JOB_NAME="test:predeploy:dev"
fi

print_status "$YELLOW" "Checking predeploy job ($PREDEPLOY_JOB_NAME) for source branch commit..."
PREDEPLOY_SBX_STATUS=$(check_deployment_job_status "$SOURCE_BRANCH_SHA" "$PREDEPLOY_JOB_NAME" "$MAINTAINER_PAT_VALUE" "$CI_PROJECT_ID" "$CI_SERVER_HOST_CLEAN")

if [[ "$PREDEPLOY_SBX_STATUS" == "success" ]]; then
    print_status "$GREEN" "✓ Predeploy ($PREDEPLOY_JOB_NAME) passed"
elif [[ "$PREDEPLOY_SBX_STATUS" == "failed" ]]; then
    print_status "$RED" "✗ Predeploy ($PREDEPLOY_JOB_NAME) failed"
elif [[ "$PREDEPLOY_SBX_STATUS" == "running" || "$PREDEPLOY_SBX_STATUS" == "pending" ]]; then
    print_status "$YELLOW" "⏳ Predeploy ($PREDEPLOY_JOB_NAME) in progress"
elif [[ "$PREDEPLOY_SBX_STATUS" == "job_not_found" ]]; then
    print_status "$YELLOW" "⚠ Predeploy ($PREDEPLOY_JOB_NAME) job not found"
elif [[ "$PREDEPLOY_SBX_STATUS" == "no_pipeline" ]]; then
    print_status "$YELLOW" "⚠ Predeploy ($PREDEPLOY_JOB_NAME) - no pipeline found"
elif [[ "$PREDEPLOY_SBX_STATUS" == "api_error" ]]; then
    print_status "$YELLOW" "⚠ Predeploy ($PREDEPLOY_JOB_NAME) - API error"
else
    print_status "$YELLOW" "? Predeploy ($PREDEPLOY_JOB_NAME) status unknown ($PREDEPLOY_SBX_STATUS)"
fi

# ---- Build comment body ----
# Use pipeline trigger user for @-mention (GitLab notifies mentioned users)
# GITLAB_USER_LOGIN: username of user who started the pipeline (or manual job)
NOTIFY_USER="${GITLAB_USER_LOGIN:-}"

COMMENT_BODY="## MR Branch Compliance (fullqa/develop)

**Source Branch:** \`$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME\` **Source SHA:** \`${SOURCE_BRANCH_SHA:0:8}\` **Target Branch:** \`$CI_MERGE_REQUEST_TARGET_BRANCH_NAME\`

### Compliance

"

if [[ "$BRANCH_NAME_STATUS" == "valid" ]]; then
    COMMENT_BODY+="- :white_check_mark: **Branch Name**: Valid Jira project key"$'\n'
elif [[ "$BRANCH_NAME_STATUS" == "invalid_bar" ]]; then
    COMMENT_BODY+="- :x: **Branch Name**: Contains BAR (release team project)"$'\n'
else
    COMMENT_BODY+="- :x: **Branch Name**: Missing valid Jira key (q2c, storm, shield, sfxpro, leadz, avatechtdr, catalyst)"$'\n'
fi

if [[ "$BRANCH_AGE_STATUS" == "recent" ]]; then
    COMMENT_BODY+="- :white_check_mark: **Branch from $MAIN_BRANCH**: Created $BRANCH_AGE_DAYS days ago (within 30 days)"$'\n'
elif [[ "$BRANCH_AGE_STATUS" == "old" ]]; then
    COMMENT_BODY+="- :x: **Branch from $MAIN_BRANCH**: Created $BRANCH_AGE_DAYS days ago (over 30 days; consider rebasing)"$'\n'
else
    COMMENT_BODY+="- :warning: **Branch from $MAIN_BRANCH**: Could not determine age"$'\n'
fi

if [[ "$BRANCH_ORIGIN" == "main" ]]; then
    COMMENT_BODY+="- :white_check_mark: **Created from $MAIN_BRANCH**: Branch was created from $MAIN_BRANCH (not develop/fullqa)"$'\n'
elif [[ "$BRANCH_ORIGIN" == "develop" ]]; then
    COMMENT_BODY+="- :x: **Created from $MAIN_BRANCH**: Branch was created from **develop** (not $MAIN_BRANCH). Re-create your branch from $MAIN_BRANCH."$'\n'
elif [[ "$BRANCH_ORIGIN" == "fullqa" ]]; then
    COMMENT_BODY+="- :x: **Created from $MAIN_BRANCH**: Branch was created from **fullqa** (not $MAIN_BRANCH). Re-create your branch from $MAIN_BRANCH."$'\n'
else
    COMMENT_BODY+="- :warning: **Created from $MAIN_BRANCH**: Could not determine if branch was created from $MAIN_BRANCH"$'\n'
fi

if [[ "$FORBIDDEN_STATUS" == "clean" ]]; then
    COMMENT_BODY+="- :white_check_mark: **No fullqa/develop merges**: Source does not merge fullqa or develop"$'\n'
elif [[ "$FORBIDDEN_STATUS" == "forbidden_merge" ]]; then
    commit_list=""
    IFS=',' read -ra COMMITS <<< "$FORBIDDEN_COMMITS"
    for c in "${COMMITS[@]}"; do
        [[ -n "$commit_list" ]] && commit_list+=", "
        commit_list+="\`${c:0:8}\`"
    done
    COMMENT_BODY+="- :x: **No fullqa/develop merges**: Source contains merge(s) from fullqa/develop ($commit_list)"$'\n'
else
    COMMENT_BODY+="- :warning: **No fullqa/develop merges**: Check could not be run"$'\n'
fi

# Predeploy validation (test:predeploy:fullqa or test:predeploy:dev)
if [[ "$PREDEPLOY_SBX_STATUS" == "success" ]]; then
    COMMENT_BODY+="- :white_check_mark: **Predeploy ($PREDEPLOY_JOB_NAME)**: Job passed"$'\n'
elif [[ "$PREDEPLOY_SBX_STATUS" == "failed" ]]; then
    COMMENT_BODY+="- :x: **Predeploy ($PREDEPLOY_JOB_NAME)**: Job failed"$'\n'
elif [[ "$PREDEPLOY_SBX_STATUS" == "running" || "$PREDEPLOY_SBX_STATUS" == "pending" ]]; then
    COMMENT_BODY+="- :hourglass: **Predeploy ($PREDEPLOY_JOB_NAME)**: In progress"$'\n'
elif [[ "$PREDEPLOY_SBX_STATUS" == "job_not_found" ]]; then
    COMMENT_BODY+="- :warning: **Predeploy ($PREDEPLOY_JOB_NAME)**: Job not found"$'\n'
elif [[ "$PREDEPLOY_SBX_STATUS" == "no_pipeline" ]]; then
    COMMENT_BODY+="- :warning: **Predeploy ($PREDEPLOY_JOB_NAME)**: No pipeline found"$'\n'
elif [[ "$PREDEPLOY_SBX_STATUS" == "api_error" ]]; then
    COMMENT_BODY+="- :warning: **Predeploy ($PREDEPLOY_JOB_NAME)**: API error"$'\n'
else
    COMMENT_BODY+="- :question: **Predeploy ($PREDEPLOY_JOB_NAME)**: Status unknown ($PREDEPLOY_SBX_STATUS)"$'\n'
fi

# Package.xml compliance (identical to PRD)
if [[ "$PACKAGE_CHECK_STATUS" == "success" ]]; then
    TEST_CLASSES=$(echo "$PACKAGE_CHECK_OUTPUT" | tail -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo "")
    if [[ -n "$PACKAGE_CHECK_WARNINGS" ]]; then
        TEST_ANNOTATION_WARNINGS=$(echo "$PACKAGE_CHECK_WARNINGS" | grep -i "test annotation\|test class" || echo "")
        if [[ -n "$TEST_CLASSES" && "$TEST_CLASSES" != "not a test" && "$TEST_CLASSES" != *"ERROR"* && "$TEST_CLASSES" != *"Apex Tests"* ]]; then
            [[ ${#TEST_CLASSES} -gt 100 ]] && COMMENT_BODY+="- :white_check_mark: **Package.xml Compliance**: Check passed (Test classes: \`${TEST_CLASSES:0:97}...\`)"$'\n' || COMMENT_BODY+="- :white_check_mark: **Package.xml Compliance**: Check passed (Test classes: \`$TEST_CLASSES\`)"$'\n'
        else
            COMMENT_BODY+="- :white_check_mark: **Package.xml Compliance**: Check passed"$'\n'
        fi
        if [[ -n "$TEST_ANNOTATION_WARNINGS" ]]; then
            WARNINGS_LIST=""
            while IFS= read -r warning; do
                CLEAN_WARNING=$(echo "$warning" | sed 's/^[[:space:]]*WARNING:[[:space:]]*//i' | cut -c1-150)
                [[ -n "$CLEAN_WARNING" ]] && { [[ -n "$WARNINGS_LIST" ]] && WARNINGS_LIST+=$'\n'; WARNINGS_LIST+="    - \`$CLEAN_WARNING\`"; }
            done <<< "$TEST_ANNOTATION_WARNINGS"
            COMMENT_BODY+="  - :warning: **Test Annotation Warnings**: "$'\n'"$WARNINGS_LIST"$'\n'
        fi
        OTHER_WARNINGS=$(echo "$PACKAGE_CHECK_WARNINGS" | grep -vi "test annotation\|test class" || echo "")
        if [[ -n "$OTHER_WARNINGS" ]]; then
            WARNINGS_LIST=""
            while IFS= read -r warning; do
                CLEAN_WARNING=$(echo "$warning" | sed 's/^[[:space:]]*WARNING:[[:space:]]*//i' | cut -c1-150)
                [[ -n "$CLEAN_WARNING" ]] && { [[ -n "$WARNINGS_LIST" ]] && WARNINGS_LIST+=$'\n'; WARNINGS_LIST+="    - \`$CLEAN_WARNING\`"; }
            done <<< "$OTHER_WARNINGS"
            COMMENT_BODY+="  - :warning: **Other Warnings**: "$'\n'"$WARNINGS_LIST"$'\n'
        fi
    else
        if [[ -n "$TEST_CLASSES" && "$TEST_CLASSES" != "not a test" && "$TEST_CLASSES" != *"ERROR"* && "$TEST_CLASSES" != *"Apex Tests"* ]]; then
            [[ ${#TEST_CLASSES} -gt 100 ]] && COMMENT_BODY+="- :white_check_mark: **Package.xml Compliance**: Check passed (Test classes: \`${TEST_CLASSES:0:97}...\`)"$'\n' || COMMENT_BODY+="- :white_check_mark: **Package.xml Compliance**: Check passed (Test classes: \`$TEST_CLASSES\`)"$'\n'
        else
            COMMENT_BODY+="- :white_check_mark: **Package.xml Compliance**: Check passed"$'\n'
        fi
    fi
elif [[ "$PACKAGE_CHECK_STATUS" == "failed" ]]; then
    ERROR_MSG=$(echo "$PACKAGE_CHECK_OUTPUT" | grep -i "ERROR" | head -1 | cut -c1-200 || echo "Package.xml compliance check failed")
    COMMENT_BODY+="- :x: **Package.xml Compliance**: Check failed - $ERROR_MSG"$'\n'
elif [[ "$PACKAGE_CHECK_STATUS" == "error" ]]; then
    ERROR_DISPLAY=$(echo "$PACKAGE_CHECK_OUTPUT" | cut -c1-200 || echo "$PACKAGE_CHECK_OUTPUT")
    COMMENT_BODY+="- :warning: **Package.xml Compliance**: Could not perform check - $ERROR_DISPLAY"$'\n'
else
    COMMENT_BODY+="- :warning: **Package.xml Compliance**: Check status unknown"$'\n'
fi

COMMENT_BODY+=$'\n'"---"$'\n'
COMMENT_BODY+="*Automated compliance check for fullqa/develop MRs. Fix non-compliant checks before merging to main/production.*"
if [[ -n "$NOTIFY_USER" ]]; then
    COMMENT_BODY+=$'\n\n'"cc @${NOTIFY_USER}"
fi

# ---- GitLab API: delete previous compliance comments, then post ----
# Target by comment header only so this works when the bot token/user changes.
API_URL="https://${CI_SERVER_HOST_CLEAN}/api/v4/projects/${CI_PROJECT_ID}/merge_requests/${CI_MERGE_REQUEST_IID}/notes"

print_status "$YELLOW" "Checking for previous compliance comments to delete..."
NOTES_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
    "${API_URL}?per_page=100" 2>&1)
NOTES_BODY=$(echo "$NOTES_RESPONSE" | sed '$d')
NOTES_STATUS=$(echo "$NOTES_RESPONSE" | tail -n1)

if [[ "$NOTES_STATUS" -ge 200 && "$NOTES_STATUS" -lt 300 ]] && command -v jq &> /dev/null; then
    NOTE_IDS=$(echo "$NOTES_BODY" | jq -r '.[] | select(.body | contains("MR Branch Compliance (fullqa/develop)")) | .id' 2>/dev/null | tr -d '\r' || true)
    if [[ -n "$NOTE_IDS" ]]; then
        while IFS= read -r note_id; do
            note_id=$(echo "$note_id" | tr -d '\r')
            if [[ -n "$note_id" && "$note_id" != "null" ]]; then
                curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" "${API_URL}/${note_id}" || true
            fi
        done <<< "$NOTE_IDS"
    fi
fi

print_status "$YELLOW" "Posting compliance comment..."
if command -v jq &> /dev/null; then
    JSON_PAYLOAD=$(jq -n --arg body "$COMMENT_BODY" '{body: $body}')
else
    ESCAPED_BODY=$(printf '%s' "$COMMENT_BODY" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/\r/\\r/g')
    JSON_PAYLOAD="{\"body\":\"$ESCAPED_BODY\"}"
fi

HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD" \
    "$API_URL" 2>&1)
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)

if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
    print_status "$GREEN" "✓ Comment posted successfully"
else
    print_status "$RED" "✗ Failed to post comment (HTTP $HTTP_STATUS)"
    exit 1
fi

print_status "$GREEN" "MR branch compliance check complete."
exit 0

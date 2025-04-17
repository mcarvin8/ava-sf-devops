#!/bin/bash
# automates the completion of a merge request from the source branch into the target branch from a CI pipeline
# if there are merge conflicts, the source branch file version will be used
set -e

# Attempt auto-merge preferring source content when possible
git merge --no-ff -X theirs --no-commit origin/$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME || true

# Manually resolve remaining conflicts: always favor the source branch (theirs)
git ls-files -u | cut -f2 | sort -u | while read -r file; do
    git checkout --theirs "$file" 2>/dev/null || {
        echo "No 'theirs' version for '$file', assuming it was deleted in source."
        git rm -f "$file"
    }
    git add "$file" 2>/dev/null || true
done

# Extract package info from merge request description
PACKAGE_LIST=$(echo "$CI_MERGE_REQUEST_DESCRIPTION" | sed -n '/<Package>/,/<\/Package>/p')

# Create commit message
COMMIT_MSG="Merge remote-tracking branch 'origin/$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME' into $CI_MERGE_REQUEST_TARGET_BRANCH_NAME. Triggered by: $GITLAB_USER_NAME"
if [[ -n "$PACKAGE_LIST" ]]; then
    COMMIT_MSG+="

Packages list in this merge request:
$PACKAGE_LIST"
fi

git commit -m "$COMMIT_MSG"
git push "https://${PAT_NAME}:${PAT_VALUE}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"

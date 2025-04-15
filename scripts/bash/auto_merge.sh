#!/bin/bash
# automates the completion of a merge request from the source branch into the target branch from a CI pipeline
# if there are merge conflicts, the source branch file version will be used
set -e

# Must fetch before checking out branches
git fetch -q
git config user.name "${PAT_NAME}"
git config user.email "${PAT_USER_NAME}@noreply.${CI_SERVER_HOST}"

git checkout -q $CI_MERGE_REQUEST_TARGET_BRANCH_NAME
git pull --ff -q

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

git commit -m "Merge remote-tracking branch 'origin/$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME' into $CI_MERGE_REQUEST_TARGET_BRANCH_NAME. Triggered by: $GITLAB_USER_NAME"

# Push changes to remote
git push "https://${PAT_NAME}:${PAT_VALUE}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"

# Cleanup, switch back to the SHA that triggered this pipeline and delete local branches
git -c advice.detachedHead=false checkout -q $CI_COMMIT_SHORT_SHA
git branch -D $CI_MERGE_REQUEST_TARGET_BRANCH_NAME

#!/bin/bash
set -e
# Push commits on `main` branch back to other org branches
# Only needed if you create branches from `main` branch but have to merge them into other long-running branches.

function accept_incoming_changes_merge() {
    # check if there are any merge conflicts
    if [[ $(git status | grep "Unmerged paths:") ]]; then
        echo "Merge conflicts detected. Resolving automatically by accepting all incoming changes on the below files:"
        # loop through all files with merge conflicts and accept incoming changes
        while IFS= read -r -d '' file; do
            echo "$file"
            git checkout --theirs "$file"
            git add "$file"
        done < <(git diff --name-only --diff-filter=U -z)
        git commit -m "Merge remote-tracking branch 'origin/main' into $1"
    fi
}

# Update the sandbox branches with changes from production
for branch_name in fqa dev
do
    git checkout -q $branch_name
    git pull --ff -q
    # Merge changes from main branch, ignoring merge conflict errors
    git merge --no-ff origin/main || true
    accept_incoming_changes_merge "$branch_name"
    # Push changes to remote, skipping CI pipeline
    git push "https://${PAT_NAME}:${PAT_VALUE}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" -o ci.skip
done

# Cleanup, switch back to the SHA that triggered this pipeline and delete local branches
git -c advice.detachedHead=false checkout -q $CI_COMMIT_SHORT_SHA
git branch -D fullqa
git branch -D develop

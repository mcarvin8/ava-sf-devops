#!/bin/bash
set -e

function handle_delete_conflicts() {
    # Manually resolve remaining conflicts: always favor the source branch (theirs)
    git ls-files -u | cut -f2 | sort -u | while read -r file; do
        git checkout --theirs "$file" 2>/dev/null || {
            echo "No 'theirs' version for '$file', assuming it was deleted in source."
            git rm -f "$file"
        }
        git add "$file" 2>/dev/null || true
    done
}

# Update the sandbox branches with changes from production
for branch_name in fqa dev
do
    git checkout -q $branch_name
    git pull --ff -q
    # Merge changes from the default branch, using "theirs" strategy to deal with conflicts
    git merge --no-ff -X theirs --no-commit origin/$CI_DEFAULT_BRANCH || true
    handle_delete_conflicts
    git commit -m "Merge remote-tracking branch 'origin/$CI_DEFAULT_BRANCH' into $branch_name"
    # Push changes to remote, skipping CI pipeline
    git push "https://${PAT_NAME}:${PAT_VALUE}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" -o ci.skip
done

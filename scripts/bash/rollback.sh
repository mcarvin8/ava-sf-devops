#!/bin/bash
set -e

function resolve_conflicts() {
    # check if there are any revert conflicts
    if [[ $(git status | grep "Unmerged paths:") ]]; then
        echo "Revert conflicts detected. Resolving automatically by accepting all current changes on the below files:"
        
        # loop through all files with revert conflicts and accept current branch changes (ours)
        while IFS= read -r -d '' file; do
            echo "$file"
            git checkout --ours "$file"
            git add "$file"
        done < <(git diff --name-only --diff-filter=U -z)

        # Continue the revert after resolving conflicts
        git revert --continue
    fi
}

if git merge-base --is-ancestor "$SHA" HEAD; then
  echo "SHA $SHA is valid in the current branch."
else
  echo "SHA $SHA is not valid in the current branch. Confirm SHA and run a new rollback pipeline."
  exit 1
fi

# Check if the commit is a merge commit - this command fails when it's not a merge commit, ignore the failure
IS_MERGE=$(git log --merges --pretty=format:"%H" | grep "$SHA" || true)

if [ -n "$IS_MERGE" ]; then
  echo "The commit $SHA is a merge commit."

  # Revert the merge commit with the first parent (-m 1)
  git revert -m 1 "$SHA" || true
else
  echo "The commit $SHA is a regular commit."

  # Revert the regular commit
  git revert "$SHA" || true
fi

resolve_conflicts

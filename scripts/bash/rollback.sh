#!/bin/bash
set -e

function check_commit_age() {
    COMMIT_TIMESTAMP=$(git show -s --format=%ct "$SHA")
    CURRENT_TIMESTAMP=$(date +%s)
    THREE_WEEKS_AGO=$(date -d '3 weeks ago' +%s)

    if (( COMMIT_TIMESTAMP < THREE_WEEKS_AGO )); then
        echo "SHA $SHA is older than 3 weeks. Rollbacks are only allowed for SHAs made in the past 3 weeks."
        exit 1
    fi
}

if git merge-base --is-ancestor "$SHA" HEAD; then
  echo "SHA $SHA is valid in the current branch."
else
  echo "SHA $SHA is not valid in the current branch. Confirm SHA and run a new rollback pipeline."
  exit 1
fi

check_commit_age

# Check if the commit is a merge commit - this command fails when it's not a merge commit, ignore the failure
IS_MERGE=$(git log --merges --pretty=format:"%H" | grep "$SHA" || true)

if [ -n "$IS_MERGE" ]; then
  echo "SHA $SHA is a merge commit."

  # Revert the merge commit with the first parent (-m 1)
  git revert -X ours --no-commit -m 1 "$SHA" || true
else
  echo "SHA $SHA is a regular commit."

  # Revert the regular commit
  git revert -X ours --no-commit "$SHA" || true
fi

# Commit changes
git commit -m "Reverts changes of $SHA, Triggered by: $GITLAB_USER_NAME"

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

git fetch -q
git config user.name "${BOT_NAME}"
git config user.email "${BOT_USER_NAME}@noreply.${CI_SERVER_HOST}"
git checkout -q $CI_COMMIT_BRANCH
git pull --ff -q

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

# NOT NEEDED IF YOU USE SFDX-GIT-DELTA TO CREATE A PACKAGE.XML
# Re-insert the commit's package.xml to re-deploy the correct package
#git checkout $SHA -- manifest/package.xml
#git add manifest/package.xml
# ignore this failure if the package isn't different
# git commit -m "Revert changes of $SHA and redeploy the package." || true

# Push changes to remote
git push "https://${BOT_NAME}:${PROJECT_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"

# Cleanup
git -c advice.detachedHead=false checkout -q $CI_COMMIT_SHORT_SHA
git branch -D $CI_COMMIT_BRANCH

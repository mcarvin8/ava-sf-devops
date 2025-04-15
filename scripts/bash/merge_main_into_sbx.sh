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

# Must fetch before checking out fullqa and develop branches
# Configure bot user name and bot user email address - https://scm.platform.us-west-2.avalara.io/help/user/project/settings/project_access_tokens
# Bot Email Address template: project_{project_id}_bot_{random_string}@noreply.{Gitlab.config.gitlab.host}
git fetch -q
git config user.name "${MAINTAINER_PAT_NAME}"
git config user.email "${MAINTAINER_PAT_USER_NAME}@noreply.${CI_SERVER_HOST}"

# Update the sandbox branches with changes from production
for branch_name in fqa dev
do
    git checkout -q $branch_name
    git pull --ff -q
    # Merge changes from main branch, using "theirs" strategy to deal with conflicts
    git merge --no-ff -X theirs --no-commit origin/main || true
    handle_delete_conflicts
    git commit -m "Merge remote-tracking branch 'origin/main' into $branch_name"
    # Push changes to remote, skipping CI pipeline
    git push "https://${PAT_NAME}:${PAT_VALUE}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" -o ci.skip
done

# Cleanup, switch back to the SHA that triggered this pipeline and delete local branches
git -c advice.detachedHead=false checkout -q $CI_COMMIT_SHORT_SHA
git branch -D fqa
git branch -D dev

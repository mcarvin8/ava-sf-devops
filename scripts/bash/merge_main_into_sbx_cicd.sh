#!/bin/bash
set -e
# CI/CD Variables to Set in Repo:
# $BOT_NAME = name of the project access token/bot user - ex: JARVIS
# $BOT_USER_NAME = user name for the project access token bot user - ex: project_{project_id}_bot_{random_string}
# $PROJECT_TOKEN = project access token passphrase

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

# Must fetch before checking out fullqa and develop branches
# Configure bot user name and bot user email address for this project access token
# Bot Email Address template: project_{project_id}_bot_{random_string}@noreply.{Gitlab.config.gitlab.host}
git reset --hard
git fetch
git config user.name "${BOT_NAME}"
git config user.email "${BOT_USER_NAME}@noreply.${CI_SERVER_HOST}"

# Update the sandbox branches with changes from production
for branch_name in fullqa develop
do
    git checkout $branch_name
    git pull --ff
    # Merge changes from main branch, ignoring merge conflict errors
    git merge --no-ff origin/main || true
    accept_incoming_changes_merge "$branch_name"
    # Push changes to remote, skipping CI pipeline
    git push "https://${BOT_NAME}:${PROJECT_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" -o ci.skip
done

# Cleanup, switch back to the SHA that triggered this pipeline and delete local branches
git checkout $CI_COMMIT_SHORT_SHA
git branch -D fullqa
git branch -D develop

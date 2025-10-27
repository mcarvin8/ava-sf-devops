#!/bin/bash
################################################################################
# Script: retrieve_packages_sbx.sh
# Description: Retrieves Salesforce metadata from sandbox environments (fullqa 
#              and develop) to their respective GitLab branches based on 
#              package.xml definitions. Commits and pushes changes, skipping CI
#              pipeline execution.
# Usage: Called from CI/CD pipeline
# Environment Variables Required:
#   - PACKAGE_NAME: XML file name from scripts/packages/ folder
#   - DEPLOY_TIMEOUT: Wait time for retrieval operation
#   - MAINTAINER_PAT_NAME, MAINTAINER_PAT_VALUE
#   - CI_COMMIT_SHORT_SHA
################################################################################
set -e

# Must fetch before checking out fullqa and develop branches
git fetch -q
git config user.name "${MAINTAINER_PAT_NAME}"
git config user.email "${MAINTAINER_PAT_USER_NAME}@noreply.${CI_SERVER_HOST}"

for branch_name in fullqa develop
do
    git checkout -q $branch_name
    git pull --ff -q
    # copy the package.xml to the manifest folder, overwriting the current package
    mkdir -p manifest
    cp -f "scripts/packages/$PACKAGE_NAME" "manifest/package.xml"
    echo "Retrieving metadata defined in $PACKAGE_NAME from $branch_name..."
    sf project retrieve start --manifest manifest/package.xml --target-org $branch_name --ignore-conflicts --wait $DEPLOY_TIMEOUT
    # Check if there are changes in the "force-app" folder
    if git diff --ignore-cr-at-eol --name-only | grep '^force-app/'; then
        echo "Changes found in the force-app directory..."
        git add force-app
        git commit -m "Retrieve latest metadata defined in $PACKAGE_NAME from $branch_name"
        # Push changes to remote, skipping CI pipeline
        git push "https://${MAINTAINER_PAT_NAME}:${MAINTAINER_PAT_VALUE}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" -o ci.skip
    else
        echo "There are no changes in the force-app directory on $branch_name."
    fi
    # hard reset required before switching branches - will reset the manifest/package.xml back to original
    rm -rf manifest
    git reset --hard
done

# Cleanup, switch back to the SHA that triggered this pipeline and delete local branches
git -c advice.detachedHead=false checkout -q $CI_COMMIT_SHORT_SHA
git branch -D fullqa
git branch -D develop

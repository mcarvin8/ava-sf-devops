#!/bin/bash
# Checks the deployment package.xml for emptyness, Apex, Connected Apps, wildcards
set -e

# verify package has types to deploy
if ! grep -q '<types>' "$DEPLOY_PACKAGE" ; then
    echo "ERROR: No Metadata captured, $DEPLOY_PACKAGE is empty"
    exit 1
fi

# Check if a wildcard is in the package and fail if true to enforce incremental deployments
# sfdx-git-delta packages will never contain wildcards
# wildcards can only be present in the developer provided package list
if grep -iq "<members>\s*\*\s*</members>" "$DEPLOY_PACKAGE"; then
    echo "ERROR: Wildcards are not allowed in the package.xml."
    echo "Remove the wildcard from your manual package list and push a new commit."
    exit 1
fi

# Check for Apex in the package and determine specified tests if true
if grep -iq "<name>ApexClass</name>" "$DEPLOY_PACKAGE" || grep -iq "<name>ApexTrigger</name>" "$DEPLOY_PACKAGE"; then
    echo "Found ApexClass or ApexTrigger in $DEPLOY_PACKAGE, looking for specified tests for deployment..."
    testclasses=$(sf apextests list -x "$DEPLOY_PACKAGE")
    echo $testclasses
else
    echo "ApexClass or ApexTrigger not found in $DEPLOY_PACKAGE"
    testclasses="not a test"
fi

# Check if Connected App is in the package and remove consumer keys if true
if grep -iq "<name>ConnectedApp</name>" "$DEPLOY_PACKAGE"; then
    echo "Found ConnectedApp in $DEPLOY_PACKAGE, removing consumer keys in each connected app before deployment..."
    # Remove the <consumerKey> line in every connected app file in the current directory and its subdirectories
    find . -type f -name "*.connectedApp-meta.xml" | while read -r file; do
        echo "Processing Connected App file: $file"
        sed -i '/<consumerKey>/d' "$file"
    done
    echo "Completed removing <consumerKey> lines from Connected App files."
fi

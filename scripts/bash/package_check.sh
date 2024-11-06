#!/bin/bash
set -e

# verify package has types to deploy
if grep -q '<types>' $DEPLOY_PACKAGE ; then
  echo "---- Deploying added and modified metadata ----"
else
  echo "---- No changes to deploy ----"
  exit 0
fi

# Check for Apex in the package and determine specified tests if true
if grep -iq "<name>ApexClass</name>" "$DEPLOY_PACKAGE" || grep -iq "<name>ApexTrigger</name>" "$DEPLOY_PACKAGE"; then
    echo "Found ApexClass or ApexTrigger in $DEPLOY_PACKAGE, installing apex tests list plugin to set specified tests for deployment..."
    echo y | sf plugins install apextestlist@latest;
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

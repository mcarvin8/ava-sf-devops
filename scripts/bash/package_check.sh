#!/bin/bash
set -e

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

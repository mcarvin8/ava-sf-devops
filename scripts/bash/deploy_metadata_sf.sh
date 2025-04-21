#!/bin/bash
# Deploys or validates metadata in the target org
set -e

# Run deployment without tests for non-apex
# Validate with specific tests for apex
if [ "$testclasses" == "not a test" ]; then
    # Add --dry-run flag to validate non-apex packages from a MR
    if [ "$CI_PIPELINE_SOURCE" != "push" ]; then
        sf project deploy start --dry-run -x $DEPLOY_PACKAGE -w $DEPLOY_TIMEOUT --verbose
    else
        sf project deploy start -x $DEPLOY_PACKAGE -w $DEPLOY_TIMEOUT --verbose
    fi
else
    # apex tests list plugin supplies the "-t" flag
    sf project deploy validate -l RunSpecifiedTests $testclasses \
        --coverage-formatters json --results-dir coverage \
        -x $DEPLOY_PACKAGE -w $DEPLOY_TIMEOUT --verbose
fi

# Quick-deploy if the validate ran tests and this is a push pipeline (deploy job)
if [ "$CI_PIPELINE_SOURCE" == "push" ] && [ "$testclasses" != "not a test" ]; then
    echo "Running the quick-deployment..."
    sf project deploy quick --use-most-recent -w $DEPLOY_TIMEOUT
fi

#!/bin/bash
set -e

# Handle non-Apex packages (no tests)
if [ "$testclasses" == "not a test" ]; then
    if [ "$CI_PIPELINE_SOURCE" != "push" ]; then
        sf project deploy start --dry-run -x $DEPLOY_PACKAGE -w $DEPLOY_TIMEOUT --verbose
    else
        sf project deploy start -x $DEPLOY_PACKAGE -w $DEPLOY_TIMEOUT --verbose
    fi
else
    # Apex package with tests
    if [ "$CI_PIPELINE_SOURCE" != "push" ]; then
        # Always validate on non-push pipelines
        sf project deploy validate -l RunSpecifiedTests -t $testclasses \
            --coverage-formatters json --results-dir coverage \
            -x $DEPLOY_PACKAGE -w $DEPLOY_TIMEOUT --verbose
    else
        if [ "$CI_ENVIRONMENT_NAME" == "production" ]; then
            # Production: validate then quick-deploy
            sf project deploy validate -l RunSpecifiedTests -t $testclasses \
                --coverage-formatters json --results-dir coverage \
                -x $DEPLOY_PACKAGE -w $DEPLOY_TIMEOUT --verbose

            echo "Running the quick-deployment..."
            sf project deploy quick --use-most-recent -w $DEPLOY_TIMEOUT
        else
            # Other environments: deploy directly with tests
            sf project deploy start -l RunSpecifiedTests -t $testclasses \
                --coverage-formatters json --results-dir coverage \
                -x $DEPLOY_PACKAGE -w $DEPLOY_TIMEOUT --verbose
        fi
    fi
fi

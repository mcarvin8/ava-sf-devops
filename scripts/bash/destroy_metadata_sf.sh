#!/bin/bash
set -e

# run destruction only if destructive changes package has types
if grep -q '<types>' $DESTRUCTIVE_CHANGES_PACKAGE ; then
  echo "---- Destructive metadata changes found.... ----"
else
  echo "---- No changes to destroy ----"
  exit 1
fi

# Check for Apex in the destructive package
if grep -iq "<name>ApexClass</name>" "$DESTRUCTIVE_CHANGES_PACKAGE" || grep -iq "<name>ApexTrigger</name>" "$DESTRUCTIVE_CHANGES_PACKAGE"; then
    apex="True"
else
    apex="False"
fi

# Run destructive deployment with pre-defined tests if destroying apex in production (prd)
# Otherwise, destroy without running tests
if [ "$apex" == "True" ] && ["$CI_ENVIRONMENT_NAME" == "prd"]; then
    sf project deploy start --pre-destructive-changes $DESTRUCTIVE_CHANGES_PACKAGE --manifest $DESTRUCTIVE_PACKAGE -l RunSpecifiedTests -t $DESTRUCTIVE_TESTS -w $DEPLOY_TIMEOUT --verbose 
else
    sf project deploy start --pre-destructive-changes $DESTRUCTIVE_CHANGES_PACKAGE --manifest $DESTRUCTIVE_PACKAGE -w $DEPLOY_TIMEOUT --verbose

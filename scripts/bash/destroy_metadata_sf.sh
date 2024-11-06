#!/bin/bash
set -e

determine_tests() {
    # Define the project keys and their associated test classes
    declare -A project_keys
    project_keys=(
        ["BATS"]="ProjectTriggerHandlerTest ProjectTaskTriggerHandlerTest ProjectTaskDependencyTiggerHandlerTest"
        ["LEADZ"]="AccountTriggerHandlerTest ContactTriggerHandlerTest OpportunityTriggerHandlerTest LeadTriggerHandlerTest"
        ["PLAUNCH"]="PaymentMethodTriggerHandlerTest"
        ["SFQ2C"]="PaymentMethodTriggerHandlerTest"
        ["SHIELD"]="ScEMEARegistrationHandlerTest SupportCaseCommunity1Test"
        ["STORM"]="EmailMessageTriggerHandlerTest CaseTriggerHandlerTest"
    )

    # Variable to store the selected test classes
    test_classes=()

    # Iterate over the project keys and check if they are present in the commit message
    for key in "${!project_keys[@]}"; do
        if echo "$CI_COMMIT_MESSAGE" | grep -iq "\\b$key\\b"; then
            # Add all test classes for this project key to the test_classes array
            test_classes+=(${project_keys[$key]})
        fi
    done

    # Add default tests if no team match is found
    if [ ${#test_classes[@]} -eq 0 ]; then
        test_classes=("AccountTriggerHandlerTest" "CaseTriggerHandlerTest")
    fi

    # Print test classes as a space-separated list
    echo "${test_classes[@]}"
}

# Set specified tests if destroying apex in production
if [ "$testclasses" == "not a test" ]
    testclasses=$(determine_tests)
    echo "Tests to run: $required_tests"
    sf project deploy start --pre-destructive-changes $DESTRUCTIVE_CHANGES_PACKAGE --manifest $DESTRUCTIVE_PACKAGE -l RunSpecifiedTests -t $testclasses -w $DEPLOY_TIMEOUT --verbose 
else
    sf project deploy start --pre-destructive-changes $DESTRUCTIVE_CHANGES_PACKAGE --manifest $DESTRUCTIVE_PACKAGE -w $DEPLOY_TIMEOUT --verbose

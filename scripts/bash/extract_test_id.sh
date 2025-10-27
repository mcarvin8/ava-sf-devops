#!/bin/bash
################################################################################
# Script: extract_test_id.sh
# Description: Extracts the Salesforce test run ID from the id.txt file created
#              during test execution and saves it to test_run_id.txt for use in
#              subsequent pipeline jobs.
# Usage: Called from CI/CD pipeline after starting test runs
# Input: id.txt (contains Salesforce CLI output with test run ID)
# Output: test_run_id.txt (contains extracted test run ID)
################################################################################

# Check if the file exists
if [ ! -f "id.txt" ]; then
    echo "Error: id.txt does not exist."
    exit 1
fi

# Read the content of the file
content=$(cat id.txt)

# Use a regular expression to extract the ID
if [[ $content =~ -i[[:space:]]*([[:alnum:]]+) ]]; then
    TEST_RUN_ID="${BASH_REMATCH[1]}"
    echo "$TEST_RUN_ID" > ./test_run_id.txt
    echo "Test run has started. The test run ID is $TEST_RUN_ID"
else
    echo "Id not found in the file content."
    exit 1
fi

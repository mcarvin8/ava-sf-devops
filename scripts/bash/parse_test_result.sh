#!/bin/bash

# Check if TEST_RUN_ID environment variable is set
if [[ -z "$TEST_RUN_ID" ]]; then
    echo "Error: Environment variable TEST_RUN_ID is not set."
    exit 1
fi

# Construct the file name using the ID
TEST_RESULT_FILE="coverage/test-result-${TEST_RUN_ID}.json"

# Check if the file exists
if [[ ! -f "$TEST_RESULT_FILE" ]]; then
    echo "Error: File $TEST_RESULT_FILE does not exist."
    exit 1
fi

# Read the JSON file and extract the summary
SUMMARY=$(jq '.summary' "$TEST_RESULT_FILE")

# Extract hostname and clean it
HOSTNAME=$(echo "$SUMMARY" | jq -r '.hostname')
FIRST_PART=$(echo "$HOSTNAME" | grep -oP '(?<=//).*?(?=\.)')

if [[ -n "$FIRST_PART" ]]; then
    HOSTNAME="$FIRST_PART"
fi

# Determine the summary text
OUTCOME=$(echo "$SUMMARY" | jq -r '.outcome')
TESTS_RAN=$(echo "$SUMMARY" | jq -r '.testsRan')
FAILING=$(echo "$SUMMARY" | jq -r '.failing')

if [[ "$OUTCOME" == "Failed" ]]; then
    SUMMARY_TEXT="❌   Automated unit testing for ${HOSTNAME} has *${OUTCOME}* with ${TESTS_RAN} test runs and ${FAILING} failure(s). Test run ID is ${TEST_RUN_ID}. Download pipeline artifacts from ${CI_JOB_URL}."
else
    SUMMARY_TEXT="✅   Automated unit testing for ${HOSTNAME} has *${OUTCOME}* 🎉 Test run ID is ${TEST_RUN_ID}."
fi

# Construct the Slack payload
SLACK_PAYLOAD=$(jq -n \
    --arg text "Test Runs Finished" \
    --arg summaryText "$SUMMARY_TEXT" \
    '{
        text: $text,
        blocks: [
            {
                type: "section",
                text: {
                    type: "mrkdwn",
                    text: $summaryText
                }
            }
        ]
    }')

# Write the JSON string to the file
echo "$SLACK_PAYLOAD" > slackPayload.json
echo "Slack payload written to slackPayload.json"

#!/bin/bash
set -euo pipefail

function share_slack_update_build() {
    local slack_webhook
    slack_webhook="$SLACK_WEBHOOK"
    local payload_file="slackPayload.json"

    # Check if the payload file exists
    if [[ ! -f "${payload_file}" ]]; then
        echo "Error: Payload file '${payload_file}' not found."
        exit 1
    fi

    # Read the JSON payload from the file
    local payload
    payload=$(cat "${payload_file}")

    curl -X POST \
        --data-urlencode "payload=${payload}" \
        "${slack_webhook}"
}

#!/bin/bash
set -euo pipefail

function print_slack_summary_build() {
    local slack_msg_header
    local pipeline_description
    local environment_name="${CI_ENVIRONMENT_NAME}"

    if [[ "${CI_JOB_STAGE}" == "test" ]]; then
        # remove "validate-" in environment name
        environment_name="${environment_name/validate-/}"
        pipeline_description="Validation against ${environment_name}"
    elif [[ "${CI_JOB_STAGE}" == "destroy" ]]; then
        pipeline_description="Destructive Deployment to ${environment_name}"
    else
        pipeline_description="Deployment to ${environment_name}"
    fi

    if [[ "${CI_JOB_STATUS}" == "success" ]]; then
        slack_msg_header=":orange-check: ${pipeline_description} succeeded :orange-check:"
    else
        slack_msg_header=":alert: ${pipeline_description} failed :alert:"
    fi

    cat <<-SLACK
    {
        "blocks": [
            {
                "type": "header",
                "text": {
                    "type": "plain_text",
                    "text": "${slack_msg_header}",
                    "emoji": true
                }
            },
            {
                "type": "divider"
            },
            {
                "type": "section",
                "fields": [
                    {
                        "type": "mrkdwn",
                        "text": "*Environment:*\n${environment_name}"
                    },
                    {
                        "type": "mrkdwn",
                        "text": "*Pushed By:*\n${GITLAB_USER_NAME}"
                    },
                    {
                        "type": "mrkdwn",
                        "text": "*Job URL:*\n${CI_JOB_URL}"
                    },
                    {
                        "type": "mrkdwn",
                        "text": "*Commit URL:*\n${CI_PROJECT_URL}/-/commit/${CI_COMMIT_SHA}"
                    }
                ]
            },
            {
                "type": "divider"
            }
        ]
    }
SLACK
}

function share_slack_update_build() {
    local slack_webhook
    slack_webhook="$SLACK_WEBHOOK"
    curl -X POST \
        --data-urlencode "payload=$(print_slack_summary_build)" \
        "${slack_webhook}"
}

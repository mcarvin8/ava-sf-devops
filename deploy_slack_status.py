"""
    Post the deployment status to a slack channel
"""
import argparse
import json
import urllib.request


# Update webhook URL here for your slack channel
SLACK_WEBHOOK_URL = "https://hooks.slack.com/services/"


def parse_args():
    """
        Function to parse required arguments.
    """
    parser = argparse.ArgumentParser(description='A script to post the deploy status to a Slack channel.')
    parser.add_argument('-s', '--status')
    parser.add_argument('-u', '--user')
    parser.add_argument('-p', '--project')
    parser.add_argument('-j', '--job')
    parser.add_argument('-c', '--commit')
    parser.add_argument('-e', '--environment')
    args = parser.parse_args()
    return args


def print_slack_summary_build(user, environment, commit, project, status, job):
    """
        Build the payload
    """
    slack_msg_header = f":x: *Deployment to {environment} failed*"
    # GitLab's CI_JOB_STATUS will be set to "success" for a successful job
    if status == "success":
        slack_msg_header = f":heavy_green_checkmark: *Deployment to {environment} succeeded*"

    slack_msg_body = {
        "blocks": [
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": slack_msg_header
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
                        "text": f"*Environment:*\n{environment}"
                    },
                    {
                        "type": "mrkdwn",
                        "text": f"*Pushed By:*\n{user}"
                    },
                    {
                        "type": "mrkdwn",
                        "text": f"*Job URL:*\n{job}"
                    },
                    {
                        "type": "mrkdwn",
                        "text": f"*Commit URL:*\n{project}/-/commit/{commit}"
                    }
                ]
            },
            {
                "type": "divider"
            }
        ]
    }
    return json.dumps(slack_msg_body)


def share_slack_update_build(payload_info):
    """
        Post to slack channel
    """
    slack_webhook = SLACK_WEBHOOK_URL
    data = {"payload": payload_info}
    data_encoded = urllib.parse.urlencode(data).encode("utf-8")
    request = urllib.request.Request(slack_webhook, data=data_encoded, method="POST")
    with urllib.request.urlopen(request):
        pass


def main(user, environment, commit, project, status, job):
    """
        Main function
    """
    payload_info = print_slack_summary_build(user, environment, commit, project, status, job)
    share_slack_update_build(payload_info)


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.user, inputs.environment, inputs.commit,
         inputs.project, inputs.status, inputs.job)

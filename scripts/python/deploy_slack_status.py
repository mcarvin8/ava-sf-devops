"""
    Post the deployment status to a slack channel
"""
import argparse
import json
import urllib.request


def parse_args():
    """
        Function to parse required arguments.
    """
    parser = argparse.ArgumentParser(description='Post deployment status to a slack channel.')
    parser.add_argument('-s', '--status')
    parser.add_argument('-u', '--user')
    parser.add_argument('-p', '--project')
    parser.add_argument('-j', '--job')
    parser.add_argument('-c', '--commit')
    parser.add_argument('-e', '--environment')
    parser.add_argument('-w', '--webhook')
    parser.add_argument('--stage', default='deploy')
    args = parser.parse_args()
    return args


def print_slack_summary_build(user, environment, commit, project, status, job, stage):
    """
        Build the payload
    """
    if stage == 'test':
        environment = environment.replace('validate-', '')
        pipeline_description = f'Validation against {environment}'
    elif stage == 'destroy':
        pipeline_description = f'Destructive Deployment to {environment}'
    else:
        pipeline_description = f'Deployment to {environment}'

    if status == "success":
        slack_msg_header = f":orange-check: *{pipeline_description} succeeded* :orange-check:"
    else:
        slack_msg_header = f":alert: *{pipeline_description} failed* :alert:"

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


def share_slack_update_build(payload_info, slack_webhook):
    """
        Post to slack channel
    """
    data = {"payload": payload_info}
    data_encoded = urllib.parse.urlencode(data).encode("utf-8")
    request = urllib.request.Request(slack_webhook, data=data_encoded, method="POST")
    with urllib.request.urlopen(request):
        pass


def main(user, environment, commit, project, status, job, webhook, stage):
    """
        Main function
    """
    payload_info = print_slack_summary_build(user, environment, commit, project, status, job, stage)
    share_slack_update_build(payload_info, webhook)


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.user, inputs.environment, inputs.commit,
         inputs.project, inputs.status, inputs.job,
         inputs.webhook, inputs.stage)

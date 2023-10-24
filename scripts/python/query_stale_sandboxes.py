"""
    Query Stale Sandboxes with Tooling API.
    Requires your Production user.name, password, and Security Token.
"""
import argparse
import datetime
import logging
import re
from simple_salesforce import Salesforce


# Format logging message
logging.basicConfig(format='%(message)s', level=logging.DEBUG)


def parse_args():
    """
        Function to pass required arguments.
    """
    parser = argparse.ArgumentParser(description='A script to query sandboxes.')
    parser.add_argument('-u', '--user')
    parser.add_argument('-p', '--password')
    parser.add_argument('-t', '--token')
    args = parser.parse_args()
    return args


def parse_iso_datetime(datetime_str):
    """
        Function to parse the datetime string with milliseconds
    """
    datetime_pattern = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})")
    match = datetime_pattern.search(datetime_str)
    if match:
        datetime_without_milliseconds = match.group(1)
        return datetime.datetime.fromisoformat(datetime_without_milliseconds)
    return None


def get_salesforce_connection(username, password, security_token):
    """
        Connect to Salesforce
    """
    # producton emails end in ".com"
    # sandbox emails have the sandbox name after ".com."
    domain = 'login' if username.endswith('.com') else 'test'
    return Salesforce(username=username, password=password,
                      security_token=security_token, domain=domain)


def is_sandbox_eligible(start_date, status):
    """
        Determine if sandbox is eligible.
        Eligibility:
            - Last refresh date is over 30 days ago
            - Sandbox Status is not Deleted or Deleting
    """
    if not start_date:
        return False
    current_time = datetime.datetime.now()
    delta = current_time - start_date
    return delta.days > 30 and (status not in {'Deleted', 'Deleting'})


def log_sandbox_info(sandbox_name, start_date):
    """
        Log sandbox info such as name and start date.
    """
    sbx_info = f'SandboxName: {sandbox_name}, LastRefreshDate: {start_date}'
    logging.info(sbx_info)


def main(user_name, user_password, user_token):
    """
        Main function
    """
    sf = get_salesforce_connection(user_name, user_password, user_token)

    # Query the Tooling API
    query_data = sf.toolingexecute('query?q=SELECT+StartDate,SandboxName,Status+FROM+SandboxProcess','GET')

    if 'records' in query_data:
        records = query_data['records']
        unique_sandbox_info = {}

        for item in records:
            sandbox_name = item.get('SandboxName')
            start_date_str = item.get('StartDate')
            sandbox_status = item.get('Status')

            if sandbox_name not in unique_sandbox_info:
                start_date = parse_iso_datetime(start_date_str)
                if is_sandbox_eligible(start_date, sandbox_status):
                    unique_sandbox_info[sandbox_name] = (sandbox_name, start_date)

        # Sort the unique_sandbox_info dictionary by sandbox name
        sorted_sandbox_info = dict(sorted(unique_sandbox_info.values(), key=lambda x: x[0].lower()))

        # Log sandbox info alphabetically by sandbox name
        for sandbox_name, start_date in sorted_sandbox_info.items():
            log_sandbox_info(sandbox_name, start_date)
    else:
        logging.error("No 'records' key found in the query response.")


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.user, inputs.password,
         inputs.token)

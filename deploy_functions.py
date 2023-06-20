"""
    Shared functions used by multiple scripts.
"""
import json
import logging
import os
import re
import subprocess
import sys


# Format logging message
logging.basicConfig(format='%(message)s', level=logging.DEBUG)


def run_command(cmd):
    """
        Function to run the command using the native shell.
    """
    try:
        subprocess.run(cmd, check=True, shell=True)
    except subprocess.CalledProcessError:
        sys.exit(1)


def check_deployment_status(deploy_json, validate):
    """
        Function to check the deploy status
        from the JSON output.
    """
    with open(os.path.abspath(deploy_json), encoding='utf-8') as json_file:
        parsed_json = json.load(json_file)
    results = parsed_json.get('result')
    deploy_type = 'Validation' if validate else 'Deployment'
    if results['success'] is True:
        logging.info('%s Passed.', deploy_type)
        # don't exit program
    else:
        logging.info('%s Failed.', deploy_type)
        sys.exit(1)


def find_deploy_id(log):
    """
        Function to check the deploy log for the ID.
    """
    pattern = r'Deploy ID: (.*)'

    # keep reading the log until the ID has been found
    deploy_id = None
    with open(log, 'r', encoding='utf-8') as deploy_file:
        while True:
            file_line = deploy_file.readline()
            match = re.search(pattern, file_line)
            # if regex is found, build the link and break the loop
            if match:
                deploy_id = match.group(1)
                break
    return deploy_id

"""
    Install Salesforce CLI and append it to your environment path before running this script.
"""
import argparse
import logging
import re
import subprocess
import sys
import threading


# Format logging message
logging.basicConfig(format='%(message)s', level=logging.DEBUG)


def parse_args():
    """
        Function to pass required arguments.
        tests - Define required Apex test classes to execute.
        manifest - path to the package.xml file
        wait - Number of minutes to wait for the command to complete.
        environment - Salesforce environment URL
        pipeline - pipeline type (push or merge_request_event)
        log - deploy log where the output of this script is being written to
            python ./deploy_metadata_sfdx.py --args | tee -a deploy_log.txt
            -a flag required to append to file during run-time
        validate - Set to true to run a check-only deployment
        debug - Optional. Print to the terminal rather than run.
    """
    parser = argparse.ArgumentParser(description='A script to deploy metadata to salesforce.')
    parser.add_argument('-t', '--tests')
    parser.add_argument('-m', '--manifest', default='manifest/package.xml')
    parser.add_argument('-w', '--wait', default=33)
    parser.add_argument('-e', '--environment')
    parser.add_argument('-l', '--log', default='deploy_log.txt')
    parser.add_argument('-p', '--pipeline', default='push')
    parser.add_argument('-v', '--validate', default=False, action='store_true')
    parser.add_argument('-d', '--debug', default=False, action='store_true')
    args = parser.parse_args()
    return args


def create_sf_link(sf_env, log, result):
    """
        Function to check the deploy log for the ID
        and build the URL.
    """
    pattern = r'Deploy ID: (.*)'
    classic_sf_path = '/changemgmt/monitorDeploymentsDetails.apexp?retURL=' +\
                        '/changemgmt/monitorDeployment.apexp&asyncId='

    # keep reading the log until the ID has been found
    deploy_id = None
    with open(log, 'r', encoding='utf-8') as deploy_file:
        while True:
            file_line = deploy_file.readline()
            match = re.search(pattern, file_line)
            # if regex is found, break the loop
            if match:
                deploy_id = match.group(1)
                break

    # log the URL and store the validate ID
    if deploy_id:
        sf_id = deploy_id[:-3]
        deploy_url = f'{sf_env}{classic_sf_path}{sf_id}'
        logging.info(deploy_url)
        result['deploy_id'] = deploy_id


def create_empty_file(file_path):
    """
        Function to create an empty file
    """
    with open(file_path, 'w', encoding='utf-8'):
        pass


def run_command(cmd):
    """
        Function to run the command using the native shell.
    """
    try:
        subprocess.run(cmd, check=True, shell=True)
    except subprocess.CalledProcessError:
        sys.exit(1)


def quick_deploy(deploy_id, wait, environment, log, result):
    """
        Function to run a quick-deploy after
        a successful validation.
    """
    quick_deploy_thread = threading.Thread(target=create_sf_link, args=(environment, log, result))
    quick_deploy_thread.daemon = True
    quick_deploy_thread.start()
    command = f'sf project deploy quick -i {deploy_id} -w {wait}'
    logging.info(command)
    logging.info('Running the quick-deployment.')
    run_command(command)


def main(testclasses, manifest, wait, environment, log, pipeline, validate, debug):
    """
        Main function to deploy to salesforce.
    """
    apex = testclasses != "not a test"
    command = (f'{f"sf project deploy validate -l RunSpecifiedTests -t {testclasses}" if (validate and apex) else "sf project deploy start"}'
                f'{" --dry-run" if (validate and not apex) else ""}'
                f' -x {manifest} -w {wait} --verbose')
    logging.info(command)

    if validate and not apex and pipeline == 'push':
        logging.info('Not running validation deployment without test classes.')
        return

    if debug:
        return

    # Create deploy log to avoid any threading errors
    create_empty_file(log)

    # Create result dictionary to store deploy_id
    result = {}

    # create and start read thread to run in parallel with deployment
    read_thread = threading.Thread(target=create_sf_link, args=(environment, log, result))
    # set read thread to daemon so it automatically terminates when
    # the main program ends
    # ex: if package.xml is empty, no ID is created and the thread will continue to run
    read_thread.daemon = True
    read_thread.start()
    # start the deployment
    run_command(command)
    # run quick-deploy after a validation on a push pipeline (apex)
    if validate and pipeline == 'push':
        # overwrite existing log from validation
        create_empty_file(log)
        quick_deploy(result.get('deploy_id'), wait, environment, log, result)


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.tests, inputs.manifest, inputs.wait, inputs.environment,
         inputs.log, inputs.pipeline, inputs.validate, inputs.debug)

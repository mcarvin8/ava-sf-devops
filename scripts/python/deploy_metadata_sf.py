"""
    Install Salesforce CLI and append it to your environment path before running this script.
"""
import argparse
import logging
import subprocess
import sys


# Format logging message
logging.basicConfig(format='%(message)s', level=logging.DEBUG)


def parse_args():
    """
        Function to pass required arguments.
        tests - Define required Apex test classes to execute.
        manifest - path to the package.xml file
        wait - Number of minutes to wait for the command to complete.
        pipeline - pipeline type (push or merge_request_event)
        validate - Set to true to run a check-only deployment
        debug - Optional. Print to the terminal rather than run.
    """
    parser = argparse.ArgumentParser(description='Deploy metadata to Salesforce.')
    parser.add_argument('-t', '--tests')
    parser.add_argument('-m', '--manifest', default='manifest/package.xml')
    parser.add_argument('-w', '--wait', default=33)
    parser.add_argument('-p', '--pipeline', default='push')
    parser.add_argument('-v', '--validate', default=False, action='store_true')
    parser.add_argument('-d', '--debug', default=False, action='store_true')
    args = parser.parse_args()
    return args


def run_command(cmd):
    """
        Function to run the command using the native shell.
    """
    try:
        subprocess.run(cmd, check=True, shell=True)
    except subprocess.CalledProcessError:
        sys.exit(1)


def quick_deploy(wait):
    """
        Function to run a quick-deploy after
        a successful validation.
    """
    command = f'sf project deploy quick --use-most-recent -w {wait}'
    logging.info(command)
    logging.info('Running the quick-deployment.')
    run_command(command)


def main(testclasses, manifest, wait, pipeline, validate, debug):
    """
        Main function to deploy to salesforce.
    """
    apex = testclasses != "not a test"
    command = (f'{f"sf project deploy validate -l RunSpecifiedTests -t {testclasses} --coverage-formatters json --results-dir coverage" if (validate and apex) else "sf project deploy start"}'
                f'{" --dry-run" if (validate and not apex) else ""}'
                f' -x {manifest} -w {wait} --verbose')
    logging.info(command)

    if validate and not apex and pipeline == 'push':
        logging.info('Not running validation deployment without test classes.')
        return

    if debug:
        return

    run_command(command)
    # run quick-deploy after a validation on a push pipeline (apex)
    if validate and pipeline == 'push':
        quick_deploy(wait)


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.tests, inputs.manifest, inputs.wait,
         inputs.pipeline, inputs.validate, inputs.debug)

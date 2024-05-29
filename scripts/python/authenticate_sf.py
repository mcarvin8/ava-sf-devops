"""
    Install Salesforce CLI and append it to your environment path before running this script.
"""
import argparse
import logging
import os
import tempfile
import subprocess
import sys


# Format logger
logging.basicConfig(format='%(message)s', level=logging.DEBUG)


def parse_args():
    """
        Function to parse required arguments.
        alias - alias to set
        url - authorization URL (do not store in quotes)
    """
    parser = argparse.ArgumentParser(description='A script to authenticate to Salesforce.')
    parser.add_argument('-a', '--alias')
    parser.add_argument('-u', '--url')
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


def make_temp_file(url):
    """
        Function to create the temporary file with the URL
    """
    temp_file = tempfile.NamedTemporaryFile(delete=False)
    with open(temp_file.name, 'w', encoding='utf-8') as file:
        file.write(url)
    return temp_file.name


def main(alias, url):
    """
        Main function to authenticate to Salesforce.
    """
    # Create temporary file to store the URL
    url_file = make_temp_file(url)

    # Set all commands
    # Do not expose the URL in the logs
    commands = []
    commands.append(f'sf org login sfdx-url -f {url_file} --set-default --alias {alias}')
    commands.append(f'sf config set target-org={alias}')
    commands.append(f'sf config set target-dev-hub={alias}')

    # Run each command one after the other
    for command in commands:
        logging.info(command)
        run_command(command)

    # Delete the temporary file
    os.unlink(url_file)


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.alias, inputs.url)

"""Delete metadata from a Salesforce org using the plugin."""
import argparse
import logging
import subprocess
import sys
import threading
import xml.etree.ElementTree as ET


import deploy_metadata_sf


# Format logging message
logging.basicConfig(format='%(message)s', level=logging.DEBUG)
ns = {'sforce': 'http://soap.sforce.com/2006/04/metadata'}


def parse_args():
    """
        Function to pass required arguments.
    """
    parser = argparse.ArgumentParser(description='A script to delete metadata.')
    parser.add_argument('-f', '--from_ref')
    parser.add_argument('-t', '--to_ref')
    parser.add_argument('-w', '--wait', default=33)
    parser.add_argument('-e', '--environment')
    parser.add_argument('-o', '--output', default='destructiveChanges')
    parser.add_argument('-l', '--log', default='deploy_log.txt')
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
        logging.info('ERROR: The plugin was unable to build the package.xml from the git diff.')
        sys.exit(1)


def scan_package(package_path):
    """
        Scan the package for any metadata types.
    """
    try:
        root = ET.parse(package_path).getroot()
    except ET.ParseError:
        logging.info('ERROR: Cannot parse package at %s', package_path)
        sys.exit(1)

    return bool(root.findall('.//sforce:types', ns))


def build_delta_package(from_ref, to_ref, output):
    """
        Run the plugin, then check the destructive package.
    """
    run_command(f'sf sgd:source:delta --to "{to_ref}"'
            f' --from "{from_ref}" --output "."')

    types_present = scan_package(output)
    if types_present:
        return
    else:
        logging.info('ERROR: Destructive changes not detected in the destructive package. Skipping destructive deployment.')
        sys.exit(1)


def main(from_ref, to_ref, wait, environment, output, log, debug):
    """
        Main function to deploy to salesforce.
    """
    destructive_package_path = f'{output}/destructiveChanges.xml'
    build_delta_package(from_ref, to_ref, destructive_package_path)

    command = f'sf project deploy start --pre-destructive-changes "{destructive_package_path}" --manifest "{output}/package.xml" -w {wait}'
    logging.info(command)

    if debug:
        return

    deploy_metadata_sf.create_empty_file(log)
    result = {}

    read_thread = threading.Thread(target=deploy_metadata_sf.create_sf_link, args=(environment, log, result))
    read_thread.daemon = True
    read_thread.start()
    deploy_metadata_sf.run_command(command)


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.from_ref, inputs.to_ref, inputs.wait, inputs.environment,
         inputs.output, inputs.log, inputs.debug)

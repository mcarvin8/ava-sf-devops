"""Delete metadata from a Salesforce org using the plugin."""
import argparse
import logging
import subprocess
import sys
import threading
import xml.etree.ElementTree as ET


import package_check


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


def process_metadata_type(root: ET.Element) -> tuple:
    '''
    Iterate and process through metadata, extract details such as metadata_values
    and whether APEX is required or not

    Needs to be different from `package_check.py` version to not scan connected app files/apex files
    '''

    metadata_values = []
    apex_required = False
    logging.info("Destructive package contents:")

    for metadata_type in root.findall('sforce:types', package_check.ns):

        try:
            metadata_name = [member.text for member in metadata_type.findall('sforce:name', package_check.ns)]
            metadata_member_list = [member.text
                                    for member in metadata_type.findall('sforce:members', package_check.ns)]

            metadata_name = package_check.validate_nametag(metadata_name)
            package_check.validate_memberdata(metadata_name, metadata_member_list)
            logging.info("%s: %s", metadata_name, ', '.join(map(str, metadata_member_list)))

        except AttributeError:
            logging.info("ERROR: <name> tag is missing, Please double check package details..!!!")
            sys.exit(1)

        if metadata_name.lower() in package_check.APEX_TYPES:
            apex_required = True
        metadata_values.append(metadata_name)

    return metadata_values, apex_required


def validate_emptyness(metadata_values: list) -> None:
    '''
    Check if package metadata is empty.

    Different from "package_check.py" version due to apex logging statement.
    '''

    if not metadata_values:
        logging.info("ERROR: No Metadata captured, Destructive Package is empty..!!!")
        sys.exit(1)


def determine_tests(message: str) -> set:
    '''
        Determine which tests to run when destroying Apex in production.
    '''
    project_keys = {
        'BATS': ['ProjectTriggerHandlerTest', 'ProjectTaskTriggerHandlerTest', 'ProjectTaskDependencyTiggerHandlerTest'],
        'LEADZ': ['AccountTriggerHandlerTest', 'ContactTriggerHandlerTest', 'OpportunityTriggerHandlerTest', 'LeadTriggerHandlerTest'],
        'PLAUNCH': ['OrderTriggerHandlerTest', 'PaymentMethodTriggerHandlerTest'],
        'SFQ2C': ['OrderTriggerHandlerTest', 'PaymentMethodTriggerHandlerTest'],
        'SHIELD': ['ScEMEARegistrationHandlerTest', 'SupportCaseCommunity1Test', 'SupportCaseCommunity1Test'],
        'STORM': ['EmailMessageTriggerHandlerTest', 'CaseTriggerHandlerTest']
    }

    # Variable to store test classes to be run
    test_classes = set()

    # Iterate over the project keys and check if they are present in the commit message
    for key, test_class_list in project_keys.items():
        if re.search(fr'\b{key}\b', message, re.IGNORECASE):
            # Add all test classes for this project key to the set
            test_classes.update(test_class_list)

    # add some random default tests if a team match isn't found
    if not test_classes:
        test_classes.add('AccountTriggerHandlerTest')
        test_classes.add('OrderTriggerHandlerTest')
        test_classes.add('CaseTriggerHandlerTest')

    return test_classes


def main(from_ref, to_ref, wait, environment, output, debug):
    """
        Main function to deploy to salesforce.
    """
    destructive_package_path = f'{output}/destructiveChanges.xml'
    build_delta_package(from_ref, to_ref, destructive_package_path)

    # default - don't run tests
    testclasses = set()

    # validate the destructive package before proceeding
    root, local_name, namespace = package_check.parse_package(destructive_package_path)
    package_check.validate_metadata_attributes(root)
    package_check.validate_root(local_name)
    package_check.validate_namespace(namespace)
    metadata_values, apex_required = process_metadata_type(root)
    package_check.validate_version_details(root)
    validate_emptyness(metadata_values)

    if environment == 'prd' and apex_required:
        logging.info("Apex Tests are Required for this package")
        testclasses = determine_tests(message)
        testclasses = package_check.validate_tests(testclasses)

    testclasses_str = ' '.join(testclasses)

    command = f'sf project deploy start --pre-destructive-changes "{destructive_package_path}" --manifest "{output}/package.xml" -w {wait}'
    if testclasses_str:
        command += f' -l RunSpecifiedTests -t {testclasses}'
    logging.info(command)

    if debug:
        return

    run_command(command)


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.from_ref, inputs.to_ref, inputs.wait, inputs.environment,
         inputs.output, inputs.debug)

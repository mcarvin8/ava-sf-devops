#!/usr/bin/env python3
################################################################################
# Script: package_check.py
# Description: Validates Salesforce package.xml files for compliance with
#              deployment standards and automatically determines required Apex
#              test classes. Performs multiple validation checks including:
#              - Schema compliance and namespace validation
#              - Wildcard detection (not allowed in deployments)
#              - Apex test class extraction using @tests/@testsuites annotations
#              - ConnectedApp consumer key removal for security
#              - Workflow parent type blocking (must use children types)
#              - Default test class execution for destructive deployments
# Usage: 
#   python package_check.py -x manifest/package.xml -s deploy -e production
# Arguments:
#   -x, --manifest: Path to package.xml file (default: manifest/package.xml)
#   -s, --stage: Pipeline stage (deploy/destroy)
#   -e, --environment: Target environment (production/sandbox)
# Dependencies: Python 3.x, xml.etree.ElementTree
# Output: Space-separated list of test classes or "not a test"
################################################################################
import argparse
import logging
import os
import re
import sys
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed

APEX_TYPES  = ['apexclass','apextrigger']
PARENT_WORKFLOW = 'workflow'
CHILDREN_WORKFLOW = ['WorkflowAlert','WorkflowFieldUpdate','WorkflowKnowledgePublish',
                     'WorkflowOutboundMessage','WorkflowRule','WorkflowSend',
                     'WorkflowTask','WorkflowFlowAction']
logging.basicConfig(level=logging.DEBUG, format='%(message)s')
ns = {'sforce': 'http://soap.sforce.com/2006/04/metadata'}
ET.register_namespace('', "http://soap.sforce.com/2006/04/metadata")


def parse_args():
    """
        Function to pass required arguments.
    """
    parser = argparse.ArgumentParser(description='A script to determine required Apex tests.')
    parser.add_argument('-x', '--manifest', default='manifest/package.xml')
    parser.add_argument('-s', '--stage', default='deploy')
    parser.add_argument('-e', '--environment', default=None)
    args = parser.parse_args()
    return args


def parse_package(package_path: str) -> tuple:
    '''
    Parses the metadata package XML file.
    '''

    try:
        root = ET.parse(package_path).getroot()
        try:
            # Extract namespace and local name(Package) from the root tag
            namespace, local_name = root.tag.rsplit('}', 1)
            namespace = namespace[1:]

        except ValueError:
            # Handle error if unable to parse root and namespace details
            logging.info(
            'ERROR: Unable to parse root and namespace details,Please correct them..!!!')
            sys.exit(1)

    except ET.ParseError:
        logging.info('ERROR: Unable to parse %s. Push a new commit to fix the package formatting.',
                     package_path)
        sys.exit(1)

    return root, local_name, namespace


def validate_metadata_attributes(root: ET.Element) -> None:
    '''
    Iterate through Metadata and encounter error incase custom tag is present
    '''

    traditional_tags = ("types", "version")

    for child in root:
        parsed_label = child.tag.rsplit('}', 1)[1]
        if parsed_label not in traditional_tags:
            logging.info("ERROR: Unable to parse : <%s> tag, Expected tags are : %s. "
                        "Please review and update them..!!!", parsed_label, traditional_tags)
            sys.exit(1)


def validate_root(local_name: str) -> None:
    '''
    Validates Root name
    '''

    # Check for Root Element, It should be "Package"
    if "Package" != local_name:
        logging.info("ERROR: Root name is '%s' whereas It should be 'Package', "
                    "Please correct Root details..!!!", local_name)
        sys.exit(1)


def validate_namespace(namespace: str) -> None:
    '''
    Validates Namespace detail, It should match with defined "ns" variable above
    '''

    if namespace != ns['sforce']:
        logging.info("ERROR: Either Namespace is missing or defined incorrectly in package. "
            "It should be '%s', Please correct it..!!!", ns['sforce'])
        sys.exit(1)


def validate_nametag(metadata_name: list) -> str:
    '''
    Check and validate <name> tag inside metadata
    1. check whether <name> is defined or not
    2. If defined, check if it's defined only once for each <types>
    Returns error If <name> tag is not present or defined more than once for specific <types>
    '''

    if len(metadata_name) > 1:
        logging.info("ERROR: Multiple <name> tags %s present in single type, "
            "Please double check and remove the additional ones..!!!", metadata_name)
        sys.exit(1)
    elif len(metadata_name) == 0:
        logging.info("ERROR: <name> tag is missing, Please double check and update..!!!")
        sys.exit(1)
    else:
        metadata_name = metadata_name[0]

    return metadata_name


def validate_memberdata(metadata_name: str, metadata_member_list: list) -> None:
    '''
    Check for Memberdata of metadata
    Return an error
    1. If "*" wildcard is used as member entry
    2. If Member is not defined for specific <name>
    '''

    # Invalid Package Example 2 - missing <members> tags
    if len(metadata_member_list) == 0:
        logging.info("ERROR: Members list is missing for %s,"
                    " Please double check package details..!!!", metadata_name)
        sys.exit(1)

    if '*' in metadata_member_list:
        logging.info('ERROR: Wildcards are not allowed in the package.xml.\n'
                        'You should declare specific metadata to deploy.\n'
                        'Remove the wildcard and push a new commit.')
        sys.exit(1)


def validate_emptyness(metadata_values: list) -> None:
    '''
    Check if package metadata is empty 
    '''
    if not metadata_values:
        logging.info("ERROR: No Metadata captured, Package seems blank..!!!")
        sys.exit(1)


def validate_version_details(root):
    """
    Validates the version details in the provided XML root element.
    """

    version_details = root.findall('sforce:version', ns)

    if len(version_details) > 1:
        logging.info("ERROR: Multiple versions : %s are available,"
                     "Please remove the duplicate one!!!",
                    [ver.text for ver in version_details])
        sys.exit(1)


def process_metadata_type(root: ET.Element, stage: str) -> tuple:
    '''
    Iterate and process through metadata, extract details such as metadata_values
    and whether APEX is required or not
    '''

    metadata_values = []
    apex_required = False
    logging.info("Deployment package contents:")
    test_classes_set = set()

    for metadata_type in root.findall('sforce:types', ns):

        try:
            metadata_name = [member.text for member in metadata_type.findall('sforce:name', ns)]
            metadata_member_list = [member.text
                                    for member in metadata_type.findall('sforce:members', ns)]

            metadata_name = validate_nametag(metadata_name)
            validate_memberdata(metadata_name, metadata_member_list)
            logging.info("%s: %s", metadata_name, ', '.join(map(str, metadata_member_list)))

        except AttributeError:
            logging.info("ERROR: <name> tag is missing, Please double check package details..!!!")
            sys.exit(1)

        if metadata_name.lower() == PARENT_WORKFLOW:
            logging.error("ERROR: The parent metadata type Workflow is banned in our CI/CD pipeline.")
            logging.error("Please update the package.xml to use one of the children Workflow types:")
            logging.error("%s", ', '.join(map(str, CHILDREN_WORKFLOW)))
            sys.exit(1)
        elif metadata_name.lower() == "connectedapp" and stage != 'destroy':
            process_connected_app(metadata_member_list)
        elif metadata_name.lower() in APEX_TYPES:
            if stage != 'destroy':
                test_classes_set = process_apex_parallel(metadata_member_list, metadata_name.lower(), test_classes_set)
            apex_required = True
        metadata_values.append(metadata_name)

    return metadata_values, apex_required, test_classes_set


def process_connected_app(metadata_member_list: list) -> None:
    '''
    Process ConnectedApp metadata, identify the associated file, and remove the consumer key.
    '''
    for member in metadata_member_list:
        file_path = f"force-app/main/default/connectedApps/{member}.connectedApp-meta.xml"
        if os.path.exists(file_path):
            logging.info("Processing ConnectedApp to remove consumer key: %s", member)
            remove_consumer_key(file_path)
        else:
            logging.info("ERROR: ConnectedApp file not found: %s", file_path)
            sys.exit(1)


def remove_consumer_key(file_path: str) -> None:
    '''
    Removes the consumer key from the specified ConnectedApp file.
    '''
    try:
        tree = ET.parse(file_path)
        root = tree.getroot()
        consumer_key_element = root.find('.//sforce:consumerKey', ns)
        if consumer_key_element is not None:
            for parent in root.iter():
                for child in parent:
                    if child == consumer_key_element:
                        parent.remove(child)
                        break
            xml_str = ET.tostring(root, encoding='utf-8', method='xml').decode('utf-8')
            header = '<?xml version="1.0" encoding="UTF-8"?>\n'
            with open(file_path, 'w', encoding='utf-8') as file:
                file.write(header + xml_str)
            logging.info("Successfully removed consumer key from %s", file_path)
        else:
            logging.info("No consumer key found in %s", file_path)
    except ET.ParseError:
        logging.info("ERROR: Unable to parse %s. Please check the file format.", file_path)
        sys.exit(1)


def process_apex_parallel(metadata_member_list: list, metadata_name: str, test_classes_set: set) -> set:
    """
    Process Apex files (.cls and .trigger) in parallel using ThreadPoolExecutor.
    """
    if metadata_name == 'apexclass':
        directory = 'classes'
        extension = '.cls'
    else:
        directory = 'triggers'
        extension = '.trigger'

    # Automatically set max_workers based on the system's CPU count
    max_workers = os.cpu_count() * 2  # For I/O-bound tasks, use more threads

    # Create a thread pool executor to process files in parallel
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_file = {
            executor.submit(find_apex_tests, f"force-app/main/default/{directory}/{member}{extension}"): member
            for member in metadata_member_list
        }

        for future in as_completed(future_to_file):
            member = future_to_file[future]
            try:
                found_tests = future.result()
                if found_tests:
                    test_classes_set.update(found_tests.split())
            except FileNotFoundError:
                logging.error("ERROR: Apex file not found: %s", member)
                sys.exit(1)
            except Exception as exc:
                logging.error("ERROR: Exception occurred while processing %s: %s", member, exc)
                sys.exit(1)

    return test_classes_set


def find_apex_tests(file_path: str) -> str:
    """
    Find apex tests declared in the file.
    Returns a string of found test classes.
    """
    try:
        with open(file_path, 'r', encoding='utf-8') as file:
            apex_file_contents = file.read()
        test_classes = []

        # Check if @isTest annotation is present, which indicates the file is an Apex test class
        # If found, append the class file name (without the .cls extension)
        if '@istest' in apex_file_contents.lower():
            class_name = os.path.splitext(os.path.basename(file_path))[0]
            test_classes.append(class_name)

        # Search for @Tests or @TestSuites followed by test class list
        matches = re.findall(r'@(tests|testsuites)\s*:\s*([^\r\n]+)', apex_file_contents, re.IGNORECASE)

        for _, test_list in matches:
            cleaned_tests = re.sub(r'[\s,]+', ' ', test_list.strip())
            test_classes.append(cleaned_tests)

        if not test_classes:
            logging.warning("WARNING: Test annotations not found in %s. Please add @tests: annotation.", file_path)
    except FileNotFoundError:
        logging.error("ERROR: File not found %s", file_path)
        sys.exit(1)
    return ' '.join(test_classes)


def validate_tests(test_classes_set: set) -> str:
    """
    Function to validate apex test classes against the working directory.
    """
    valid_test_classes = []

    for test_class in test_classes_set:
        class_file_path = f'force-app/main/default/classes/{test_class}.cls'
        if os.path.isfile(class_file_path):
            valid_test_classes.append(test_class)
        else:
            logging.warning('WARNING: %s is not a valid test class in the current directory.',
                            test_class)

    if not valid_test_classes:
        logging.error('ERROR: None of the test annotations provided are valid test classes.')
        logging.error('Confirm test class annotations and try again.')
        sys.exit(1)

    # Join valid test classes with a single space for the CLI
    return ' '.join(valid_test_classes)


def determine_destructive_tests() -> str:
    '''
        Determine which tests to run when destroying Apex.
        Returns default test classes for destructive deployments.
    '''
    test_classes = {'AccountTriggerHandlerTest', 'CaseTriggerHandlerTest'}
    return ' '.join(test_classes)


def scan_package(package_path: str, stage: str, env: str) -> str:
    """
    Function to scan the package and confirm if Apex tests are required.
    """
    root, local_name, namespace = parse_package(package_path)

    validate_metadata_attributes(root)
    validate_root(local_name)
    validate_namespace(namespace)
    metadata_values, apex_required, test_classes = process_metadata_type(root, stage)
    validate_version_details(root)
    validate_emptyness(metadata_values)

    # only validate tests for deployments/validations
    if apex_required and stage != 'destroy':
        logging.info("Apex Tests are Required for this package")
        test_classes = validate_tests(test_classes)
    # set default tests for destructive apex deployments only in production
    elif apex_required and stage == 'destroy' and env == 'production':
        logging.info("Apex Tests are Required for this package")
        test_classes = determine_destructive_tests()
    else:
        logging.info("Apex Tests are Not Required for this package")
        test_classes = 'not a test'
    return test_classes


def main(manifest, stage, environment):
    """
        Main function.
    """
    test_classes = scan_package(manifest, stage, environment)
    # print to terminal
    logging.info(test_classes)
    # save to bash variable
    print(test_classes)


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.manifest,
         inputs.stage,
         inputs.environment)

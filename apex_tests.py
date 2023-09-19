"""
    Determine if package contains Apex and
    set required tests for the deployment.
"""
import argparse
import logging
import re
import sys
import xml.etree.ElementTree as ET


# format logger
logging.basicConfig(format='%(message)s', level=logging.DEBUG)

# Metadata which require Apex tests
# Flows require Apex tests if deployed as active
APEX_TYPES = ['ApexClass', 'ApexTrigger']


def parse_args():
    """
        Function to parse required arguments.
        tests - required Apex tests to run against
        manifest - path to the package.xml file
    """
    parser = argparse.ArgumentParser(description='A script to check for Apex types.')
    parser.add_argument('-t', '--tests', default='not,a,test')
    parser.add_argument('-m', '--manifest', default='manifest/package.xml')
    args = parser.parse_args()
    return args


def remove_spaces(string):
    """
        Function to remove extra spaces in a string.
    """
    pattern = re.compile(r'\s+')
    return re.sub(pattern, '', string)


def replace_commas(string):
    """
        Function to remove commas with a single space.
    """
    return re.sub(',', ' ', string)


def extract_tests(commit_msg):
    """
        Extract tests using a regular expression.
        Apex::define,tests,here::Apex
    """
    try:
        tests = re.search(r'[Aa][Pp][Ee][Xx]::(.*?)::[Aa][Pp][Ee][Xx]', commit_msg, flags=0).group(1)
        if tests.isspace() or not tests:
            raise AttributeError
        tests = remove_spaces(tests)
        tests = replace_commas(tests)
    except AttributeError:
        logging.warning('Apex tests not found in the commit message')
        sys.exit(1)
    return tests


def search_for_apex(package_path):
    """
    This function searches the package.xml for any Apex types
    and determines if Apex Tests are required.
    """
    # register the namespace to search the XML
    ns = {'sforce': 'http://soap.sforce.com/2006/04/metadata'}
    root = ET.parse(package_path).getroot()
    apex = False
    for metadata_type in root.findall('sforce:types', ns):
        metadata_name = (metadata_type.find('sforce:name', ns)).text
        # only need to find 1 match before breaking the loop
        if metadata_name in APEX_TYPES:
            apex = True
            break
    return apex


def main(tests, manifest):
    """
        Main function to check for Apex types
        and determine required tests.
    """
    apex = search_for_apex(manifest)

    if apex:
        logging.info('Apex found in the package.')
        tests = extract_tests(tests)
    else:
        logging.info('Apex not found in the package.')
        tests = 'not a test'
    # print tests to store in bash variable
    logging.info(tests)
    print(tests)


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.tests, inputs.manifest)

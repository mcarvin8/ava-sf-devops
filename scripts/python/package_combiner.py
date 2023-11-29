"""
  This script creates a deployment package and tests file by
  combining packages and tests from multiple git branches.
"""
import argparse
import logging
import re
import subprocess
import xml.etree.ElementTree as ET


import apex_tests_git_delta


# Format logging message
logging.basicConfig(format='%(message)s', level=logging.DEBUG)


def parse_args():
    """
        Parse the required args
    """
    parser = argparse.ArgumentParser(description='Build a combined package and tests file.')
    parser.add_argument('-b', '--branches')
    parser.add_argument('-p', '--package', default='manifest/package.xml')
    parser.add_argument('-t', '--tests', default='runTests.txt')
    args = parser.parse_args()
    return args


def remove_spaces(string):
    """
        Function to remove all spaces in a string.
    """
    pattern = re.compile(r'\s+')
    return re.sub(pattern, '', string)


def build_package_from_content(contents, package):
    """
        Write package contents to temp file.
    """
    with open(package, 'w', encoding='utf-8') as package_file:
        package_file.write(contents.strip())
    return package


def get_file_contents(branch, file_path):
    """
        Get the file content on the git branch.
    """
    try:
        contents = subprocess.check_output(['git', 'show', f'{branch}:{file_path}'])
        return contents.decode('utf-8')
    except subprocess.CalledProcessError:
        return ''


def set_metadata_and_tests(branches, package_file, test_file):
    """
        Create a dictionary with all metadata types.
        Create the combined tests file.
    """
    metadata = {}
    combined_test_classes = {}
    api_versions = []
    for branch in branches.split(','):
        package_contents = get_file_contents(branch, package_file)
        package_file = build_package_from_content(package_contents, package_file)
        metadata, api_version, apex_tests_required = parse_package_file(package_file, metadata, branch)
        if apex_tests_required:
            test_file_contents = get_file_contents(branch, test_file)
            test_classes = apex_tests_git_delta.parse_test_classes(test_file_contents)
            combined_test_classes.update({test_class: True for test_class in test_classes.split()})
        api_versions.append(float(0 if api_version is None else api_version))
    required_tests = ','.join(sorted(combined_test_classes.keys(), key=str.lower))
    logging.info('Required tests: %s', required_tests)
    apex_tests_git_delta.create_combined_test_file(test_file, required_tests)
    return metadata, max(api_versions)


def parse_package_file(package_path, changes, branch):
    """
        Parse a package.xml file and append the metadata types to a dictionary.
        Check for apex types to determine if tests are needed.
    """
    try:
        root = ET.parse(package_path).getroot()
    except ET.ParseError:
        logging.info('Package.xml on branch %s unable to be parsed.', branch)
        return changes, None, False
    ns = {'sforce': 'http://soap.sforce.com/2006/04/metadata'}
    apex_types  = ['ApexClass','ApexTrigger']
    metadata_values = []
    apex_required = False
    for metadata_type in root.findall('sforce:types', ns):
        metadata_name = metadata_type.find('sforce:name', ns).text
        metadata_member_list = metadata_type.findall('sforce:members', ns)
        metadata_values.append(metadata_name)

        if metadata_name and '*' not in metadata_name.strip():
            changes.setdefault(metadata_name, set()).update(metadata_member.text for metadata_member in metadata_member_list)
        elif '*' in metadata_name:
            logging.warning('WARNING: Wildcards are not allowed in the deployment package.')

    api_version = root.find('sforce:version', ns).text if root.find('sforce:version', ns) is not None else None

    for metadata_value in metadata_values:
        if metadata_value in apex_types:
            apex_required = True
            break

    return changes, api_version, apex_required


def create_package_file(items, api_version, output_file):
    """
    Create the final package.xml file
    """
    pkg_header = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    pkg_header += '<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n'

    pkg_footer = f'\t<version>{api_version}</version>\n</Package>\n'

    # Sort the keys in items alphabetically (case-insensitive)
    sorted_items = {key: sorted(items[key], key=str.lower) for key in sorted(items, key=str.lower)}

    # Initialize the package contents with the header
    package_contents = pkg_header

    # Append each item to the package
    for key in sorted_items:
        package_contents += "\t<types>\n"
        # Sort the members within each key's list alphabetically (case-insensitive)
        sorted_members = sorted(sorted_items[key], key=str.lower)
        for member in sorted_members:
            package_contents += "\t\t<members>" + member + "</members>\n"
        package_contents += "\t\t<name>" + key + "</name>\n"
        package_contents += "\t</types>\n"

    # Append the footer to the package
    package_contents += pkg_footer
    logging.info('Deployment package contents:')
    logging.info(package_contents)

    with open(output_file, 'w', encoding='utf-8') as package_file:
        package_file.write(package_contents)


def main(branches, package, test_file):
    """
        Main function to build the deployment package and tests file.
    """
    metadata_dict, api_version = set_metadata_and_tests(remove_spaces(branches), package, test_file)
    create_package_file(metadata_dict, api_version, package)


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.branches, inputs.package,
         inputs.tests)

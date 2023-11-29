"""
    Script to build the runTests.txt using the git diff.
"""
import argparse
import logging
import os
import re
import subprocess
import xml.etree.ElementTree as ET


# Format logging message
logging.basicConfig(format='%(message)s', level=logging.DEBUG)


def parse_args():
    """
        Function to pass required arguments.
        old - previous commit (from)
        new - newer commit (to)
        file - file with test classes
    """
    parser = argparse.ArgumentParser(description='Create the runTests.txt file between 2 commits.')
    parser.add_argument('--from', dest='from_value')
    parser.add_argument('--to', dest='to_value')
    parser.add_argument('--tests', default='runTests.txt')
    parser.add_argument('--package', default='manifest/package.xml')
    args = parser.parse_args()
    return args


def get_git_diff(file_path, commit_range):
    """
        Get the diff of the file over the commit range.
    """
    diff_output = subprocess.check_output(['git', 'diff', '--unified=0', commit_range, '--', file_path])
    diff_output = diff_output.decode('utf-8')
    return diff_output


def get_file_contents(commit, file_path):
    """
        Get the file content for the specific git commit.
    """
    try:
        contents = subprocess.check_output(['git', 'show', f'{commit}:{file_path}'])
        return contents.decode('utf-8')
    except subprocess.CalledProcessError:
        return ''


def parse_test_classes(file_contents):
    """
        Add each test class separated by commas to the dictionary.
    """
    test_classes = file_contents.split(',')
    test_dict = {}
    for test_class in test_classes:
        test_dict[remove_spaces(test_class)] = True
    return ' '.join(test_dict.keys())


def validate_test_classes(test_classes, commit):
    """
        Confirm test classes are valid test classes
        in the "to" commit reference.
    """
    valid_test_classes = []
    for test_class in test_classes:
        file_name = test_class + '.cls'
        full_path = f'force-app/main/default/classes/{file_name}'
        cmd = f'git ls-tree {commit} --name-only -- {full_path}'
        try:
            output = subprocess.run(cmd, shell=True, capture_output=True, text=True, check=True)
            output_lines = output.stdout.splitlines()
            filenames = [os.path.basename(line) for line in output_lines]
            if file_name in filenames:
                valid_test_classes.append(test_class)
        except subprocess.CalledProcessError:
            continue
    return valid_test_classes


def create_combined_test_file(test_file_path, test_classes):
    """
        Overwrite the test file.
    """
    with open(test_file_path, 'w', encoding='utf-8') as test_file:
        test_file.write(test_classes)


def remove_spaces(string):
    """
        Function to remove extra spaces in a string.
    """
    pattern = re.compile(r'\s+')
    return re.sub(pattern, '', string)


def parse_package_file(package_path, commit):
    """
        Check for Apex in the package.
    """
    try:
        root = ET.parse(package_path).getroot()
    except ET.ParseError:
        logging.info('Package.xml on commit %s unable to be parsed.', commit)
        return False

    ns = {'sforce': 'http://soap.sforce.com/2006/04/metadata'}
    apex_types = ['ApexClass', 'ApexTrigger']
    apex_required = False

    for metadata_type in root.findall('sforce:types', ns):
        metadata_name = metadata_type.find('sforce:name', ns).text
        if metadata_name in apex_types:
            apex_required = True
            break

    return apex_required


def main(from_ref, to_ref, test_file, package_path):
    """
        Main function.
    """
    commit_range = f'{from_ref}..{to_ref}'
    # Initialize an empty dictionary to store the test classes
    combined_test_classes = {}
    temp_package_file = 'package.xml'
    # Iterate over each commit in the range
    for commit in subprocess.check_output(['git', 'rev-list', commit_range]).decode('utf-8').splitlines():
        package_contents = get_file_contents(commit, package_path)
        # write temp package to scan for apex types
        with open(temp_package_file, 'w', encoding='utf-8') as package_file:
            package_file.write(package_contents.strip())
        apex_tests_required = parse_package_file('package.xml', commit)
        if apex_tests_required:
            tests_contents = get_file_contents(commit, test_file)
            test_classes = parse_test_classes(tests_contents)
            combined_test_classes.update({test_class: True for test_class in test_classes.split()})
    # delete temp package
    os.remove(temp_package_file)
    valid_test_classes = validate_test_classes(combined_test_classes, to_ref)
    valid_test_classes_sorted = ','.join(sorted(valid_test_classes, key=lambda x: x.lower()))

    # Create the combined test file
    create_combined_test_file(test_file, valid_test_classes_sorted)
    print(valid_test_classes_sorted)



if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.from_value, inputs.to_value, inputs.tests,
         inputs.package)

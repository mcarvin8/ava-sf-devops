"""
    Install Salesforce CLI and append it to your environment path.
"""
import argparse
import json
import logging
import os
import sys


# format logger
logging.basicConfig(format='%(message)s', level=logging.DEBUG)


def parse_args():
    """
        Function to parse required arguments.
        file - path to the JSON file, if not the default value
    """
    parser = argparse.ArgumentParser(description='A script to parse the sfdx-project.json.')
    parser.add_argument('-a', '--file', default='./sfdx-project.json')
    args = parser.parse_args()
    return args


def check_single_package_dir(directory, default_path):
    """
        Function to confirm the single package directory is the default.
    """
    try:
        # if the default key is present, it cannot be set to false
        if directory[0]['default'] is False:
            logging.warning('ERROR: The JSON file must include 1 default package directory.')
            logging.warning('Set default to True or remove the default key.')
            sys.exit(1)
    # the default key can be omitted if there is only 1 directory
    except KeyError:
        pass
    # set the path if the directory passes error validation
    default_path = directory[0]['path']
    return default_path


def check_multiple_package_dir(directories, default_path):
    """
        Function to check multiple directories and confirm only 1 is the default.
    """
    # initialize a count
    default_cnt = 0
    for directory in directories:
        try:
            if directory['default'] is True:
                default_path = directory['path']
                default_cnt += 1
        except KeyError:
            pass
    # confirm there is only 1 default directory
    if default_cnt > 1:
        logging.warning('ERROR: There can only be 1 default package directory.')
        sys.exit(1)
    return default_path

def set_default_package_dir(directories):
    """
        Function to set the default package directory path.
    """
    source_folder = None

    # call applicable function based on directory count
    if len(directories) == 1:
        source_folder = check_single_package_dir(directories, source_folder)
    else:
        source_folder = check_multiple_package_dir(directories, source_folder)
    return source_folder


def main(json_file):
    """
        Main function to return the package directory path.
    """
    with open(os.path.abspath(json_file), encoding='utf-8') as file:
        parsed_json = json.load(file)

    package_directories = parsed_json.get('packageDirectories')

    if package_directories:
        # set the default directory path
        dir_path = set_default_package_dir(package_directories)

        if dir_path is None:
            logging.warning('ERROR: Default package directory not found.')
            sys.exit(1)
    else:
        logging.warning('ERROR: Package directories not specified in the JSON file.')
        sys.exit(1)
    # print variable to use in a shell terminal
    print(dir_path)
    return dir_path


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.file)

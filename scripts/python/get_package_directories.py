import json
import logging
import os
import sys


logging.basicConfig(format='%(message)s', level=logging.DEBUG)


def collect_package_dirs(directories):
    """
        Function to collect all package directory paths into a set.
    """
    dir_paths = set()

    # iterate over each directory in packageDirectories and add its path to the set
    for directory in directories:
        try:
            dir_path = directory['path']
            dir_paths.add(dir_path)
        except KeyError:
            logging.warning('ERROR: Directory entry is missing the "path" key.')
            sys.exit(1)

    return dir_paths


def main(json_file):
    """
        Main function to return all package directory paths in a set.
    """
    with open(os.path.abspath(json_file), encoding='utf-8') as file:
        parsed_json = json.load(file)

    package_directories = parsed_json.get('packageDirectories')

    if package_directories:
        dir_paths = collect_package_dirs(package_directories)

        if not dir_paths:
            logging.warning('ERROR: No valid package directories found.')
            sys.exit(1)
    else:
        logging.warning('ERROR: Package directories not specified in the JSON file.')
        sys.exit(1)

    return dir_paths

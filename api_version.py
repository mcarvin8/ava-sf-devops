"""
    The URL should be 'https://org.mysalesforce.com/services/data' depending on your
    Salesforce instance (org).
    This script can be ran as a scheduled pipeline to periodically check and update 
    the sfdx-project.json file with the latest API version.
"""
import argparse
import json
import logging
import os
import sys
import urllib.request

# Format logging message
logging.basicConfig(format='%(message)s', level=logging.DEBUG)


def parse_args():
    """
        Function to pass required arguments.
        url - URL with all supported versions
        file - sfdx-project.json
    """
    parser = argparse.ArgumentParser(description='A script to check the API version.')
    parser.add_argument('-u', '--url')
    parser.add_argument('-f', '--file', default='./sfdx-project.json')
    args = parser.parse_args()
    return args


def find_latest_version(url):
    """
        Function to open the URL and find the latest API version.
    """
    with urllib.request.urlopen(url) as json_file:
        data = json.loads(json_file.read().decode('utf8'))

    # Add versions to array, then find highest version
    versions = []
    for element in data:
        # Convert to float first due to decimal
        version = float(element['version'])
        versions.append(version)
    return max(versions)


def check_json_file(json_path):
    """
        Function to check if the JSON file has the latest API version.
    """
    with open(os.path.abspath(json_path), encoding='utf-8') as file:
        parsed_json = json.load(file)

    source_api_version = parsed_json.get('sourceApiVersion')
    if source_api_version is None:
        logging.info('The JSON file does not the API version.')
        sys.exit(1)
    return parsed_json, source_api_version


def update_json_file(current_version, latest_version, json_path, json_content):
    """
        Function to update the JSON file.
    """
    if str(latest_version) == current_version:
        logging.info('The JSON file already has the latest API version. Ending pipeline.')
        sys.exit(1)
    else:
        logging.info('The JSON file has a older API version.')

    json_content['sourceApiVersion'] = f'"{latest_version}"'
    with open(os.path.abspath(json_path), 'w', encoding='utf-8') as file:
        json.dump(json_content, file, indent=2, sort_keys=True)


def main(url, json_path):
    """
        Main function to check & set the latest API version
        in the JSON file.
        The script will return the latest API version to the terminal
        to use in other scripts.
    """
    latest_version = find_latest_version(url)

    logging.info('Latest API version: ')
    logging.info(latest_version)
    json_dict, current_version = check_json_file(json_path)
    update_json_file(current_version, latest_version, json_path, json_dict)
    # print version to use it in the pipeline
    print(latest_version)


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.url, inputs.file)

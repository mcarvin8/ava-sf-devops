import json
import logging
import os
import sys


def check_json_file(json_path):
    """
        Function to get the sourceAPIVersion from the JSON file.
    """
    with open(os.path.abspath(json_path), encoding='utf-8') as file:
        parsed_json = json.load(file)

    source_api_version = parsed_json.get('sourceApiVersion')
    if source_api_version is None:
        logging.info('The JSON file does not the API version.')
        sys.exit(1)
    return parsed_json, source_api_version

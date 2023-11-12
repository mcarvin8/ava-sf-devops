"""
    Convert SF CLI Validation JSON into Generic Test Coverage format for SonarQube.
    Input - JSON file from the sf project deploy validate command
    Output - XML file formatted with Generic Test Coverage format
"""
import argparse
import json
import logging
import sys
from xml.dom.minidom import Document


# Format logging message
logging.basicConfig(format='%(message)s', level=logging.DEBUG)


def parse_args():
    """
        Function to parse required arguments.
    """
    parser = argparse.ArgumentParser(description='A script to set code coverage.')
    parser.add_argument('-j', '--json', default='./coverage/coverage/coverage.json')
    parser.add_argument('-x', '--xml', default='./coverage.xml')
    args = parser.parse_args()
    return args


def convert_to_generic_test_report(data):
    """
        Function to convert original data to Generic Test Execution Report Format (XML)
    """
    doc = Document()
    coverage = doc.createElement("coverage")
    coverage.setAttribute("version", "1")
    doc.appendChild(coverage)

    for class_name, coverage_info in data.items():
        # Remove "no-map/" from class_name
        class_name = class_name.replace("no-map/", "")
        class_path = f'force-app/main/default/classes/{class_name}.cls'
        file_element = doc.createElement("file")
        file_element.setAttribute("path", class_path)
        coverage.appendChild(file_element)

        for line_number, count in coverage_info["s"].items():
            # Convert True and False to lowercase
            covered = str(count > 0).lower()
            # Only document uncovered lines
            if covered == 'false':
                line_element = doc.createElement("lineToCover")
                line_element.setAttribute("lineNumber", str(line_number))
                line_element.setAttribute("covered", covered)
                file_element.appendChild(line_element)

    return doc.toprettyxml(indent="  ")  # Format with newlines


def main(json_path, xml_path):
    """
        Main function
    """
    try:
        with open(json_path, "r", encoding='utf-8') as json_file:
            original_data = json.load(json_file)
    except FileNotFoundError:
        logging.info('The JSON file %s was not found.', json_path)
        sys.exit(1)

    # Convert to Generic Test Execution Report Format (XML)
    generic_test_report = convert_to_generic_test_report(original_data)

    # Print the Generic Test Execution Report without the first line
    xml_data = '\n'.join(generic_test_report.split('\n')[1:])
    logging.info(xml_data)

    with open(xml_path, "w", encoding='utf-8') as xml_file:
        xml_file.write(xml_data)


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.json, inputs.xml)

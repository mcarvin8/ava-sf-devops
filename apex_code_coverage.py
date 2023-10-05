"""
    Convert SF CLI Validation JSON into Generic Test Coverage format for SonarQube.
    Input - JSON file from the sf project deploy validate command
    Output - XML file formatted with Generic Test Coverage format
"""
import argparse
import json
import xml.etree.ElementTree as ET
from xml.dom.minidom import Document


def parse_args():
    """
        Function to parse required arguments.
        file - path to the JSON file, if not the default value
    """
    parser = argparse.ArgumentParser(description='A script to set code coverage.')
    parser.add_argument('-f', '--file', default='./coverage/coverage/coverage.json')
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


def main(input_file):
    """
        Main function
    """
    try:
        with open(input_file, "r") as f:
            original_data = json.load(f)
    except FileNotFoundError:
        print(f"Error: The file {input_file} was not found.")
        original_data = {}

    # Convert to Generic Test Execution Report Format (XML)
    generic_test_report = convert_to_generic_test_report(original_data)

    # Print the Generic Test Execution Report without the first line
    print('\n'.join(generic_test_report.split('\n')[1:]))

    output_file = "coverage.xml"
    with open(output_file, "w") as f:
        f.write('\n'.join(generic_test_report.split('\n')[1:]))  # Wri

if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.file)

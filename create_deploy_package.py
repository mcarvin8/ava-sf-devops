"""
  This script uses the SFDX git delta plugin to create the delta
  package. Then, it combines the delta XML file with the package.xml
  contents found in the Merge Request description/commit message
  to create the final deployment package.
"""
import argparse
import json
import logging
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


# Format logging message
logging.basicConfig(format='%(message)s', level=logging.DEBUG)
ns = {'sforce': 'http://soap.sforce.com/2006/04/metadata'}


def parse_args():
    """
        Parse the required args
        from_ref - previous commit or baseline branch $CI_COMMIT_BEFORE_SHA
        to_ref - current commit or new branch $CI_COMMIT_SHA
        delta - delta file created by the SDFX Git Delta Plugin
        message - commit message that includes package.xml contents
        combined - package.xml with delta and manifest updates combined
    """
    parser = argparse.ArgumentParser(description='A script to build the deployment package.')
    parser.add_argument('-f', '--from_ref')
    parser.add_argument('-t', '--to_ref')
    parser.add_argument('-d', '--delta', default='package/package.xml')
    parser.add_argument('-m', '--message', default=None)
    parser.add_argument('-c', '--combined', default='deploy.xml')
    args = parser.parse_args()
    return args


def get_source_api_version(json_path):
    """
        Function to get the sourceAPIVersion from the JSON file.
    """
    with open(os.path.abspath(json_path), encoding='utf-8') as file:
        parsed_json = json.load(file)

    source_api_version = parsed_json.get('sourceApiVersion')
    if source_api_version is None:
        logging.info('The JSON file does not have the API version.')
        sys.exit(1)
    return source_api_version


def build_package_from_commit(commit_msg):
    """
        Parse the commit message for the package.xml
    """
    pattern = r'(<\?xml.*?\?>.*?</Package>)'
    matches = re.findall(pattern, commit_msg, re.DOTALL)
    if matches:
        package_xml_content = matches[0]
        logging.info('Found package.xml content:')
        logging.info(package_xml_content.strip())
        with open('package.xml', 'w', encoding='utf-8') as package_file:
            package_file.write(package_xml_content.strip())
        logging.info('package.xml file created.')
        return 'package.xml'
    else:
        logging.info('Package.xml contents not found in the commit message.')
        return None


def parse_package_file(package_path, changes):
    """
        Parse a package.xml file
        and append the metadata types to a dictionary.
    """
    root = ET.parse(package_path).getroot()

    for metadata_type in root.findall('sforce:types', ns):
        metadata_name = (metadata_type.find('sforce:name', ns)).text
        # find all matches if there are multiple members for 1 metadata type
        metadata_member_list = metadata_type.findall('sforce:members', ns)
        for metadata_member in metadata_member_list:
            # if a wilcard is present in the member, don't process it
            wildcard = re.search(r'\*', metadata_member.text)
            if (metadata_name is not None and wildcard is None and len(metadata_name.strip()) > 0) :
                if metadata_name in changes and changes[metadata_name] is not None:
                    changes[metadata_name].add(metadata_member.text)
                else:
                    changes.update({metadata_name : set()})
                    changes[metadata_name].add(metadata_member.text)
            elif wildcard:
                logging.warning('WARNING: Wildcards are not allowed in the deployment package.')
    return changes


def run_command(cmd):
    """
        Function to run the command using the native shell.
    """
    try:
        subprocess.run(cmd, check=True, shell=True)
    except subprocess.CalledProcessError:
        sys.exit(1)


def create_metadata_dict(from_ref, to_ref, delta, commit_msg):
    """
        Create a dictionary with all metadata types.
    """
    run_command(f'sf sgd:source:delta --to "{to_ref}"'
                f' --from "{from_ref}" --output "."')
    metadata = {}
    metadata = parse_package_file(delta, metadata)
    mr_package = build_package_from_commit(commit_msg)
    if mr_package:
        metadata = parse_package_file(mr_package, metadata)
    return metadata


def create_package_file(items, output_file):
    """
        Create the final package.xml file
    """
    api_version = get_source_api_version('./sfdx-project.json')

    pkg_header = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    pkg_header += '<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n'

    pkg_footer = f'\t<version>{api_version}</version>\n'
    pkg_footer += '</Package>\n'

    # Initialize the package contents with the header
    package_contents = pkg_header

    # Append each item to the package
    for key in items:
        package_contents += "\t<types>\n"
        for member in items[key]:
            package_contents += "\t\t<members>" + member + "</members>\n"
        package_contents += "\t\t<name>" + key + "</name>\n"
        package_contents += "\t</types>\n"
    # Append the footer to the package
    package_contents += pkg_footer
    logging.info('Deployment package contents:')
    logging.info(package_contents)
    with open(output_file, 'w', encoding='utf-8') as package_file:
        package_file.write(package_contents)


def main(from_ref, to_ref, delta, message, combined):
    """
        Main function to build the deployment package
    """
    metadata_dict = create_metadata_dict(from_ref, to_ref, delta, message)
    create_package_file(metadata_dict, combined)


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.from_ref, inputs.to_ref,
         inputs.delta, inputs.message, inputs.combined)

"""
    Build the deployment package.xml
"""
import argparse
import logging
import re
import xml.etree.ElementTree as ET


# Format logging message
logging.basicConfig(format='%(message)s', level=logging.DEBUG)
ns = {'sforce': 'http://soap.sforce.com/2006/04/metadata'}


def parse_args():
    """
        Function to pass required arguments.
        from_ref - previous commit or baseline branch $CI_COMMIT_BEFORE_SHA
        to_ref - current commit or new branch $CI_COMMIT_SHA
        plugin - package created by the SDFX Git Delta Plugin
        message - commit message that includes package.xml contents
        output - package.xml for deployment
    """
    parser = argparse.ArgumentParser(description='A script to build the deployment package.')
    parser.add_argument('-f', '--from_ref')
    parser.add_argument('-t', '--to_ref')
    parser.add_argument('-p', '--plugin', default='package/package.xml')
    parser.add_argument('-m', '--message', default=None)
    parser.add_argument('-o', '--output', default='package.xml')
    args = parser.parse_args()
    return args


def build_package_from_commit(commit_msg, output_file):
    """
        Parse the commit message for the package.xml
    """
    pattern = r'(<Package xmlns=".*?">.*?</Package>)'
    matches = re.findall(pattern, commit_msg, re.DOTALL)
    package_path = None
    if matches:
        package_xml_content = matches[0]
        logging.info('Found package.xml contents in the commit message.')
        with open(output_file, 'w', encoding='utf-8') as package_file:
            package_file.write(package_xml_content.strip())
        package_path = output_file
    else:
        logging.info('WARNING: Package.xml contents NOT found in the commit message.')
        return None
    return package_path


def parse_package_file(package_path, changes, ignore_api_version):
    """
        Parse a package.xml file
        and append the metadata types to a dictionary.
    """
    try:
        root = ET.parse(package_path).getroot()
    except ET.ParseError:
        logging.info('Cannot parse package at %s', package_path)
        return changes, None

    for metadata_type in root.findall('sforce:types', ns):
        metadata_name = metadata_type.find('sforce:name', ns).text
        metadata_member_list = metadata_type.findall('sforce:members', ns)
        if metadata_name and '*' not in metadata_name.strip():
            changes.setdefault(metadata_name, set()).update(metadata_member.text for metadata_member in metadata_member_list)
        elif '*' in metadata_name:
            logging.warning('WARNING: Wildcards are not allowed in the deployment package.')

    # ignore api version on plugin (same as JSON)
    # if package.xml in commit message has one, process it
    api_version = root.find('sforce:version', ns).text if not ignore_api_version and root.find('sforce:version', ns) is not None else None
    return changes, api_version


def create_metadata_dict(from_ref, to_ref, plugin_package, commit_msg, output_file):
    """
        Create a dictionary with all metadata types.
    """
    metadata = {}
    metadata, api_version = parse_package_file(plugin_package, metadata, True)

    mr_package = build_package_from_commit(commit_msg, output_file)
    if mr_package:
        metadata, api_version = parse_package_file(mr_package, metadata, False)
    return metadata, api_version


def create_package_file(items, api_version, output_file):
    """
        Create the final package.xml file
    """
    pkg_header = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    pkg_header += '<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n'

    if api_version:
        pkg_footer = f'\t<version>{api_version}</version>\n</Package>\n'
    else:
        pkg_footer = '</Package>\n'

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


def main(from_ref, to_ref, plugin, message, output):
    """
        Main function to build the deployment package
    """
    metadata_dict, api_version = create_metadata_dict(from_ref, to_ref, plugin, message, output)
    create_package_file(metadata_dict, api_version, output)


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.from_ref, inputs.to_ref,
         inputs.plugin, inputs.message, inputs.output)

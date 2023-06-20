"""
    Import ElementTree to parse a package XML file.
"""
import logging
import re
import xml.etree.ElementTree as ET

logging.basicConfig(format='%(message)s', level=logging.DEBUG)
# register the namespace to search the XML
ns = {'sforce': 'http://soap.sforce.com/2006/04/metadata'}


def parse_package_xml(package_path, changes):
    """
        Parse the manual package.xml
        and append the metadata types
        to the existing changes dictionary
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

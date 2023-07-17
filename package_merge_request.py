"""
    Function to build a package.xml from the MR description/commit message.
"""
import logging
import re


# Format logging message
logging.basicConfig(format='%(message)s', level=logging.DEBUG)


def parse_package_xml(description):
    """
        Parse the commit message for the package.xml
    """
    pattern = r'(<\?xml.*?\?>.*?</Package>)'
    matches = re.findall(pattern, description, re.DOTALL)
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

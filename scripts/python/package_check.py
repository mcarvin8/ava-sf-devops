"""
    Scan the package.xml for specific metadata types:
        - ApexClass
        - ApexTrigger
        - Connected Apps
    Fail deployments if the package contains a wildcard.
"""
import argparse
import logging 
import sys
import xml.etree.ElementTree as ET

APEX_TYPES  = ['apexclass','apextrigger']
logging.basicConfig(level=logging.DEBUG, format='%(message)s')
ns = {'sforce': 'http://soap.sforce.com/2006/04/metadata'}
ET.register_namespace('', "http://soap.sforce.com/2006/04/metadata")


def parse_args():
    """
        Function to pass required arguments.
    """
    parser = argparse.ArgumentParser(description='Scan a package.xml')
    parser.add_argument('-m', '--manifest', default='./manifest/package.xml')
    args = parser.parse_args()
    return args


def parse_package(package_path: str) -> tuple:
    '''
    Parses the metadata package XML file.
    '''

    try:
        root = ET.parse(package_path).getroot()
        try:
            # Extract namespace and local name(Package) from the root tag
            namespace, local_name = root.tag.rsplit('}', 1)
            namespace = namespace[1:]

        except ValueError:
            # Handle error if unable to parse root and namespace details
            logging.info(
            'ERROR: Unable to parse root and namespace details,Please correct them..!!!')
            sys.exit(1)

    except ET.ParseError:
        logging.info('ERROR: Unable to parse %s. Push a new commit to fix the package formatting.',
                     package_path)
        sys.exit(1)

    return root, local_name, namespace


def validate_metadata_attributes(root: ET.Element) -> None:
    '''
    Iterate through Metadata and encounter error incase custom tag is present
    '''

    traditional_tags = ("types", "version")

    for child in root:
        parsed_label = child.tag.rsplit('}', 1)[1]
        if parsed_label not in traditional_tags:
            logging.info("ERROR: Unable to parse : <%s> tag, Expected tags are : %s. "
                        "Please review and update them..!!!", parsed_label, traditional_tags)
            sys.exit(1)


def validate_root(local_name: str) -> None:
    '''
    Validates Root name
    '''

    # Check for Root Element, It should be "Package"
    if "Package" != local_name:
        logging.info("ERROR: Root name is '%s' whereas It should be 'Package', "
                    "Please correct Root details..!!!", local_name)
        sys.exit(1)


def validate_namespace(namespace: str) -> None:
    '''
    Validates Namespace detail, It should match with defined "ns" variable above
    '''

    if namespace != ns['sforce']:
        logging.info("ERROR: Either Namespace is missing or defined incorrectly in package. "
            "It should be '%s', Please correct it..!!!", ns['sforce'])
        sys.exit(1)


def validate_nametag(metadata_name: list) -> str:
    '''
    Check and validate <name> tag inside metadata
    1. check whether <name> is defined or not
    2. If defined, check if it's defined only once for each <types>
    Returns error If <name> tag is not present or defined more than once for specific <types>
    '''

    if len(metadata_name) > 1:
        logging.info("ERROR: Multiple <name> tags %s present in single type, "
            "Please double check and remove the additional ones..!!!", metadata_name)
        sys.exit(1)
    elif len(metadata_name) == 0:
        logging.info("ERROR: <name> tag is missing, Please double check and update..!!!")
        sys.exit(1)
    else:
        metadata_name = metadata_name[0]

    return metadata_name


def validate_memberdata(metadata_name: str, metadata_member_list: list) -> None:
    '''
    Check for Memberdata of metadata
    Return an error
    1. If "*" wildcard is used as member entry
    2. If Member is not defined for specific <name>
    '''

    if len(metadata_member_list) == 0:
        logging.info("ERROR: Members list is missing for %s,"
                    " Please double check package details..!!!", metadata_name)
        sys.exit(1)

    if '*' in metadata_member_list:
        logging.info('ERROR: Wildcards are not allowed in the package.xml.\n'
                        'You should declare specific metadata to deploy.\n'
                        'Remove the wildcard and push a new commit.')
        sys.exit(1)


def validate_emptyness(metadata_values: list, apex_required: bool) -> None:
    '''
    Check if package metadata is empty 
    '''

    if metadata_values:
        log_message = "Apex Tests are Required for this package" if apex_required \
                        else "Apex Tests are Not Required for this package"
        logging.info(log_message)
    else:
        logging.info("ERROR: No Metadata captured, Package seems blank..!!!")
        sys.exit(1)


def validate_version_details(root):
    """
    Validates the version details in the provided XML root element.
    """

    version_details = root.findall('sforce:version', ns)

    if len(version_details) > 1:
        logging.info("ERROR: Multiple versions : %s are available,"
                     "Please remove the duplicate one!!!",
                    [ver.text for ver in version_details])
        sys.exit(1)


def process_metadata_type(root: ET.Element, package_directories: set) -> tuple:
    '''
    Iterate and process through metadata, extract details such as metadata_values
    and whether APEX is required or not
    '''
    metadata_values = []
    apex_required = False
    logging.info("Deployment package contents:")

    for metadata_type in root.findall('sforce:types', ns):

        try:
            metadata_name = [member.text for member in metadata_type.findall('sforce:name', ns)]
            metadata_member_list = [member.text
                                    for member in metadata_type.findall('sforce:members', ns)]

            metadata_name = validate_nametag(metadata_name)
            validate_memberdata(metadata_name, metadata_member_list)
            logging.info("%s: %s", metadata_name, ', '.join(map(str, metadata_member_list)))

        except AttributeError:
            logging.info("ERROR: <name> tag is missing, Please double check package details..!!!")
            sys.exit(1)

        if metadata_name.lower() in APEX_TYPES:
            apex_required = True
        metadata_values.append(metadata_name)

    return metadata_values, apex_required


def scan_package(package_path: str) -> str:
    """
    Function to scan the package and confirm if Apex tests are required.
    """
    root, local_name, namespace = parse_package(package_path)

    validate_metadata_attributes(root)
    validate_root(local_name)
    validate_namespace(namespace)
    metadata_values, apex_required = process_metadata_type(root)
    validate_version_details(root)
    validate_emptyness(metadata_values, apex_required)
    return apex_required


def main(manifest):
    """
        Main function.
    """
    apex_required = scan_package(manifest)
    # save to bash variable
    print(apex_required)


if __name__ == '__main__':
    inputs = parse_args()
    main(inputs.manifest)

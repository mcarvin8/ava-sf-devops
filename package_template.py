"""
    Package.xml template
    Pull API version from api_version.py
"""
from api_version import check_json_file

# get current API version used for the project
# only need the second return value
API_VERSION = check_json_file('./sfdx-project.json')[1]

PKG_HEADER = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
'''

PKG_FOOTER = f'''\t<version>{API_VERSION}</version>
</Package>
'''

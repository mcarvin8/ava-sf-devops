#!/bin/bash
# This is an alternate destructive pipeline script which takes in a package list (created via "convert_package_to_list.sh")
# and creates the destructive packages before a destructive deployment.
# This could be used in a web-based pipeline that isn't triggered by changes pushed to a git branch.
# You could copy a package created by Workbench and convert the package to this format.
set -e
# Create directory if it don't exist
mkdir -p "destructiveChanges"

PACKAGE_LIST_FILE="destructiveChanges/package-list.txt"

# Save the package list to a text file
echo "$PACKAGE" | tr ';' '\n' > "$PACKAGE_LIST_FILE"

# convert package list to XML
sf sfpl xml -l "$PACKAGE_LIST_FILE" -x "$DESTRUCTIVE_CHANGES_PACKAGE"

# need an empty package.xml for destructive deployments
sf sfpc combine -c "$DESTRUCTIVE_PACKAGE" -n

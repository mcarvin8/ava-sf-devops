#!/bin/bash
set -e
# Create directory if it don't exist
mkdir -p "destructiveChanges"

PACKAGE_LIST_FILE="package.txt"

# Save the package list to a text file
echo "$PACKAGE" | tr ';' '\n' > "$PACKAGE_LIST_FILE"

# convert package list to XML, omitting the API version
sf sfpl xml -l "$PACKAGE_LIST_FILE" -x "$DESTRUCTIVE_CHANGES_PACKAGE" -n

# need an empty package.xml for destructive deployments
sf sfpl xml -x "$DESTRUCTIVE_PACKAGE"

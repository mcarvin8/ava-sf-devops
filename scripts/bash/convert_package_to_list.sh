#!/bin/bash

# Define the path to the package.xml file
PACKAGE_XML="$1"

# Check if the file exists
if [[ ! -f $PACKAGE_XML ]]; then
    echo "Error: File $PACKAGE_XML not found!"
    exit 1
fi

# Use awk to process the XML and extract metadata types and members
awk '
BEGIN {
    # Initialize variables
    metadataType = ""
    members = ""
}
/<types>/ { inTypes = 1 }                # Start of a <types> block
/<\/types>/ {                            # End of a <types> block
    inTypes = 0
    if (metadataType && members) {
        print metadataType ": " members  # Print the metadata type and its members
    }
    metadataType = ""                    # Reset metadataType
    members = ""                         # Reset members
}
/<name>/ && inTypes {                    # Extract the metadata type
    gsub(/<\/?name>/, "", $1)
    metadataType = $1
}
/<members>/ && inTypes {                 # Extract the member and append it
    gsub(/<\/?members>/, "", $1)
    if (members) {
        members = members ", " $1       # Append with a comma separator
    } else {
        members = $1                    # First member
    }
}
' "$PACKAGE_XML"

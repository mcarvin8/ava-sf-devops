#!/bin/bash
# This is an alternate destructive pipeline script which takes in a package list (created via "convert_package_to_list.sh")
# and creates the destructive packages before a destructive deployment.
# This could be used in a web-based pipeline that isn't triggered by changes pushed to a git branch.
# You could copy a package created by Workbench and convert the package to this format.
set -e
# Create directory if it don't exist
mkdir -p "destructiveChanges"

# Salesforce package.xml header
cat <<EOF > "$DEPLOY_PACKAGE"
<?xml version="1.0" encoding="UTF-8" ?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
EOF

# Normalize input: replace semicolons with newlines for consistent processing
normalized_input=$(echo "$PACKAGE" | tr ';' '\n')

# Check each line for "name: members" format
while IFS= read -r line; do
    # Skip empty lines
    if [[ -z "$line" ]]; then
        continue
    fi
    
    # Check for the pattern "name: members"
    if ! [[ "$line" =~ ^[[:alnum:]_]+:[[:space:]]*[[:alnum:]_.\/]+(,[[:space:]]*[[:alnum:]_.\/]+)*$ ]]; then
        echo "Error: Invalid input format: '$line'"
        echo "Expected format: 'MetadataName: Member1, Member2 ...'"
        exit 1
    fi
done <<< "$normalized_input"

# Parse the input list
while IFS=':' read -r metadata_name members; do
    # Trim whitespace around metadata_name and members
    metadata_name=$(echo "$metadata_name" | xargs)
    members=$(echo "$members" | xargs)

    # Normalize members by replacing commas with spaces and collapsing multiple spaces
    members=$(echo "$members" | tr ',' ' ' | xargs)

    # Add metadata types to package.xml
    echo "    <types>" >> "$DEPLOY_PACKAGE"

    # Split and add each member
    for member in $members; do
        echo "        <members>$member</members>" >> "$DEPLOY_PACKAGE"
    done

    # Add metadata name
    echo "        <name>$metadata_name</name>" >> "$DEPLOY_PACKAGE"
    echo "    </types>" >> "$DEPLOY_PACKAGE"
done <<< "$normalized_input"

# Add closing tags
cat <<EOF >> "$DEPLOY_PACKAGE"
</Package>
EOF

echo "Destructive Package created in $DEPLOY_PACKAGE."
# need an empty package.xml for destructive deployments
cp -f "scripts/packages/destructivePackage.xml" "$DESTRUCTIVE_PACKAGE"

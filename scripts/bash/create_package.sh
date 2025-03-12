#!/bin/bash
set -e

# Define a function to build package.xml from commit message
build_package_from_commit() {
    local commit_msg="$1"
    local output_file="$2"
    PACKAGE_FOUND="False"
    VERSION_FOUND="False"

    # Extract <Package> content from the commit message
    package_content=$(echo "$commit_msg" | sed -n '/<Package>/,/<\/Package>/p' | sed '1d;$d') # Remove <Package> tags

    if [[ -n "$package_content" ]]; then
        echo "Found package content in the commit message."

        # Create package.xml header
        cat <<EOF > "$output_file"
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
EOF

        # Process each line in the package content
        while IFS= read -r line; do
            # Skip empty or whitespace-only lines
            if [[ -z "$(echo "$line" | xargs)" ]]; then
                continue
            fi

            # Check for version
            if echo "$line" | grep -i "^Version:" >/dev/null; then
                if [[ "$VERSION_FOUND" == "False" ]]; then
                    version=$(echo "$line" | cut -d':' -f2 | xargs)
                    version=${version%%.*} # Convert float to integer by truncating
                    echo "Extracted version: $version"
                    VERSION_FOUND="True"
                    export VERSION="$version"
                fi
                continue
            fi

            # Extract metadata name and members
            metadata_name=$(echo "$line" | cut -d':' -f1 | xargs)
            members=$(echo "$line" | cut -d':' -f2- | xargs)

            # Validate metadata_name and members
            if [[ -z "$metadata_name" || -z "$members" ]]; then
                echo "WARNING: Skipping invalid line: '$line'"
                continue
            fi

            # Skip lines with wildcards in members
            if echo "$members" | grep -q '\*'; then
                echo "WARNING: Skipping line with wildcard: '$metadata_name'"
                continue
            fi

            # Add metadata type and members to package.xml
            echo "    <types>" >> "$output_file"
            for member in $(echo "$members" | tr ',' '\n'); do
                echo "        <members>$member</members>" >> "$output_file"
            done
            echo "        <name>$metadata_name</name>" >> "$output_file"
            echo "    </types>" >> "$output_file"
        done <<< "$package_content"

        # Close the package.xml
        cat <<EOF >> "$output_file"
</Package>
EOF

        PACKAGE_FOUND="True"
    else
        echo "WARNING: Package content NOT found in the commit message."
    fi
    export PACKAGE_FOUND
}

# Run the function
build_package_from_commit "$COMMIT_MSG" "$DEPLOY_PACKAGE"

# combine packages with plugin if provided in commit message
# use developer provided API version if found, otherwise omit the API version to default to other source API version inputs
if [[ "$PACKAGE_FOUND" == "True" ]]; then
    echo "Combining package in commit message with automated diff package..."
    if [[ "$VERSION_FOUND" == "True" ]]; then
        sf sfpc combine -f "package/package.xml" -f "$DEPLOY_PACKAGE" -c "$DEPLOY_PACKAGE" -v "$VERSION.0"
    else
        sf sfpc combine -f "package/package.xml" -f "$DEPLOY_PACKAGE" -c "$DEPLOY_PACKAGE" -n
    fi
else
    echo "Fully relying on automated diff package..."
    # reparse delta package with combiner plugin to omit the API version to default to other source API version inputs
    sf sfpc combine -f "package/package.xml" -c "$DEPLOY_PACKAGE" -n
fi

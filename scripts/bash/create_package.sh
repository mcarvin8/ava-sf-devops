#!/bin/bash
# $COMMIT_MSG should vary when validating from a merge request

# Define a function to build package.xml from commit message
build_package_from_commit() {
    local commit_msg="$1"
    local output_file="$2"
    PACKAGE_FOUND="False"

    # Use sed to match and extract the XML package content
    package_xml_content=$(echo "$commit_msg" | sed -n '/<Package xmlns=".*">/,/<\/Package>/p')

    if [[ -n "$package_xml_content" ]]; then
        echo "Found package.xml contents in the commit message."
        echo "$package_xml_content" > "$output_file"
        PACKAGE_FOUND="True"
    else
        echo "WARNING: Package.xml contents NOT found in the commit message."
    fi
    export PACKAGE_FOUND
}

# Run the function
build_package_from_commit "$COMMIT_MSG" "$DEPLOY_PACKAGE"

if [[ "$PACKAGE_FOUND" == "True" ]]; then
    echo "Combining package in commit message with automated diff package..."
    echo y | sf plugins install sf-package-combiner@latest
    sf sfpc combine -f "package/package.xml" -f "$DEPLOY_PACKAGE" -c "$DEPLOY_PACKAGE"
else
    echo "Fully relying on automated diff package..."
    cp -f "package/package.xml" "$DEPLOY_PACKAGE"
fi

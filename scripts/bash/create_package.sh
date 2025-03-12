#!/bin/bash
# $COMMIT_MSG should vary when validating from a merge request
# $COMMIT_MSG: $CI_MERGE_REQUEST_DESCRIPTION for validation
# $COMMIT_MSG: $CI_COMMIT_MESSAGE for deployment
# $DEPLOY_PACKAGE needs to be re-defined as "package.xml" in the .gitlab-ci.yml to use this script
# Only use this script for validate and deploy to allow additional metadata. Fully rely on sfdx-git-delta for destruction packages.

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

# combine packages with plugin if providsx in commit message
if [[ "$PACKAGE_FOUND" == "True" ]]; then
    echo "Combining package in commit message with automated diff package..."
    sf sfpc combine -f "package/package.xml" -f "$DEPLOY_PACKAGE" -c "$DEPLOY_PACKAGE"
else
    echo "Fully relying on automated diff package..."
    # reparse delta package with combiner plugin to remove api version (default to other source api version inputs)
    sf sfpc combine -f "package/package.xml" -c "$DEPLOY_PACKAGE" -n
fi

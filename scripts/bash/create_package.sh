#!/bin/bash
set -e

# Define a function to build package.xml from commit message
build_package_from_commit() {
    local commit_msg="$1"
    local output_file="$2"
    PACKAGE_FOUND="False"
    VERSION_FOUND="False"
    PACKAGE_LIST="package-list.txt"

    # Extract <Package> content from the commit message
    package_content=$(echo "$commit_msg" | sed -n '/<Package>/,/<\/Package>/p' | sed '1d;$d') # Remove <Package> tags

    if [[ -n "$package_content" ]]; then
        echo "Found package content in the commit message."
        echo "$package_content" > "$PACKAGE_LIST"

        # Convert package list to XML
        sf sfpl xml -l "$PACKAGE_LIST" -x "$DEPLOY_PACKAGE"

        # Extract version from package.xml
        if [[ -f "$DEPLOY_PACKAGE" ]]; then
            VERSION=$(grep -oPm1 "(?<=<version>)[0-9.]+" "$DEPLOY_PACKAGE")
            if [[ -n "$VERSION" ]]; then
                VERSION=${VERSION%%.*} # Convert float to integer
                echo "Extracted version: $VERSION"
                VERSION_FOUND="True"
                export VERSION
            fi
        else
            echo "ERROR: $DEPLOY_PACKAGE was not generated."
            exit 1
        fi
        PACKAGE_FOUND="True"
    else
        echo "WARNING: Package contents NOT found in the commit message."
    fi
    export PACKAGE_FOUND
}

# Run the function
build_package_from_commit "$COMMIT_MSG" "$DEPLOY_PACKAGE"

# Combine packages with plugin if provided in commit message
if [[ "$PACKAGE_FOUND" == "True" ]]; then
    echo "Combining package in commit message with automated diff package..."
    if [[ "$VERSION_FOUND" == "True" ]]; then
        sf sfpc combine -f "package/package.xml" -f "$DEPLOY_PACKAGE" -c "$DEPLOY_PACKAGE" -v "$VERSION.0"
    else
        sf sfpc combine -f "package/package.xml" -f "$DEPLOY_PACKAGE" -c "$DEPLOY_PACKAGE" -n
    fi
else
    echo "Fully relying on automated diff package..."
    sf sfpc combine -f "package/package.xml" -c "$DEPLOY_PACKAGE" -n
fi
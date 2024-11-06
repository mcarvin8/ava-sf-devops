#!/bin/bash

# Remove the <consumerKey> line in every connected app file in the current directory and its subdirectories
find . -type f -name "*.connectedApp-meta.xml" | while read -r file; do
    echo "Processing Connected App file: $file"
    sed -i '/<consumerKey>/d' "$file"
done

echo "Completed removing <consumerKey> lines from Connected App files."

#!/bin/bash
################################################################################
# Script: metadata_audit.sh
# Description: Audits metadata deployed by specific development teams over a
#              time period by extracting and combining package.xml files from
#              merge commits. Generates team-specific manifest files and uploads
#              them to Confluence for tracking and reporting purposes.
# Usage: Called from scheduled CI/CD pipeline for weekly audits
# Dependencies: git, Salesforce CLI (sf sfpc), curl, jq
# Environment Variables Required:
#   - CONFLUENCE_USER, CONFLUENCE_TOKEN, CONFLUENCE_PAGE_ID
# Teams Tracked: q2c, leadz, sfxpro, storm, shield
################################################################################
set +e
# Ensure main branch is up to date
git fetch -q
git fetch origin main

# List of teams and their identifiers used in commit messages
declare -A teams=(
  ["q2c"]="q2c"
  ["leadz"]="leadz"
  ["sfxpro"]="sfxpro"
  ["storm"]="storm"
  ["shield"]="shield"
)

timestamp=$(date +"%Y-%m-%d")

for team in "${!teams[@]}"; do
  keyword="${teams[$team]}"
  manifest_dir="${team}_manifests"
  filename="${team}-manifest-${timestamp}.xml"

  echo "Processing team: $team (keyword: $keyword)"
  mkdir -p "$manifest_dir"

  # Find and extract package.xml from relevant merge commits
  git log origin/main --since="1 week ago" --merges --pretty=format:"%H %s" | \
    grep -i "$keyword" | \
    awk '{print $1}' | \
    while read commit; do
      git show "$commit:manifest/package.xml" > "$manifest_dir/$commit-package.xml" 2>/dev/null || \
        echo "File missing in $commit for $team"
    done

  # Combine manifests into a single package.xml
  sf sfpc combine -d "$manifest_dir" -c "$filename" -n

  # Upload to Confluence
  curl -u "$CONFLUENCE_USER:$CONFLUENCE_TOKEN" \
    -X POST \
    -H "X-Atlassian-Token: no-check" \
    -F "file=@$filename" \
    "https://avalara.atlassian.net/wiki/rest/api/content/${CONFLUENCE_PAGE_ID}/child/attachment"
done

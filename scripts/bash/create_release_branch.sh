#!/bin/bash
################################################################################
# Script: create_release_branch.sh
# Description: Creates or updates a release branch by merging multiple story 
#              branches and combining their package.xml manifests. Prevents 
#              merging into protected branches (main, fullqa, develop, ContPar).
# Usage: 
#   RELEASE_BRANCH=release/1.2.3 STORY_BRANCHES="story/123 story/456" ./create_release_branch.sh
# Environment Variables Required:
#   - RELEASE_BRANCH: Name of the release branch to create/update
#   - STORY_BRANCHES: Space or comma-separated list of story branches to merge
#   - MAINTAINER_PAT_NAME, MAINTAINER_PAT_VALUE
################################################################################

set -e

# Normalize STORY_BRANCHES: allow space or comma separation, remove extra whitespace
STORY_BRANCHES=$(echo "$STORY_BRANCHES" | tr ',' ' ' | xargs)

# Check required variables
if [[ -z "$RELEASE_BRANCH" ]]; then
  echo "RELEASE_BRANCH is not set."
  exit 1
fi

if [[ -z "$STORY_BRANCHES" ]]; then
  echo "STORY_BRANCHES is not set."
  exit 1
fi

# Restricted branches
RESTRICTED_BRANCHES=("main" "fullqa" "develop" "ContPar")

# Check if RELEASE_BRANCH or any STORY_BRANCH is restricted
for restricted in "${RESTRICTED_BRANCHES[@]}"; do
  if [[ "$RELEASE_BRANCH" == "$restricted" ]]; then
    echo "ERROR: RELEASE_BRANCH cannot be '$restricted'"
    exit 1
  fi

  for b in $STORY_BRANCHES; do
    if [[ "$b" == "$restricted" ]]; then
      echo "ERROR: STORY_BRANCHES contains restricted branch '$restricted'"
      exit 1
    fi
  done
done

# Fetch latest from origin
git fetch -q

# Ensure the release branch reference from origin exists locally
git fetch origin "$RELEASE_BRANCH":"refs/remotes/origin/$RELEASE_BRANCH" || true

git config user.name "${MAINTAINER_PAT_NAME}"
git config user.email "${MAINTAINER_PAT_USER_NAME}@noreply.${CI_SERVER_HOST}"

# Check if the release branch exists on the remote
if git ls-remote --exit-code --heads origin "$RELEASE_BRANCH" > /dev/null; then
  echo "Release branch exists on origin: $RELEASE_BRANCH"
  git fetch origin "$RELEASE_BRANCH"
  git checkout -b "$RELEASE_BRANCH" "origin/$RELEASE_BRANCH"
else
  echo "Creating new release branch: $RELEASE_BRANCH from origin/main"
  git fetch origin main
  git checkout -b "$RELEASE_BRANCH" origin/main
fi

# Create a temporary directory for package.xml files
TEMP_DIR=$(mktemp -d)
echo "Created temporary directory: $TEMP_DIR"

# Array to store paths to package.xml files
package_files=()

# Check if release branch is in STORY_BRANCHES
RELEASE_INCLUDED=false
for b in $STORY_BRANCHES; do
  if [[ "$b" == "$RELEASE_BRANCH" ]]; then
    RELEASE_INCLUDED=true
    break
  fi
done

# If release branch is included, stash its package.xml before merging others
if $RELEASE_INCLUDED; then
  echo "Release branch is in STORY_BRANCHES — stashing its package.xml"
  git checkout -q "$RELEASE_BRANCH" -- manifest/package.xml
  release_package_file="$TEMP_DIR/package_${RELEASE_BRANCH//\//_}.xml"
  cp manifest/package.xml "$release_package_file"
  package_files+=("-f" "$release_package_file")
fi

# Merge each story branch (excluding the release branch itself)
for branch in $STORY_BRANCHES; do
  if [[ "$branch" == "$RELEASE_BRANCH" ]]; then
    echo "Skipping merge of release branch into itself: $branch"
    continue
  fi
  echo "Merging branch: $branch"
  git merge --no-ff -X theirs "origin/$branch" -m "Merging $branch into $RELEASE_BRANCH"
done

# Extract package.xml from each story branch (excluding release branch)
for branch in $STORY_BRANCHES; do
  if [[ "$branch" == "$RELEASE_BRANCH" ]]; then
    continue
  fi
  branch_name=${branch#origin/}
  echo "Checking out manifest/package.xml from origin/$branch_name"

  git checkout "origin/$branch_name" -- manifest/package.xml
  if [ $? -ne 0 ]; then
    echo "Failed to checkout manifest/package.xml from branch $branch_name"
    continue
  fi

  package_file="$TEMP_DIR/package_${branch_name//\//_}.xml"
  cp manifest/package.xml "$package_file"
  package_files+=("-f" "$package_file")
done

# Run the sfpc combine command
if [ ${#package_files[@]} -gt 0 ]; then
  echo "Running sfpc combine command..."
  sf sfpc combine "${package_files[@]}" -c "manifest/package.xml"
else
  echo "No package files found to combine."
  exit 1
fi

# Clean up the temporary directory
rm -rf "$TEMP_DIR"
echo "Cleaned up temporary directory: $TEMP_DIR"
git add manifest
git commit -m "Combined manifest/package.xml from story branches into $RELEASE_BRANCH"
git push "https://${MAINTAINER_PAT_NAME}:${MAINTAINER_PAT_VALUE}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" $RELEASE_BRANCH

git -c advice.detachedHead=false checkout -q $CI_COMMIT_SHORT_SHA
git branch -D $RELEASE_BRANCH

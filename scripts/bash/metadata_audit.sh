#!/bin/bash
################################################################################
# Script: metadata_audit.sh
# Description:
#   Audits metadata deployed by specific development teams over a time period
#   by extracting and combining package.xml files from merge commits.
#   For each team, it:
#     - Builds a combined manifest (package.xml)
#     - Builds a git diff summary of relevant merge commits
#     - Calls ALFA LLM gateway with a PAT to generate an AI summary (Markdown)
#     - Uploads both manifest and summary as attachments to a Confluence page
#
# Usage:
#   Called from a scheduled CI/CD pipeline (e.g., weekly)
#
# Dependencies:
#   - git
#   - Salesforce CLI (sf sfpc)
#   - curl
#   - jq
#
# Required Environment Variables:
#   # Confluence
#   - CONFLUENCE_USER
#   - CONFLUENCE_TOKEN
#   - CONFLUENCE_PAGE_ID      # e.g. 638886675099 (Metadata Manifest Audits 2026)
#
#   # ALFA LLM Gateway (PAT/API Secret from ALFA Portal)
#   - ALFA_PROXY_URL          # e.g. https://alfa.gamma.qa.us-west-2.aws.avalara.io
#   - ALFA_PROJECT_UUID       # your ALFA project UUID
#   - ALFA_PAT_TOKEN          # PAT/API Secret from ALFA Portal (x-alfa-authorization)
#
# Teams Tracked:
#   q2c, leadz, sfxpro, storm, shield
################################################################################

# set +e

# --- Required env var checks ---------------------------------------------------

: "${CONFLUENCE_USER:?Must set CONFLUENCE_USER}"
: "${CONFLUENCE_TOKEN:?Must set CONFLUENCE_TOKEN}"
: "${CONFLUENCE_PAGE_ID:?Must set CONFLUENCE_PAGE_ID}"

: "${ALFA_PROXY_URL:?Must set ALFA_PROXY_URL, e.g. https://alfa.gamma.qa.us-west-2.aws.avalara.io}"
: "${ALFA_PROJECT_UUID:?Must set ALFA_PROJECT_UUID (ALFA project UUID)}"
: "${ALFA_PAT_TOKEN:?Must set ALFA_PAT_TOKEN (PAT/API Secret from ALFA Portal)}"

# --- ALFA helper: call LLM via OpenAI-compatible /v1/chat/completions ---------

generate_ai_summary() {
  local team="$1"
  local timestamp="$2"
  local diff_file="$3"
  local manifest_file="$4"
  local out_file="$5"

  echo "Generating ALFA AI summary for team '${team}'..."

  # System prompt as a Bash variable
  local system_prompt
  read -r -d '' system_prompt <<'EOF'
You are a senior Salesforce architect summarizing weekly production metadata deployments for internal developers.
Given git diffs and a combined package.xml, produce a concise, developer-focused summary in Markdown.
Use sections: Highlights, Risky or breaking changes, Data model changes, Automation & flows, Security & access.
Group related changes; do not list every individual component or file.
EOF

  # Build OpenAI-compatible payload for ALFA LLM proxy
  local payload
  payload=$(jq -n \
    --arg team "$team" \
    --arg ts "$timestamp" \
    --arg sys "$system_prompt" \
    --rawfile diff "$diff_file" \
    --rawfile manifest "$manifest_file" '
  {
    "model": "gpt-4o-mini",
    "temperature": 0.2,
    "max_tokens": 1024,
    "messages": [
      {
        "role": "system",
        "content": $sys
      },
      {
        "role": "user",
        "content": (
          "Team: " + $team + "\nDate: " + $ts +
          "\n\n=== Git diff (name-status + commit messages) ===\n" + $diff +
          "\n\n=== Combined package.xml ===\n" + $manifest
        )
      }
    ]
  }')

  # Call ALFA and capture both body and HTTP status
  local response http_code body
  response=$(curl -sS "${ALFA_PROXY_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "x-alfa-authorization: ${ALFA_PAT_TOKEN}" \
    -H "Authorization: Bearer sk-${ALFA_PROJECT_UUID}" \
    -d "$payload" \
    -w '\n%{http_code}') || {
      echo "ERROR: curl call to ALFA failed for team '${team}'"
      return 1
    }

  http_code=$(printf '%s\n' "$response" | tail -n1)
  body=$(printf '%s\n' "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    echo "ERROR: ALFA returned HTTP $http_code for team '${team}'"
    echo "ALFA response body:"
    echo "$body"
    return 1
  fi

  # Parse LLM response
  if ! printf '%s\n' "$body" | jq -r '.choices[0].message.content' > "$out_file"; then
    echo "ERROR: Failed to parse ALFA response for team '${team}'"
    echo "Raw body was:"
    echo "$body"
    return 1
  fi

  if [[ ! -s "$out_file" ]]; then
    echo "WARNING: Empty summary generated for team '${team}'"
  else
    echo "AI summary written to ${out_file}"
  fi
}

# --- Git setup ----------------------------------------------------------------

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

# --- Main loop: per-team processing ------------------------------------------

for team in "${!teams[@]}"; do
  keyword="${teams[$team]}"
  manifest_dir="${team}_manifests"
  manifest_file="${team}-manifest-${timestamp}.xml"
  diff_file="${team}-diff-${timestamp}.txt"
  summary_file="${team}-summary-${timestamp}.md"

  echo
  echo "============================================================"
  echo "Processing team: ${team} (keyword: ${keyword})"
  echo "============================================================"

  mkdir -p "$manifest_dir"
  : > "$diff_file"

  # Find merge commits in the last week whose subject contains the team keyword
  git log origin/main \
    --since="1 week ago" \
    --merges \
    --pretty=format:"%H %s" | \
    grep -i "$keyword" | \
    awk '{print $1}' | \
    while read -r commit; do
      # Re-fetch subject for cleaner logging and diff header
      subject=$(git log -1 --pretty=format:"%s" "$commit" 2>/dev/null || echo "")

      echo "  Commit: $commit $subject"

      # Extract manifest/package.xml from that commit, if present
      git show "$commit:manifest/package.xml" > "$manifest_dir/$commit-package.xml" 2>/dev/null || \
        echo "    NOTE: manifest/package.xml missing in $commit for team ${team}"

      # Append a compact diff (name-status) for ALFA context
      {
        echo "## $commit $subject"
        git diff --name-status "${commit}^" "$commit" || true
        echo
      } >> "$diff_file"
    done

  # Combine manifests into a single package.xml for this team
  echo "Combining manifests for team ${team} into ${manifest_file}..."
  sf sfpc combine -d "$manifest_dir" -c "$manifest_file" -n

  if [[ ! -f "$manifest_file" ]]; then
    echo "WARNING: Combined manifest ${manifest_file} not created for team ${team}; skipping upload and AI summary."
    continue
  fi

  # Generate AI summary using git diff + combined manifest (if we had any commits)
  if [[ -s "$diff_file" ]]; then
    generate_ai_summary "$team" "$timestamp" "$diff_file" "$manifest_file" "$summary_file"
  else
    echo "No matching merge commits found for team ${team} in the last week; skipping AI summary."
    # Still upload manifest so the week is tracked even if no AI summary
  fi

  # Upload manifest to Confluence
  echo "Uploading manifest ${manifest_file} to Confluence page ${CONFLUENCE_PAGE_ID}..."
  curl -sS -u "$CONFLUENCE_USER:$CONFLUENCE_TOKEN" \
    -X POST \
    -H "X-Atlassian-Token: no-check" \
    -F "file=@${manifest_file}" \
    "https://avalara.atlassian.net/wiki/rest/api/content/${CONFLUENCE_PAGE_ID}/child/attachment" \
    >/dev/null || echo "WARNING: Failed to upload ${manifest_file} for team ${team}"

  # Upload AI summary (if generated) to Confluence
  if [[ -s "$summary_file" ]]; then
    echo "Uploading AI summary ${summary_file} to Confluence page ${CONFLUENCE_PAGE_ID}..."
    curl -sS -u "$CONFLUENCE_USER:$CONFLUENCE_TOKEN" \
      -X POST \
      -H "X-Atlassian-Token: no-check" \
      -F "file=@${summary_file}" \
      "https://avalara.atlassian.net/wiki/rest/api/content/${CONFLUENCE_PAGE_ID}/child/attachment" \
      >/dev/null || echo "WARNING: Failed to upload ${summary_file} for team ${team}"
  else
    echo "No AI summary file for team ${team}; nothing to upload."
  fi

done

echo
echo "Metadata audit and ALFA summaries complete."

#!/bin/bash
################################################################################
# Script: metadata_audit.sh
# Description:
#   Audits metadata deployed by specific development teams over a time period
#   by extracting and combining package.xml files from merge commits.
#   For each team, it:
#     - Builds a combined manifest (package.xml)
#     - Builds git context for relevant merge commits (name-status + unified patches vs first parent)
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
# Optional:
#   - METADATA_AUDIT_FAIL_ON_ALFA_ERROR=1  # exit the job if ALFA fails (default: warn and continue so Confluence uploads still run)
#   - METADATA_AUDIT_DIFF_PATHSPECS="force-app manifest"  # space-separated git pathspecs for patches (limits payload size)
#   - METADATA_AUDIT_DIFF_CONTEXT=2   # unified diff context lines (-U) per patch hunk
#   - METADATA_AUDIT_MAX_PATCH_BYTES_PER_COMMIT=131072  # cap patch bytes per merge commit (rest omitted with a marker)
#   - METADATA_AUDIT_ALFA_MAX_TOKENS=2048  # completion budget for the single per-team ALFA call
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

# Avoid double slashes in API URL when CI variables include a trailing slash
ALFA_PROXY_URL="${ALFA_PROXY_URL%/}"

# Git → ALFA: limit patch size (one combined payload per team)
read -r -a METADATA_AUDIT_DIFF_PATHSPECS <<< "${METADATA_AUDIT_DIFF_PATHSPECS:-force-app manifest}"
METADATA_AUDIT_DIFF_CONTEXT="${METADATA_AUDIT_DIFF_CONTEXT:-2}"
METADATA_AUDIT_MAX_PATCH_BYTES_PER_COMMIT="${METADATA_AUDIT_MAX_PATCH_BYTES_PER_COMMIT:-131072}"
METADATA_AUDIT_ALFA_MAX_TOKENS="${METADATA_AUDIT_ALFA_MAX_TOKENS:-2048}"

# Append one merge commit's name-status + unified patch (vs first parent) for ALFA context.
append_merge_commit_alfa_context() {
  local commit="$1"
  local subject="$2"
  local out="$3"
  local patch_tmp bytes max_b

  patch_tmp=$(mktemp) || {
    echo "    WARNING: mktemp failed; skipping patch body for ${commit}"
    {
      echo "## Merge commit ${commit}"
      echo "**${subject}**"
      echo
      echo "### Files changed (name-status)"
      git diff --name-status "${commit}^1" "$commit" -- "${METADATA_AUDIT_DIFF_PATHSPECS[@]}" 2>/dev/null || true
      echo
    } >> "$out"
    return 0
  }

  git diff --no-color "-U${METADATA_AUDIT_DIFF_CONTEXT}" "${commit}^1" "$commit" -- \
    "${METADATA_AUDIT_DIFF_PATHSPECS[@]}" 2>/dev/null >"$patch_tmp" || true

  bytes=$(wc -c <"$patch_tmp" | tr -d ' \t\r\n')
  max_b="${METADATA_AUDIT_MAX_PATCH_BYTES_PER_COMMIT}"

  {
    echo "## Merge commit ${commit}"
    echo "**${subject}**"
    echo
    echo "### Files changed (name-status)"
    git diff --name-status "${commit}^1" "$commit" -- "${METADATA_AUDIT_DIFF_PATHSPECS[@]}" 2>/dev/null || true
    echo
    echo "### Patch (unified diff: first parent ^1 → merge; scoped pathspecs)"
    if [[ -n "$bytes" && "$bytes" =~ ^[0-9]+$ && "$bytes" -gt "$max_b" ]]; then
      head -c "$max_b" "$patch_tmp"
      printf '\n\n[... PATCH TRUNCATED: %s bytes for this commit, showing first %s bytes ...]\n' "$bytes" "$max_b"
    else
      cat "$patch_tmp"
    fi
    echo
    echo
  } >>"$out"

  rm -f "$patch_tmp"
}

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
You receive, per merge commit: a subject line, name-status of files changed, and a unified git patch (first parent → merge) scoped to Salesforce metadata paths. Patches may be truncated mid-commit with an explicit marker—do not infer changes beyond visible lines.
Explain what functionality changed: user-visible behavior, automations, integrations, data model, and security/access. Tie claims to the patch when possible.
Produce a concise, developer-focused summary in Markdown.
Use sections: Highlights, Risky or breaking changes, Data model changes, Automation & flows, Security & access.
Group related changes; do not list every individual component or file. Where multiple merge commits appear, briefly separate notable themes by commit when helpful.
EOF

  # Build OpenAI-compatible JSON for ALFA (write to a temp file so curl does not hit
  # "Argument list too long" on Windows/Git Bash when diffs + manifest are large.)
  local payload_tmp
  payload_tmp=$(mktemp) || {
    echo "ERROR: mktemp failed for ALFA payload for team '${team}'"
    return 1
  }
  if ! jq -n \
    --arg team "$team" \
    --arg ts "$timestamp" \
    --arg sys "$system_prompt" \
    --argjson max_tokens "${METADATA_AUDIT_ALFA_MAX_TOKENS}" \
    --rawfile diff "$diff_file" \
    --rawfile manifest "$manifest_file" '
  {
    "model": "gpt-4o-mini",
    "temperature": 0.2,
    "max_tokens": $max_tokens,
    "messages": [
      {
        "role": "system",
        "content": $sys
      },
      {
        "role": "user",
        "content": (
          "Team: " + $team + "\nDate: " + $ts +
          "\n\n=== Git context (per merge: name-status + unified patches; patches may be truncated per commit) ===\n" + $diff +
          "\n\n=== Combined package.xml ===\n" + $manifest
        )
      }
    ]
  }' >"$payload_tmp"; then
    echo "ERROR: jq failed building ALFA request payload for team '${team}' (check diff/manifest size and UTF-8)."
    rm -f "$payload_tmp"
    return 1
  fi

  # Call ALFA and capture both body and HTTP status (body from file, not argv)
  local response http_code body
  response=$(curl -sS "${ALFA_PROXY_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "x-alfa-authorization: ${ALFA_PAT_TOKEN}" \
    -H "Authorization: Bearer sk-${ALFA_PROJECT_UUID}" \
    --data-binary @"$payload_tmp" \
    -w '\n%{http_code}') || {
      echo "ERROR: curl call to ALFA failed for team '${team}'"
      rm -f "$payload_tmp"
      return 1
    }
  rm -f "$payload_tmp"

  http_code=$(printf '%s\n' "$response" | tail -n1)
  body=$(printf '%s\n' "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    echo "ERROR: ALFA returned HTTP $http_code for team '${team}'"
    echo "ALFA response body (first 4k):"
    printf '%s' "$body" | head -c 4096
    echo
    return 1
  fi

  # Parse LLM response (OpenAI-compatible shape)
  if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    echo "ERROR: ALFA returned HTTP 200 but body is not valid JSON for team '${team}'"
    printf '%s' "$body" | head -c 4096
    echo
    return 1
  fi

  local content
  content=$(printf '%s' "$body" | jq -r '.choices[0].message.content // empty')
  if [[ -z "$content" ]]; then
    echo "ERROR: ALFA JSON had no .choices[0].message.content for team '${team}'"
    printf '%s' "$body" | head -c 4096
    echo
    return 1
  fi

  printf '%s\n' "$content" > "$out_file"
  echo "AI summary written to ${out_file}"
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

      # Append name-status + unified patch (vs first parent) for ALFA context (one team payload → one ALFA call)
      append_merge_commit_alfa_context "$commit" "$subject" "$diff_file"
    done

  # Combine manifests into a single package.xml for this team
  echo "Combining manifests for team ${team} into ${manifest_file}..."
  sf sfpc combine -d "$manifest_dir" -c "$manifest_file" -n

  if [[ ! -f "$manifest_file" ]]; then
    echo "WARNING: Combined manifest ${manifest_file} not created for team ${team}; skipping upload and AI summary."
    continue
  fi

  # Generate AI summary using git diff + combined manifest (if we had any commits).
  # Use "if ! ..." so a failed summary does not abort the whole script under "set -e" (e.g. GitLab CI).
  if [[ -s "$diff_file" ]]; then
    if ! generate_ai_summary "$team" "$timestamp" "$diff_file" "$manifest_file" "$summary_file"; then
      echo "WARNING: ALFA AI summary failed for team '${team}'. Manifest will still upload. Check ALFA_PROXY_URL, ALFA_PROJECT_UUID, ALFA_PAT_TOKEN, and gateway reachability from the runner." >&2
      if [[ "${METADATA_AUDIT_FAIL_ON_ALFA_ERROR:-}" == "1" ]]; then
        exit 1
      fi
    fi
  else
    echo "No matching merge commits found for team ${team} in the last week; skipping AI summary."
    # Still upload manifest so the week is tracked even if no AI summary
  fi

  # Upload manifest to Confluence (PUT = create *or* new version if filename exists; POST only creates new)
  echo "Uploading manifest ${manifest_file} to Confluence page ${CONFLUENCE_PAGE_ID}..."
  curl -sS -u "$CONFLUENCE_USER:$CONFLUENCE_TOKEN" \
    -X PUT \
    -H "X-Atlassian-Token: nocheck" \
    -F "file=@${manifest_file}" \
    -F 'minorEdit=true' \
    -F "comment=metadata_audit ${timestamp} ${team} manifest; type=text/plain; charset=utf-8" \
    "https://avalara.atlassian.net/wiki/rest/api/content/${CONFLUENCE_PAGE_ID}/child/attachment" \
    >/dev/null || echo "WARNING: Failed to upload ${manifest_file} for team ${team}"

  # Upload AI summary (if generated) to Confluence
  if [[ -s "$summary_file" ]]; then
    echo "Uploading AI summary ${summary_file} to Confluence page ${CONFLUENCE_PAGE_ID}..."
    curl -sS -u "$CONFLUENCE_USER:$CONFLUENCE_TOKEN" \
      -X PUT \
      -H "X-Atlassian-Token: nocheck" \
      -F "file=@${summary_file}" \
      -F 'minorEdit=true' \
      -F "comment=metadata_audit ${timestamp} ${team} ALFA summary; type=text/plain; charset=utf-8" \
      "https://avalara.atlassian.net/wiki/rest/api/content/${CONFLUENCE_PAGE_ID}/child/attachment" \
      >/dev/null || echo "WARNING: Failed to upload ${summary_file} for team ${team}"
  else
    echo "No AI summary file for team ${team}; nothing to upload."
  fi

done

echo
echo "Metadata audit and ALFA summaries complete."

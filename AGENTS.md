# AGENTS.md (Generalized for Salesforce DX GitLab Repos)

Orientation file for coding agents (Cursor, Claude Code, Codex, Aider, etc.).  
This document provides **context and guardrails**, not exhaustive rules.  
Defer to your tool’s capabilities and developer instructions when appropriate.

---

## What this repo is

This is a **Salesforce DX (SFDX) metadata repository** deployed via **GitLab CI/CD** across multiple environments.

### Core characteristics

- **Manifest-driven deployments**
  - Only metadata explicitly listed in `manifest/package.xml` is deployed
  - No wildcards allowed
  - The manifest must be **generated per Merge Request (MR)** and include **only that MR’s delta**
  - Always **overwrite**, never append or accumulate entries

- **Apex test selection via annotations**
  - CI executes only tests referenced in `@tests:` annotations on changed classes

- **Promotion-based delivery model**
  - The same story branch is promoted across environments via separate MRs

---

## Branching & environment model

| Environment | Purpose | Branch | Deployment Trigger |
|------------|--------|--------|--------------------|
| Dev (Shared) | Integration | `develop` | Merge to `develop` |
| QA / UAT | Validation | `fullqa` | Merge to `fullqa` |
| Production | Live | `main` | Merge to `main` |

### Promotion flow (required)

```
story branch → develop → fullqa → main
```

- **Three MRs per change are required**
- Each MR must originate from the **same story branch**
- Do not rely on branch-to-branch merges for promotion

---

## Universal hard rules

These apply to all agents and contributors:

1. **No secrets in commits**
   - Never commit credentials, tokens, keys, or `.env` files

2. **No direct pushes to protected branches**
   - `develop`, `fullqa`, and `main` are protected
   - Always use feature branches + MRs

3. **Do not edit profiles**
   - Profiles are managed outside the repo
   - Use **Permission Sets** instead

4. **Branch from `main` only**
   - Do not branch from `develop` or `fullqa`

---

## Manifest (`package.xml`) rules

This is the **most common failure point**.

- Must contain **ONLY metadata changed in the current MR**
- Must be **fully regenerated each time**
- Must **not include entries from previous work**
- Must **not use wildcards**

### Correct behavior

- Generate from git diff
- Overwrite existing file
- Include only added/modified components

### Incorrect behavior

- Appending entries
- Keeping previous entries
- Merging manifests across branches

CI will fail if the manifest does not match the actual delta.

---

## Conflict resolution rules

### General

- Resolve conflicts **locally using git**
- Do **not** use GitLab UI conflict resolver
- Do **not** rebase story branches
- Do **not** merge target branches into story branches

---

### `manifest/package.xml`

- Always take the **story branch version**
- Do not merge entries
- Must reflect only current MR changes

---

### `force-app/` metadata

- Resolve **manually and intentionally**
- Preserve:
  - Intended story branch changes
  - Necessary target branch changes
- Escalate if unclear

---

## Repository structure (typical)

```
force-app/main/default/
  classes/
  triggers/
  objects/
  flows/
  layouts/
  lwc/
  aura/
  permissionsets/
  profiles/        (read-only)
  customMetadata/
```

### Notes

- Profiles are **read-only**
- Permission Sets control access
- Custom Metadata often drives business logic and has high impact

---

## CI/CD entry points

- `.gitlab-ci.yml` — pipeline definition
- `manifest/package.xml` — deployment scope
- `manifest/destructiveChanges.xml` — deletions
- `scripts/` — deployment and validation logic

---

## Toolchain expectations

- Salesforce CLI (`sf`)
- Python (for validation scripts)
- GitLab CI runners (Docker-based)
- Pre-commit hooks (lint + secret scanning)

---

## Common pitfalls (“sharp edges”)

1. **Manifest errors**
   - Must match git delta exactly
   - Most frequent cause of CI failure

2. **Missing `@tests:` annotations**
   - Results in zero tests running

3. **Profiles edited**
   - Changes ignored or rejected

4. **Wrong branching strategy**
   - Leads to conflicts during promotion

5. **Secrets in commits**
   - Blocked by hooks or CI

6. **Environment-specific values**
   - Should not be hardcoded (handled at deploy time)

---

## Agent guidance: change types

### Good candidates for automation

- Apex test classes
- Validation rules
- Permission set updates
- Documentation
- Small refactors with existing coverage
- Custom labels and translations

---

### Requires human review

- Flows (high blast radius)
- Custom Metadata changes
- Triggers
- Destructive changes
- Managed package metadata

---

## MR review checklist

Agents should ensure:

1. **Manifest correctness**
   - Only current MR changes included

2. **Apex test annotations present**
   - All changed classes include `@tests:`

3. **No secrets**
   - No credentials or sensitive data

4. **No profile edits**

5. **Proper reviewers assigned**

6. **Sandbox validation completed**

---

## Sandbox usage

- Personal sandbox → development/testing
- Dev sandbox → integration validation
- QA sandbox → business validation
- Production → final deployment

---

## General Salesforce guidance

- Prefer **declarative solutions (OOB)** over code
- Follow naming conventions for metadata
- Use **Permission Sets**, not profiles
- Avoid hardcoding IDs or environment-specific values

---

## Working principles for agents

- Treat `package.xml` as **ephemeral**
- Always generate it from the current diff
- Prioritize **safe, minimal changes**
- Avoid modifying unrelated metadata
- Escalate when impact is unclear
- Preserve **promotion integrity across environments**

---

## Final note

This file provides **constraints and patterns**, not exhaustive instructions.

Agents should:
- Follow repository conventions
- Respect CI/CD validation rules
- Defer to developer guidance when necessary

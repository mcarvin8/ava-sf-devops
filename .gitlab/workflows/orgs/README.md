# Org-Specific CI/CD Configuration

This directory contains individual YAML files for each Salesforce org that participates in the CI/CD pipeline. Each org has its own dedicated file containing all deployment jobs (test, deploy, destroy, merge) for that specific environment.

## 📁 Current Orgs

- **`dev.yml`** - Common development sandbox environment  
- **`fullqa.yml`** - Full QA sandbox environment
- **`production.yml`** - Production environment

## 🚀 Adding a New Org

Follow these steps to add a new Salesforce org to the CI/CD pipeline:

### Step 1: Create the Org YAML File

1. **Copy an existing org file** as your template:
   ```bash
   cp .gitlab/orgs/dev.yml .gitlab/orgs/staging.yml
   ```

2. **Edit the new file** with org-specific details:
   ```yaml
   ####################################################
   # Staging Org Jobs
   # All deployment jobs for the staging environment
   ####################################################
   
   test:predeploy:staging:
     extends: .validate-metadata
     stage: test
     resource_group: staging
     rules:
       - if: $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME == 'develop' || $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME == 'fullqa' || $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME == $CI_DEFAULT_BRANCH # ← Update branch names to the other orgs tracked in CI/CD (never allow other org branches to be merged into each other)
         when: never
       - if: $CI_MERGE_REQUEST_TARGET_BRANCH_NAME == 'staging'  # ← Update branch name
         when: manual
     allow_failure: false
     variables:
       AUTH_ALIAS: STAGING                    # ← Update alias
       AUTH_URL: $STAGING_AUTH_URL           # ← Update URL variable
     environment:
       name: validate-staging                # ← Update environment name
       url: https://avalara--staging.sandbox.my.salesforce.com  # ← Update org URL
     tags: 
       - aws,prd,us-west-2
   
   # ... repeat for deploy:staging, destroy:staging, merge:staging
   ```

### Step 2: Update Job Names and Variables

For each job in your new org file, update:

#### **Job Names:**
- `test:predeploy:staging`
- `deploy:staging`
- `destroy:staging`
- `merge:staging`

#### **Resource Groups:**
- `resource_group: staging`
- `resource_group: merge-staging`

#### **Rules (Branch Names):**
- `$CI_MERGE_REQUEST_TARGET_BRANCH_NAME == 'staging'`
- `$CI_COMMIT_REF_NAME == 'staging'`

#### **Variables:**
- `AUTH_ALIAS: STAGING`
- `AUTH_URL: $STAGING_AUTH_URL`
- `GT_ANNOTATION_ENVIRONMENT: staging` (for deploy/destroy jobs)
- Disable variable: `$STAGING_DISABLED` (for deploy/destroy jobs)

#### **Environment Names:**
- `name: validate-staging` (for test job)
- `name: staging` (for deploy/destroy/merge jobs)
- `url: https://your-org-url.salesforce.com`

### Step 3: Include the New Org File

Add your new org file to the main `.gitlab-ci.yml` includes section:

```yaml
include:
  - project: sre/gitlab-templates
    ref: v4
    file:
      - functions/grafana/deployment-annotation/deployment-annotation.yml
  - local: '.gitlab/base-templates.yml'
  - local: '.gitlab/core-jobs.yml'
  - local: '.gitlab/test-quality-jobs.yml'
  - local: '.gitlab/maintenance-pipeline.yml'
  # Org-specific job definitions
  - local: '.gitlab/orgs/dev.yml'
  - local: '.gitlab/orgs/fullqa.yml'
  - local: '.gitlab/orgs/production.yml'
  - local: '.gitlab/orgs/staging.yml'        # ← Add your new org here
```

### Step 4: Configure GitLab Variables

In your GitLab project settings, add the required CI/CD variables:

- **`STAGING_AUTH_URL`** - Salesforce authentication URL for the staging org
- **`STAGING_DISABLED`** - Optional variable to disable deployments to staging

### Step 5: Test Your Configuration

1. **Validate YAML syntax:**
   ```bash
   # Use GitLab CI Lint tool or local YAML validator
   ```

2. **Create a test branch:**
   ```bash
   git checkout -b test-staging-ci
   git add .gitlab/orgs/staging.yml .gitlab-ci.yml
   git commit -m "Add staging org to CI/CD pipeline"
   git push origin test-staging-ci
   ```

3. **Create a merge request** targeting the `staging` branch to test the new jobs

## 🔧 Updating an Existing Org

To modify an existing org's configuration:

1. **Edit the org's YAML file** directly (e.g., `.gitlab/orgs/staging.yml`)
2. **Make your changes** (rules, variables, environment URLs, etc.)
3. **Test the changes** with a merge request or pipeline run
4. **No other files need to be modified** - changes are isolated to that org

## 🗑️ Removing an Org

To remove an org from CI/CD:

1. **Delete the org's YAML file:**
   ```bash
   rm .gitlab/orgs/staging.yml
   ```

2. **Remove the include line** from `.gitlab-ci.yml`:
   ```yaml
   # Remove this line:
   - local: '.gitlab/orgs/staging.yml'
   ```

3. **Clean up GitLab variables** (optional):
   - Remove `STAGING_AUTH_URL`, `STAGING_DISABLED`, etc.

## 📋 Org File Template

Here's a complete template for a new org file:

```yaml
####################################################
# [ORG_NAME] Org Jobs
# All deployment jobs for the [org description] environment
####################################################

test:predeploy:[ORG_NAME]:
  extends: .validate-metadata
  stage: test
  resource_group: [ORG_NAME]
  rules:
    - if: $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME == 'develop' || $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME == 'fullqa' || $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME == $CI_DEFAULT_BRANCH
      when: never
    - if: $CI_MERGE_REQUEST_TARGET_BRANCH_NAME == '[BRANCH_NAME]'
      when: manual
  allow_failure: false
  variables:
    AUTH_ALIAS: [AUTH_ALIAS]
    AUTH_URL: $[AUTH_URL_VAR]
  environment:
    name: validate-[ORG_NAME]
    url: [SALESFORCE_ORG_URL]
  tags: 
    - aws,prd,us-west-2

deploy:[ORG_NAME]:
  extends: .deploy-metadata
  stage: deploy
  resource_group: [ORG_NAME]
  rules:
    - if: $[DISABLED_VAR]
      when: never
    - if: $CI_COMMIT_REF_NAME == '[BRANCH_NAME]' && $CI_PIPELINE_SOURCE == 'push'
      when: always
  allow_failure: false
  variables:
    AUTH_ALIAS: [AUTH_ALIAS]
    AUTH_URL: $[AUTH_URL_VAR]
    GT_ANNOTATION_ENVIRONMENT: [ORG_NAME]
  environment:
    name: [ORG_NAME]
    url: [SALESFORCE_ORG_URL]
  tags: 
    - aws,prd,us-west-2

destroy:[ORG_NAME]:
  extends: .delete-metadata
  stage: destroy
  resource_group: [ORG_NAME]
  rules:
    - if: $[DISABLED_VAR]
      when: never
    - if: $CI_COMMIT_REF_NAME == '[BRANCH_NAME]' && $CI_PIPELINE_SOURCE == 'web' && $PACKAGE
      when: always
  allow_failure: false
  variables:
    AUTH_ALIAS: [AUTH_ALIAS]
    AUTH_URL: $[AUTH_URL_VAR]
    GT_ANNOTATION_ENVIRONMENT: [ORG_NAME]
  environment:
    name: [ORG_NAME]
    url: [SALESFORCE_ORG_URL]
  tags: 
    - aws,prd,us-west-2

merge:[ORG_NAME]:
  extends: .auto-merge
  stage: merge
  resource_group: merge-[ORG_NAME]
  needs: []
  rules:
    - if: $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME == 'develop' || $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME == 'fullqa' || $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME == $CI_DEFAULT_BRANCH
      when: never
    - if: $CI_MERGE_REQUEST_TARGET_BRANCH_NAME == '[BRANCH_NAME]'
      when: manual
  allow_failure: false
  environment:
    name: [ORG_NAME]
    url: [SALESFORCE_ORG_URL]
  tags: 
    - aws,prd,us-west-2
```

### Template Placeholders:

- **`[ORG_NAME]`** - Short org name (e.g., `staging`, `uat`, `demo`)
- **`[BRANCH_NAME]`** - Git branch name for this org (usually same as org name)
- **`[AUTH_ALIAS]`** - Salesforce CLI alias (usually uppercase org name)
- **`[AUTH_URL_VAR]`** - GitLab CI variable name for auth URL (e.g., `STAGING_AUTH_URL`)
- **`[DISABLED_VAR]`** - GitLab CI variable to disable deployments (e.g., `STAGING_DISABLED`)
- **`[SALESFORCE_ORG_URL]`** - Full Salesforce org URL

## 💡 Best Practices

1. **Use descriptive org names** that match your branch naming convention
2. **Keep variable names consistent** across orgs (follow existing patterns)
3. **Test new orgs thoroughly** before merging to main
4. **Document any special rules** or configurations in the org file comments
5. **Use meaningful environment names** for GitLab environment tracking
6. **Follow the existing resource group patterns** to avoid conflicts

## 🔍 Troubleshooting

### Common Issues:

- **Jobs not appearing**: Check that the include line is added to `.gitlab-ci.yml`
- **Authentication failures**: Verify `AUTH_URL` variable is set correctly
- **Rule conflicts**: Ensure branch names in rules match your Git branches
- **Resource group conflicts**: Make sure resource group names are unique per org

### Debugging Tips:

- Use GitLab CI Lint tool to validate YAML syntax
- Check GitLab CI/CD > Variables for required environment variables
- Review pipeline logs for specific error messages
- Compare working org files with problematic ones

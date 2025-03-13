# ava-sf-devops

This repository demonstrates how to use GitLab actions, the Salesforce CLI (`sf`), Salesforce CLI plugins, and bash scripts to validate, deploy, or destroy metadata in a Salesforce org following the org development model, without using packages/scratch orgs.

The model uses these Salesforce CLI plugins:
1. [sfdx-git-delta](https://github.com/scolladon/sfdx-git-delta)
2. [apex-tests-list](https://github.com/renatoliveira/apex-test-list)
3. [apex-code-coverage-transformer](https://github.com/mcarvin8/apex-code-coverage-transformer)
4. [sf-package-combiner](https://github.com/mcarvin8/sf-package-combiner)

## CI/CD Model

The CI/CD model in `.gitlab-ci.yml` follows the org branching model, where each Salesforce org has its own long-running Git branch. The rules in each org job can be customized based on your branching strategy.

## Pipeline Stages

### 1. Pipeline Stage (Optional Ad-Hoc Jobs)
These are optional ad-hoc jobs that can be removed if not needed.
   - **Rollback**: Roll back previous deployments via a web-based pipeline.
   - **ProdBackfill**: Used to refresh long-running branches with changes from `main` when merging into other long-running branches.

These jobs require a GitLab project access token to perform git operations. The token should have a "Maintainer" role with "api" and "write_repository" scope enabled.

These CI/CD variables should be configured in the repo with the token attributes:

- `BOT_NAME` should be the name of the project access token user
- `BOT_USER_NAME` should be the user name of the project access token user
- `PROJECT_TOKEN`  should contain the project access token value

### 2. Test Stage
This stage ensures that metadata changes are properly validated and tested.
   - **Validation**: When a merge request (MR) is opened, it will validate the metadata changes in the target org.
   - **Unit Testing**: A scheduled pipeline with `$JOB_NAME` set to "unitTest" runs all local tests in the target org.
     - Requires `$AUTH_URL` and `$AUTH_ALIAS` variables.
   - **Code Coverage**: The `apex-code-coverage-transformer` creates JaCoCo-formatted reports, which can be visualized in GitLab v17.

### 3. Quality Stage
This stage runs SonarQube scans (if applicable) after all test jobs.
   - Relies on JaCoCo coverage reports created by `apex-code-coverage-transformer` in the test jobs.
   - Can be modified or removed if SonarQube is not used.

### 4. Destroy Stage
Handles the deletion of metadata from the Salesforce org when files are deleted from the branch.
   - Jobs are allowed to fail if no metadata types are detected.
   - Destructive deployments are run before constructive deployments by default.
   - If destructive changes need to be deployed after constructive ones, cancel the `destroy` stage, allow `deploy` to complete, then re-run `destroy`.

### 5. Deploy Stage
Deploys constructive metadata changes to the target org.

## Declare Metadata to Deploy

This model uses a manifest file (`package.xml`) to run incremental deployments. The `sfdx-git-delta` plugin generates the package based on git diffs.

### Validations and Deployment Packages

Additional metadata can be declared in merge request descriptions or commit messages using the following format:

```
<Package>
MetadataType: Member1, Member2, Member3
MetadataType2: Member1, Member2, Member3
Version: 60.0
</Package>
```

> `scripts/bash/convert_package_to_list.sh` can be used to convert an existing package.xml, such as one created in Workbench, into the accepted list format.

This is combined with the `sfdx-git-delta` package using the `sf-package-combiner` plugin.

**Repo Recommendations**
- Update your GitLab repo settings to provide the tags in the default merge request description.

![Default Merge Request Description](.gitlab/images/default-merge-request-description.png)

- Update your GitLab repo settings to include the MR description automatically in the merge commit message. 

![Merge Commit Message Template](.gitlab/images/merge-commit-msg-template.png)

### Destructive Packages

The destroy job solely relies on the `sfdx-git-delta` destructive package.

## Declare Apex Tests

Apex tests are required for deployments and destructive changes containing Apex classes/triggers.

### Validation and Deployment Tests

The `apex-tests-list` plugin will determine the specified tests to run when validating and deploying.

- Tests must be annotated with `@tests:` or `@testsuites:` in Apex classes/triggers.

### Destructive Apex Tests

To destroy Apex in production, you must run Apex tests in the destructive deployment. Set the `DESTRUCTIVE_TESTS` variable in `.gitlab-ci.yml` with the pre-defined tests to run when destroying Apex in production.

> **Sandbox orgs do not require destructive tests.**

## Connected Apps
If connected apps are detected in a package, their `<consumerKey>` line is automatically removed before deployment to avoid failures.

## Slack Integration
Deployment, test, and destruction statuses can be posted to a Slack channel.
Update the webhook URL in `.gitlab-ci.yml`:
```yaml
SLACK_WEBHOOK_URL: https://hooks.slack.com/services/
```
To disable Slack notifications, remove this variable and the `scripts/bash/deploy_slack_status.sh` step.

## Branch Protection
### Validation Merge Request Pipelines
Enable "Pipelines must succeed" in GitLab's Merge Request settings to enforce validation before merging.

### Protected CI/CD Environments
Protect environments to restrict who can deploy changes. Validation environments (`validate-*`) can be left open, while destructive and deploy environments should be restricted.

## Bot Deployments
For Einstein Bots, update:
- `.forceignore` to exclude bot versions not to deploy.
- `scripts/replacementFiles` to configure the Bot User per org.
- `sfdx-project.json` to run the right `replacements` per environment variables

> If not using this feature, remove `replacements` from `sfdx-project.json`.

## Other CI/CD Platforms

Bash scripts in `scripts/bash` can be adapted for other CI/CD platforms if environment variables match GitLab's predefined CI/CD variables.

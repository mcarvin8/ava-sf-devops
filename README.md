# ava-sf-devops

This repository demonstrates how to use GitLab actions, the Salesforce CLI (`sf`), Salesforce CLI plugins, and bash scripts to validate, deploy, or destroy metadata in a Salesforce org following the org development model, without using packages/scratch orgs.

The model uses these Salesforce CLI plugins:
1. [sfdx-git-delta](https://github.com/scolladon/sfdx-git-delta)
2. [apex-tests-list](https://github.com/renatoliveira/apex-test-list)
3. [apex-code-coverage-transformer](https://github.com/mcarvin8/apex-code-coverage-transformer)
4. [sf-package-combiner](https://github.com/mcarvin8/sf-package-combiner)

## CI/CD Model

The CI/CD model in `.gitlab-ci.yml` is the org branching model, where each Salesforce org has its own long-running Git branch. The rules in each org job can easily be updated based on your branching strategy, i.e.
- update the branches in the rules to target the default branch upon merge to the default branch. Changes to default branch will trigger validations, deployments, and destructions in each org.
- update the sandbox jobs to run when a merge request is open against the default branch and update production jobs to run upon merge to the default branch

### Stages and Jobs

- `pipeline` stage = optional ad-hoc jobs which can be deleted if desired. See "Ad-Hoc Pipelines" section.
   - `rollback` job = roll-back previous deployments via a web-based pipeline.
   - `prodBackfill` job = If you create branches from `main` (default branch) but have to merge them into other long-running branches, this job can be used to refresh those long-running branches with changes from `main`.
- `test` stage = test changes before and after deployment
    - When a merge request (MR) is opened, it will validate the metadata changes in the target org.
    - When you create a scheduled pipeline with the `$JOB_NAME` as "unitTest", it will run all local tests in the target org.
        - Define `$AUTH_URL` and `$AUTH_ALIAS` when creating this scheduled pipeline.
        - See inspiration behind this method: https://www.pablogonzalez.io/how-to-schedule-run-all-tests-in-salesforce-with-github-actions-for-unlimited-salesforce-orgs-nothing-to-install/
    - All test jobs uses the apex-code-coverage-transformer to create the code coverage artifact in jacoco format. GitLab v17 can visualize code coverage in MRs with jacoco reports.
- `quality` stage = run SonarQube scans if you have SonarQube.
    - Runs after all `test` jobs and depends on the jacoco coverage report created by these jobs.
    - Delete or modify if you do not use SonarQube
- `destroy` stage = Destroy the metadata from the org if the files were deleted from the branch. 
    - Jobs are  allowed to fail and will fail if there are no metadata types detected in the destructive package.
    - This will be a standalone destructive deployment that will run before the deployment by default. 
    - If you need to deploy the destructive changes after the deployment, cancel the `destroy` stage when the pipeline is created, allow the `deploy` stage to complete, then re-run the `destroy` stage.
- `deploy` stage = Deploy constructive metadata changes to the target org.

## Slack Posts

The deployment, test, and destruction statuses can be posted to a Slack channel. Update the webhook variable in the `.gitlab-ci.yml` you use:

``` yaml
  # Update webhook URL here for your slack channel
  SLACK_WEBHOOK_URL: https://hooks.slack.com/services/
```

Delete this variable and the step in each `after_script` section that runs `scripts/bash/deploy_slack_status.sh` if you are not using slack.

## Declare Metadata to Deploy

This org model uses a manifest file (package.xml) to run incremental deployments.

All jobs use the sfdx-git-delta plugin to create a incremental package.xml via the git diff.

The packages created in each job are checked to search for Apex Classes, Apex Triggers, and Connected Apps.

### Validations and Deployment Packages

In addition to the sfdx-git-delta package, the developer can supply additional metadata to deploy by adding `package.xml` contents to the merge request description/commit message in package list format (see example below).

```
<Package>
MetadataType: Member1, Member2, Member3
MetadataType2: Member1, Member2, Member3
Version: 60.0
</Package>
```

The manual package contents should be in between `<Package>` and `</Package>` tags.
Update your GitLab repo settings to provide the tags in the default merge request description.

![Default Merge Request Description](.gitlab/images/default-merge-request-description.png)

Update your GitLab repo settings to include the MR description automatically in the merge commit message. 

![Merge Commit Message Template](.gitlab/images/merge-commit-msg-template.png)

The sfdx-git-delta package and commit message package are combined using the sf-package-combiner plugin to make the final package to deploy. If the commit message contains an API version via `Version:` (case insensitive), the sf-package-combiner will set the final package at that API version. Otherwise, the API version will be omitted from the package.xml to default to other source API version inputs.

`scripts/bash/convert_package_to_list.sh` can be used to convert an existing package.xml, such as one created in Workbench, into the accepted list format.

### Destructive Packages

The destroy job just uses the sfdx-git-delta destructive changes package.

## Declare Apex Tests

If Apex classes and triggers are found in the package, the pipeline will run specified tests during the deployment to satisfy code coverage requirements.

### Validations and Deployment Tests

The apex-tests-list plugin will determine the specified tests to run when validating and deploying.

You must add the `@tests:` or `@testsuites:` annotations to each Apex class/trigger per the [apex-test-list plugin documentation](https://github.com/renatoliveira/apex-test-list?tab=readme-ov-file#apex-test-list).

### Destructive Apex Tests

To destroy Apex in production, you must run Apex tests in the destructive deployment. Set the `DESTRUCTIVE_TESTS` variable in `.gitlab-ci.yml` with the pre-defined tests to run when destroying Apex in production.

> **Tests will not run when destroying Apex in sandboxes.**

### Connected Apps

If connected apps are found in the package for validations or deployments, the `<consumerKey>` line in each connected app meta file will be automatically removed before deployment. Deployments with connected apps will fail if you leave the consumer key in the file.

## Branch Protection

### Validation Merge Request Pipelines

In the "Merge requests" settings, you can enable "Pipelines must succeed" to ensure the merge request validation passes before the request can be accepted.

### Protected CI/CD Environments

You can protect each CI/CD environment to limit those who can deploy to the orgs.

The pre-deploy validation environments start with "validate-", which you can allow anyone to validate.

But for destructions and deployments, I would recommend protecting these environments to limit those who can permanently change the target org.

## Bot Deployments

To deploy Einstein Bots, you should update the `.forceignore` file with bot versions to not deploy/retrieve (such as the active bot version) and you should also update the `scripts/replacementFiles` with the Bot User for each org, if you are configuring the bot user. The metadata string replacements are done automatically by the Salesforce CLI before deployment and they are dependent on the `AUTH_ALIAS` variables configure in the `.gitlab-ci.yml`.

If you do not want to use this feature, remove the `replacements` key in the `sfdx-project.json`.

## Ad-Hoc Pipelines

The optional ad-hoc pipelines require a GitLab project access token to perform git operations. The token should have a "Maintainer" role with "api" and "write_repository" scope enabled.

These CI/CD variables should be configured in the repo with the token attributes:

- `BOT_NAME` should be the name of the project access token user
- `BOT_USER_NAME` should be the user name of the project access token user
- `PROJECT_TOKEN`  should contain the project access token value

The `rollback` pipeline is web-based. Go to the repo, then go to Build > Pipelines. Press "New pipeline". Select the applicable branch in "Run for branch name or tag". Enter 1 new CI/CD variable for the job. The variable key should be `SHA` and hte variable value should be the SHA to revert/roll-back.

## Other CI/CD Platforms

The bash scripts in `scripts/bash` could work on other CI/CD platforms as long as the container sets these environment variables to match the GitLab predefined CI/CD variables.

The primary scripts to destroy, deploy, and validate metadata are:
- `scripts/bash/deploy_metadata_sf.sh` - To validate and deploy metadata to Salesforce orgs. Tests are set by `scripts/bash/package_check.sh`.
    - `$CI_PIPELINE_SOURCE` must be "push" to be deploy and some other value to validate (like `merge_request_event`) from a merge request/pull request. Only the value "push" is hard-coded into the bash script.
    - `$DEPLOY_PACKAGE` should be the path to the package.xml to be deployed
    - `$DEPLOY_TIMEOUT` should be the wait period for the CLI. Set to 240 in the `.gitlab-ci.yml`.
- `scripts/bash/package_check.sh` - To check the package before validating and deploying metadata to Salesforce orgs.
    - `$DEPLOY_PACKAGE` should be the path to the package.xml to be deployed
- `scripts/bash/destroy_metadata_sf.sh`
    - `$DESTRUCTIVE_CHANGES_PACKAGE` should be the path to the `destructive/destructiveChanges.xml` created by the sfdx-git-delta plugin. `$DESTRUCTIVE_PACKAGE` should be the path to the `destructive/package.xml` created by the sfdx-git-delta plugin.
    - `$CI_ENVIRONMENT_NAME` must be "prd" for production orgs in order to run apex tests when destroying Apex in production, per Salesforce requirement. Sandbox org names do not matter.
    - `$DEPLOY_TIMEOUT` should be the wait period for the CLI. Set to 240 in the `.gitlab-ci.yml`.   
- `scripts/bash/deploy_slack_status.sh`
    - `$CI_ENVIRONMENT_NAME` must be set with the org name. Optionally, validation environments can start with "validate-", which will be removed in the slack status. This is useful to create separate CI/CD environments for validations and deployments to limit those who can deploy over those who can validate.
    - `$CI_JOB_STAGE` must be "validate", "destroy", or "deploy" to have slack post the right message.
    - `$CI_JOB_STATUS` must be "success" for successful pipelines and some other value for failed pipelines.
    - `GITLAB_USER_NAME`, `CI_JOB_URL`, `CI_PROJECT_URL`, `CI_COMMIT_SHA` should be adjusted for the platform to have the correct details.
- `scripts/bash/create_package.sh`
    - `$COMMIT_MSG` should be the commit message containing the backup package.xml contents in list format
    - `$DEPLOY_PACKAGE` should be the path to the package.xml to be deployed

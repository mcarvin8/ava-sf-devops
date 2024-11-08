# Salesforce Org Model for GitLab CI/CD using the Salesforce CLI (`sf`)
This repository demonstrates how to use GitLab actions, the Salesforce CLI, and custom scripts to validate, deploy, or destroy metadata in a Salesforce org following the org development model, without using packages/scratch orgs.

Two models are provided
- The default model = Org Branching Model (aka each org has its own long-running branch)
- Alternative model = 1 long running branch similar to Git Flow model

Both models use these 2 Salesforce CLI plugins:
1. [SFDX Git Delta](https://github.com/scolladon/sfdx-git-delta)
2. [Apex Tests List](https://github.com/renatoliveira/apex-test-list)

## Default CI/CD Model - Org Branches

The default model in `.gitlab-ci.yml` is the org branching model, where each Salesforce org has its own long-running Git branch.

- The `validate` stage contains jobs for each org. When a merge request is opened against one of the org branches, it will validate the changes in the org.
- The `destroy` stage contains jobs for each org that will delete the metadata from the org if the files were deleted from the org branch. This job is allowed to fail and will fail if there are no metadata types detected in the destructive package.
    - This will be a standalone destructive deployment that will run before the deployment by default. If you need to deploy the destructive changes after the deployment, cancel the `destroy` stage when the pipeline is created, allow the `deploy` stage to complete, then re-run the `destroy` stage.
    - To destroy Apex in production, you must run tests per Salesforce requirement. Set the `DESTRUCTIVE_TESTS` variable in `.gitlab-ci.yml` with the pre-defined tests to run when destroying Apex in production.
- The `deploy` stage contains jobs for each org that will deploy the metadata to the assigned org after a merge into the org branch.


## Alternative CI/CD Model - 1 Long Running Branch

The other model in `one-branch.gitlab-ci.yml` is for 1 long running branch that is default such as `main`. 

When a merge request is open against the default branch, a merge request pipeline will be created to:
1. Validate changes in each sandbox org ("dev" and "fqa" in the example) and production. The validation is allowed to fail in order to not block sandbox deployments.
2. If destructive changes are made, destroy metadata in each sandbox org. The destruction is allowed to fail in order to not block sandbox deployments.
3. Deploy changes to each sandbox org.

Each job in the merge request pipeline is manually triggered and can be protected by creating protected CI/CD environments to limit those who can trigger the jobs.

This is where I suggest using CI/CD environment protection rules.

When the merge is accepted into the default branch, the push pipeline will run automatiicaly to destroy any destructive metadata in production and then deploy constructive changes to production.

The destructive deployment job is allowed to fail in order to not block the constructive deployment or to allow the destruction to run after the constructive.

## Slack Posts

The deployment, validation, and destruction statuses can be posted to a Slack channel. Update the webhook variable in the `.gitlab-ci.yml` you use:

``` yaml
  # Update webhook URL here for your slack channel
  SLACK_WEBHOOK_URL: https://hooks.slack.com/services/
```

Delete this variable and the step in each `after_script` section that runs `scripts/bash/deploy_slack_status.sh` if you are not using slack.

## Declare Metadata to Deploy

This org model uses a manifest file (package.xml) to run delta deployments. The SFDX git delta plugin will create a package.xml by comparing the changes between the current commit and previous commit.

This package is then checked to search for Apex Classes, Apex Triggers, and Connected Apps. See below:

### Declare Apex Tests

If Apex classes/trigger are found in the package for validations or deployments, it will run the apex tests list plugin to determine the specified tests to run, instead of running all local tests in the org.

You must add the `@tests:` or `@testsuites:` annotations to each Apex class/trigger per the [Apex Test List plugin documentation](https://github.com/renatoliveira/apex-test-list?tab=readme-ov-file#apex-test-list).

This plugin is not used in destructive deployments.

### Connected Apps

If connected apps are found in the package for validations or deployments, the `<consumerKey>` line in each connected app meta file will be automatically removed before deployment. Deployments with connected apps will fail if you leave the consumer key in the file.

## Branch Protection

### Validation Merge Request Pipelines

In the "Merge requests" settings, you can enable "Pipelines must succeed" to ensure the merge request validation passes before the request can be accepted. I also recommend enabling "Enable merged results pipelines" under "Merge options".

### Protected CI/CD Environments

You can protect each CI/CD environment to limit those who can deploy to the orgs.

In both models, the validation environments start with "validate-", which you can allow anyone to validate.

But for destructions and deployments, I would recommend protecting these environments to limit those who can permanently change the target org.

## Bot Deployments

To deploy Einstein Bots, you should update the `.forceignore` file with bot versions to not deploy/retrieve (such as the active bot version) and you should also update the `scripts/replacementFiles` with the Bot User for each org, if you are configuring the bot user. The metadata string replacements are done automatically by the Salesforce CLI before deployment and they are dependent on the `AUTH_ALIAS` variables configure in the `.gitlab-ci.yml`.

If you do not want to use this feature, remove the `replacements` key in the `sfdx-project.json`.

## Other CI/CD Platforms

The bash scripts in `scripts/bash` could work on other CI/CD platforms as long as the container sets these environment variables to match the GitLab predefined CI/CD variables.

The primary scripts to destroy, deploy, and validate metadata are:
- `scripts/bash/deploy_metadata_sf.sh` - To validate and deploy metadata to Salesforce orgs. Tests are set by `scripts/bash/package_check.sh`.
    - `$CI_PIPELINE_SOURCE` must be "push" to be deploy and some other value to validate (like `merge_request_event`) from a merge request/pull request. Only the value "push" is hard-coded into the bash script.
    - `$DEPLOY_PACKAGE` should be the path to the package.xml created by the sfdx-git-delta plugin.
    - `$DEPLOY_TIMEOUT` should be the wait period for the CLI. Set to 240 in the `.gitlab-ci.yml`.
- `scripts/bash/package_check.sh` - To check the package before validating and deploying metadata to Salesforce orgs.
    - `$DEPLOY_PACKAGE` should be the path to the package.xml created by the sfdx-git-delta plugin.
- `scripts/bash/destroy_metadata_sf.sh`
    - `$DESTRUCTIVE_CHANGES_PACKAGE` should be the path to the `destructive/destructiveChanges.xml` created by the sfdx-git-delta plugin. `$DESTRUCTIVE_PACKAGE` should be the path to the `destructive/package.xml` created by the sfdx-git-delta plugin.
    - `$CI_ENVIRONMENT_NAME` must be "prd" for production orgs in order to run apex tests when destroying Apex in production, per Salesforce requirement. Sandbox org names do not matter.
    - `$DEPLOY_TIMEOUT` should be the wait period for the CLI. Set to 240 in the `.gitlab-ci.yml`.   
- `scripts/bash/deploy_slack_status.sh`
    - `$CI_ENVIRONMENT_NAME` must be set with the org name. Optionally, validation environments can start with "validate-", which will be removed in the slack status. This is useful to create separate CI/CD environments for validations and deployments to limit those who can deploy over those who can validate.
    - `$CI_JOB_STAGE` must be "validate", "destroy", or "deploy" to have slack post the right message.
    - `$CI_JOB_STATUS` must be "success" for successful pipelines and some other value for failed pipelines.
    - `GITLAB_USER_NAME`, `CI_JOB_URL`, `CI_PROJECT_URL`, `CI_COMMIT_SHA` should be adjusted for the platform to have the correct details.

# Salesforce Org Model for GitLab CI/CD using the SF Executable
This repository demonstrates how to use GitLab actions, the Salesforce CLI, the SFDX git delta plugin, and custom Python scripts to validate, deploy, or destroy metadata in a Salesforce org following the org development model, without using packages/scratch orgs. 

Each Salesforce org has its own long-running Git branch.

## CI/CD Jobs

The pipeline is divided into the following stages:

- The `build` stage builds a Docker image for the org if the `Dockerfile` has been modified. This Docker image is pushed to the GitLab repository's Container Registry.
- The `validate` stage contains jobs for each org. When a merge request is opened against one of the org branches, it will validate the changes in the org.
    - This has been confirmed on GitLab Merge Request Pipelines (standard pipeline - defaults to this when there are merge conflicts) and Merged Results Pipelines (when there are no conflicts and this setting is enabled in the repo)
    - If you are working on GitLab v16.6, adjust the variable $COMMIT_MSG to use $CI_MERGE_REQUEST_DESCRIPTION to ensure MR pipelines with merge conflicts parse the tests and package in the MR description.
- The `destroy` stage contains jobs for each org that will delete the metadata from the org if the files were deleted from the org branch. This job is allowed to fail and will fail if there are no metadata types detected in the destructive package.
    - This will be a standalone destructive deployment that will run before the deployment by default. If you need to deploy the destructive changes after the deployment, cancel the `destroy` stage when the pipeline is created, allow the `deploy` stage to complete, then re-run the `destroy` stage.
- The `deploy` stage contains jobs for each org that will deploy the metadata to the assigned org after a merge into the org branch.

## Declare Metadata to Deploy

This org model uses a manifest file (package.xml) to run delta deployments. By default, the SFDX git delta plugin will create a package.xml by comparing the changes between the current commit and previous commit.

As a backup, the GitLab Merge Request description will be parsed via the merge commit message to look for package.xml contents.

The package.xml contents in the Merge Request should be used to declare any metadata that would not be covered by the diff between the current commit and the previous commit.

The following updates must be made to your GitLab repository:
- The default merge commit message should be updated to include the description of the MR for UI merges.
![Merge Request Commit Message Template](mr-commit-message-template.JPG)
- The default merge request description template should be updated to include the required Apex string template.
- The default merge request description template should be updated to include the package.xml header and footer.
![Default Merge Request Description](default-mr-description.JPG)
- Enable Merged Results Pipelines 
![Merged Results Setting](merged-results.png)

The plugin manifest file and the manual manifest file will be merged to create the final deployment package.

The final deployment package cannot contain wildcard characters for delta deployments. If a metadata type contains a wildcard, it will not be added to the final deployment package.

## Declare Apex Tests
Apex tests will be declared in the commit message with the following expression:
`Apex::Class1,Class2,Class3::Apex`

The entire "Apex" string is case insensitive. Test classes can be separated by commas or spaces. If your Apex Test Class naming convention allows spaces, adjust the regex in the `apex_tests.py` script.

## Branch Protection

### Validation Merge Request Pipelines

In the "Merge requests" settings, enable "Pipelines must succeed" to ensure the merge request validation passes before the request can be accepted.

### Code Owners

Update the `CODEOWNERS` file in this repo to define the owners of your code base. Enforce `CODEOWNERS` approval in merge requests to prevent a merge request from being accepted wtihout code owner approval.

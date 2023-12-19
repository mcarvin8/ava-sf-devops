# Salesforce Org Model for GitLab CI/CD using the SF Executable
This repository contains Python scripts that demonstrate how to use GitLab actions to validate and deploy metadata in a Salesforce org following the org development model, without using packages/scratch orgs. 

Each Salesforce org has its own long-running Git branch.

## CI/CD Jobs

The pipeline is divided into several stages:

- The `build` stage builds a Docker image for the org if the Dockerfile has been modified. This Docker image is pushed to the GitLab Container Registry for the repository.
- The `validate` stage consists of 3 jobs that represent 3 Salesforce orgs which have their own long-running branch. When a merge request is opened against one of these branches, it will validate the changes in the org.
    - This has been confirmed on GitLab Merge Request Pipelines (standard pipeline - defaults to this when there are merge conflicts) and Merged Results Pipelines (when there are no conflicts and this setting is enabled in the repo)
- The `deploy` stage consists of 3 jobs that will deploy the metadata to the assigned org after a merge into the long-running branch.

## Declare Metadata

This org model uses a manifest file (package.xml) to run delta deployments. By default, the SFDX git delta plugin will create a package.xml by comparing the changes between the current commit and previous commit.

As a backup, the GitLab Merge Request description will be parsed via the merge commit message to look for package.xml contents.

The package.xml contents in the Merge Request should be used to declare any metadata that would not be covered by the diff between the current commit and the previous commit.

The following updates must be made to your GitLab repository:
- The default merge commit message should be updated to include the description of the MR for UI merges.
![Merge Request Commit Message Template](mr-commit-message-template.JPG)
- The default merge request description template should be updated to include the required Apex string template.
- The default merge request description template should be updated to include the package.xml header and footer.
![Default Merge Request Description](default-mr-description.JPG)

The scripts will merge metadata types from the plugin manifest file and the manual manifest file to create the final deployment package.

Note that the final deployment package cannot contain wildcard characters for delta deployments. 
If a metadata type contains a wildcard, the type will not be added to the final deployment package.

## Declare Apex Tests
Apex tests will be declared in the commit message with the following expression:
`Apex::Class1,Class2,Class3::Apex`

The entire "Apex" string is case insensitive.

The above string will be converted to the SF compatible string (multiple test classes separated by spaces).


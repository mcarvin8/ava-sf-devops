FROM ubuntu:latest

# Set Salesforce CLI Environment Variables
ENV SF_AUTOUPDATE_DISABLE=true \
    # ^-- By default, the CLI periodically checks for and installs updates.
    #     Disable (false) this auto-update check to improve performance of CLI commands.
    SF_USE_GENERIC_UNIX_KEYCHAIN=true \
    # ^-- Set to true if you want to use the generic UNIX keychain instead of the Linux libsecret library or macOS keychain.
    #     Specify this variable when using the CLI with ssh or "headless" in a CI environment.
    SF_DOMAIN_RETRY=300 \
    # ^-- Specifies the time, in seconds, that the CLI waits for the Lightning Experience custom domain to resolve and become available in a newly-created scratch org.
    #     If you get errors about My Domain not configured when you try to use a newly-created scratch org, increase this wait time.
    SF_PROJECT_AUTOUPDATE_DISABLE_FOR_PACKAGE_CREATE=true \
    # ^-- For force:package:create, disables automatic updates to the sfdx-project.json file.
    SF_PROJECT_AUTOUPDATE_DISABLE_FOR_PACKAGE_VERSION_CREATE=true \
    # ^-- For force:package:version:create, disables automatic updates to the sfdx-project.json file.
    SF_DISABLE_DNS_CHECK=true \
    # ^-- Disable the DNS check done when looking for the latest API version in the org.
    SF_DISABLE_SOURCE_MEMBER_POLLING=true \
    # ^-- Disable source member polling between local source and org.
    SF_SKIP_NEW_VERSION_CHECK=true
    # ^-- Disable the check for newer CLI versions.

# Install dependencies and output versions
RUN apt-get update && apt-get install -y curl git python3 ca-certificates curl gnupg && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y nodejs && \
    npm install --global @salesforce/cli@latest && \
    sf version --verbose --json

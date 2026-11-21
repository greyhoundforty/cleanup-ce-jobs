FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies: curl, jq, and ca-certificates
RUN apt-get update && apt-get install -y \
    curl \
    jq \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install IBM Cloud CLI
# The installer puts the binary in /usr/local/bin/ibmcloud by default
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | sh

# No need to install 'resource-controller' as 'ibmcloud resource' is native.
# We just ensure we have the 'cos' plugin for the upload.
RUN /usr/local/bin/ibmcloud plugin install cos

# Copy the cleanup script into the image
COPY weekly_cleanup_report.sh /usr/local/bin/weekly_cleanup_report.sh
RUN chmod +x /usr/local/bin/weekly_cleanup_report.sh

# Set the working directory
WORKDIR /home/app

# Wrapper entrypoint to handle non-interactive login and execute the script
# We add --non-interactive to the login to prevent hanging on prompts
RUN echo '#!/bin/bash\n/usr/local/bin/ibmcloud login --apikey "$IBMCLOUD_API_KEY" -q > /dev/null 2>&1\n/usr/local/bin/weekly_cleanup_report.sh' > /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

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

# Copy the cleanup script into the image
COPY weekly_cleanup_report.sh /usr/local/bin/weekly_cleanup_report.sh
RUN chmod +x /usr/local/bin/weekly_cleanup_report.sh

# Set the working directory
WORKDIR /home/app

# Entrypoint: non-interactive login (fails fast with a clear error), then the report
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

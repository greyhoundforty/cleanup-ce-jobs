FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies: curl, jq, ca-certificates, and python3 (deleteme cleanup job)
RUN apt-get update && apt-get install -y \
    curl \
    jq \
    ca-certificates \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Install IBM Cloud CLI
# The installer puts the binary in /usr/local/bin/ibmcloud by default
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | sh

# VPC commands (`ibmcloud is ...`) for the deleteme cleanup job; the installer
# does not include this plugin.
RUN ibmcloud plugin install vpc-infrastructure -f -q \
    && ibmcloud plugin show vpc-infrastructure >/dev/null

# Copy the cleanup script into the image
COPY weekly_cleanup_report.sh /usr/local/bin/weekly_cleanup_report.sh
RUN chmod +x /usr/local/bin/weekly_cleanup_report.sh

# deleteme cleanup job (issue #2); runs with CLEANUP_SCRIPT=/opt/cleanup/deleteme_cleanup.py
COPY deleteme /opt/cleanup/deleteme
COPY deleteme_cleanup.py /opt/cleanup/deleteme_cleanup.py
RUN chmod +x /opt/cleanup/deleteme_cleanup.py

# Set the working directory
WORKDIR /home/app

# Entrypoint: non-interactive login (fails fast with a clear error), then the report
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

#!/bin/bash
# weekly_cleanup_report.sh
# Lists all resources tagged with owner:ryantiffany for weekly cleanup.
# Modified for Code Engine execution with COS upload.

TAG="owner:ryantiffany"
TIMESTAMP=$(date +"%Y-%m-%d")
OUTPUT_FILE="cleanup_report_${TIMESTAMP}.txt"

echo "Searching for resources with tag: ${TAG}..."

# Execute search and format output using jq
ibmcloud resource search "tags:\"${TAG}\"" --output json | jq -r '.items[] | "\(.name) | \(.region) | \(.service_name) | \(.crn)"' > "$OUTPUT_FILE"

if [ -s "$OUTPUT_FILE" ]; then
    echo "Report generated successfully: $OUTPUT_FILE"
    
    # COS Upload Logic
    # Assumes COS_BUCKET_NAME is provided as an environment variable
    if [ -n "$COS_BUCKET_NAME" ]; then
        echo "Uploading report to bucket: $COS_BUCKET_NAME..."
        # Use ibmcloud cos to upload the file
        # This requires the 'cos' plugin to be installed and authenticated
        ibmcloud plugin install cos
        ibmcloud cos bucket-upload "$COS_BUCKET_NAME" "$OUTPUT_FILE"
        
        if [ $? -eq 0 ]; then
            echo "Upload successful."
        else
            echo "Upload failed."
            exit 1
        fi
    else
        echo "COS_BUCKET_NAME not set. Skipping upload."
    fi
else
    echo "No resources found with tag ${TAG}."
    rm -f "$OUTPUT_FILE"
fi

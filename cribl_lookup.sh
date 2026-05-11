#!/bin/bash

# ============================================================
# Cribl Lookup Table Sync Script
# ============================================================
# Workflow:
# 1. Prompt user for Cribl credentials securely at runtime
# 2. Authenticate to Cribl
# 3. Download current lookup CSV
# 4. Parse source CSV
# 5. Compare source vs destination
# 6. Append only missing records
# 7. Upload updated CSV
#
# Destination CSV format:
# csi_id,environment,gcp_project_id,criticality,project_name,extra_key
#
# Current source sample column mapping:
# A = CSI_ID
# C = ENVIRONMENT
# J = GCP_PROJECT_ID
# R = CRITICALITY
# S = EXTRA_KEY (temporary placeholder until finalized)
#
# Unique key:
# CSI_ID + ENVIRONMENT + CRITICALITY + GCP_PROJECT_ID + EXTRA_KEY
# ============================================================

set -euo pipefail

# -------------------------
# Variables
# -------------------------
CRIBL_URL=""
SOURCE_CSV=""
LOOKUP_FILENAME=""
WORKING_DEST_CSV=""

# -------------------------
# Usage
# -------------------------
usage() {
    echo "Usage:"
    echo "$0 -source-csv <source.csv> -lookup-file <lookup.csv> -cribl-url <url>"
    exit 1
}

# -------------------------
# Parse Arguments
# -------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -source-csv)
            SOURCE_CSV="$2"
            shift 2
            ;;
        -lookup-file)
            LOOKUP_FILENAME="$2"
            shift 2
            ;;
        -cribl-url)
            CRIBL_URL="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

# -------------------------
# Validate Inputs
# -------------------------
if [[ -z "$SOURCE_CSV" || -z "$LOOKUP_FILENAME" || -z "$CRIBL_URL" ]]; then
    usage
fi

if [[ ! -f "$SOURCE_CSV" ]]; then
    echo "Source CSV not found: $SOURCE_CSV"
    exit 1
fi

WORKING_DEST_CSV="./$LOOKUP_FILENAME"

# -------------------------
# Prompt for Credentials
# -------------------------
read -p "Enter Cribl Username: " CRIBL_USERNAME
read -s -p "Enter Cribl Password: " CRIBL_PASSWORD
echo ""

# -------------------------
# Authenticate
# -------------------------
echo "Authenticating to Cribl..."

TOKEN=$(curl -sk -X POST "$CRIBL_URL/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$CRIBL_USERNAME\",\"password\":\"$CRIBL_PASSWORD\"}" \
    | jq -r '.token')

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "Failed to retrieve Cribl auth token."
    exit 1
fi

echo "Authentication successful."

# -------------------------
# Download Current Lookup File
# -------------------------
echo "Downloading existing lookup file..."

curl -sk -X GET "$CRIBL_URL/api/v1/m/default/system/lookups/$LOOKUP_FILENAME" \
    -H "Authorization: Bearer $TOKEN" \
    -o "$WORKING_DEST_CSV"

if [[ ! -f "$WORKING_DEST_CSV" ]]; then
    echo "Failed to download lookup file."
    exit 1
fi

echo "Lookup file downloaded successfully."

# -------------------------
# Backup Existing File
# -------------------------
cp "$WORKING_DEST_CSV" "${WORKING_DEST_CSV}.bak"

# -------------------------
# Counters
# -------------------------
ADDED_COUNT=0
SKIPPED_COUNT=0
INVALID_COUNT=0

TEMP_APPEND=$(mktemp)

# -------------------------
# Process Source CSV
# -------------------------
echo "Processing source CSV..."

# Skip header and parse based on known sample column positions:
# A,C,J,R,S
tail -n +2 "$SOURCE_CSV" | while IFS=',' read -r \
    COL_A COL_B COL_C COL_D COL_E COL_F COL_G COL_H COL_I COL_J \
    COL_K COL_L COL_M COL_N COL_O COL_P COL_Q COL_R COL_S REMAINDER; do

    CSI_ID="$COL_A"
    ENVIRONMENT=$(echo "$COL_C" | tr '[:upper:]' '[:lower:]')
    GCP_PROJECT_ID="$COL_J"
    CRITICALITY="$COL_R"
    EXTRA_KEY="$COL_S"

    # Placeholder until confirmed:
    PROJECT_NAME="$GCP_PROJECT_ID"

    # Validate required fields
    if [[ -z "$CSI_ID" || -z "$ENVIRONMENT" || -z "$GCP_PROJECT_ID" || -z "$CRITICALITY" || -z "$EXTRA_KEY" ]]; then
        echo "Skipping incomplete row for CSI_ID=$CSI_ID"
        ((INVALID_COUNT++))
        continue
    fi

    # Validate environment
    if [[ ! "$ENVIRONMENT" =~ ^(dev|uat|prod)$ ]]; then
        echo "Skipping invalid environment for CSI_ID=$CSI_ID : $ENVIRONMENT"
        ((INVALID_COUNT++))
        continue
    fi

    # Build unique key
    KEY="${CSI_ID}|${ENVIRONMENT}|${CRITICALITY}|${GCP_PROJECT_ID}|${EXTRA_KEY}"

    # Check if exact record exists
    if grep -q "^${CSI_ID},${ENVIRONMENT},${GCP_PROJECT_ID},${CRITICALITY},${PROJECT_NAME},${EXTRA_KEY}$" "$WORKING_DEST_CSV"; then
        echo "Skipping existing record: $KEY"
        ((SKIPPED_COUNT++))
    else
        echo "$CSI_ID,$ENVIRONMENT,$GCP_PROJECT_ID,$CRITICALITY,$PROJECT_NAME,$EXTRA_KEY" >> "$TEMP_APPEND"
        echo "Added missing record: $KEY"
        ((ADDED_COUNT++))
    fi

done

# -------------------------
# Append Missing Records
# -------------------------
if [[ -s "$TEMP_APPEND" ]]; then
    cat "$TEMP_APPEND" >> "$WORKING_DEST_CSV"
fi

rm -f "$TEMP_APPEND"

# -------------------------
# Upload Updated Lookup File
# -------------------------
echo "Uploading updated lookup file..."

UPLOAD_RESPONSE=$(curl -sk -X PUT "$CRIBL_URL/api/v1/m/default/system/lookups/$LOOKUP_FILENAME" \
    -H "Authorization: Bearer $TOKEN" \
    -F "file=@$WORKING_DEST_CSV")

echo "Upload Response:"
echo "$UPLOAD_RESPONSE"

# -------------------------
# Summary
# -------------------------
echo "===================================="
echo "Cribl Lookup Sync Complete"
echo "Added Records   : $ADDED_COUNT"
echo "Skipped Existing: $SKIPPED_COUNT"
echo "Invalid Rows    : $INVALID_COUNT"
echo "Backup File     : ${WORKING_DEST_CSV}.bak"
echo "===================================="

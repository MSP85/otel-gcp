#!/bin/bash

# ============================================================
# Cribl Lookup Table Sync Script
# ============================================================
# Flow:
# 1. Parse source CSV
# 2. Extract required fields into temp CSV
# 3. Prompt for Cribl credentials
# 4. Download existing lookup
# 5. Append missing records
# 6. Upload updated lookup
# ============================================================

set -euo pipefail

# -------------------------
# Static Configuration
# -------------------------
SOURCE_CSV="/path/to/source.csv"
CRIBL_URL="https://your-cribl-instance"
LOOKUP_FILENAME="your_lookup_file.csv"

# -------------------------
# Helpers
# -------------------------
trim() {
    echo "$1" | sed 's/^ *//;s/ *$//' | tr -d '\r'
}

# -------------------------
# Validate Source File
# -------------------------
if [[ ! -f "$SOURCE_CSV" ]]; then
    echo "Source CSV not found: $SOURCE_CSV"
    exit 1
fi

# -------------------------
# Working Files
# -------------------------
CURRENT_DIR=$(pwd)
TEMP_SOURCE_OUTPUT="${CURRENT_DIR}/parsed_source_lookup.csv"
DEST_CSV="${CURRENT_DIR}/${LOOKUP_FILENAME}"

# -------------------------
# Initialize Parsed Output
# -------------------------
echo "application_id,environment,vended_project_name,critical,extra_key" > "$TEMP_SOURCE_OUTPUT"

# -------------------------
# Read Header Row
# -------------------------
HEADER=$(head -n 1 "$SOURCE_CSV")
IFS=',' read -ra HEADER_COLUMNS <<< "$HEADER"

APP_ID_INDEX=-1
ENV_INDEX=-1
CRITICAL_INDEX=-1
PROJECT_INDEX=-1

for i in "${!HEADER_COLUMNS[@]}"; do
    COLUMN_NAME=$(trim "${HEADER_COLUMNS[$i]}" | tr -d '"')

    case "$COLUMN_NAME" in
        "Application Id") APP_ID_INDEX=$i ;;
        "Environments") ENV_INDEX=$i ;;
        "Critical") CRITICAL_INDEX=$i ;;
        "Vended Project Name") PROJECT_INDEX=$i ;;
    esac
done

# -------------------------
# Validate Headers
# -------------------------
if [[ $APP_ID_INDEX -lt 0 || $ENV_INDEX -lt 0 || $CRITICAL_INDEX -lt 0 || $PROJECT_INDEX -lt 0 ]]; then
    echo "Required source headers not found."
    echo "Headers required:"
    echo "- Application Id"
    echo "- Environments"
    echo "- Critical"
    echo "- Vended Project Name"
    exit 1
fi

echo "Source headers mapped successfully."

# -------------------------
# Counters
# -------------------------
PROCESSED_COUNT=0
INVALID_COUNT=0

# -------------------------
# Parse Source CSV
# -------------------------
echo "Parsing source CSV..."

tail -n +2 "$SOURCE_CSV" | while IFS=',' read -ra ROW; do

    APPLICATION_ID=$(trim "${ROW[$APP_ID_INDEX]}" | tr -d '"')
    ENVIRONMENT=$(trim "${ROW[$ENV_INDEX]}" | tr '[:upper:]' '[:lower:]' | tr -d '"')
    CRITICALITY=$(trim "${ROW[$CRITICAL_INDEX]}" | tr -d '"')
    VENDED_PROJECT_NAME=$(trim "${ROW[$PROJECT_INDEX]}" | tr -d '"')

    EXTRA_KEY=""

    # Required fields
    if [[ -z "$APPLICATION_ID" || -z "$ENVIRONMENT" || -z "$VENDED_PROJECT_NAME" ]]; then
        echo "Skipping incomplete row."
        ((INVALID_COUNT++))
        continue
    fi

    # Valid environments
    if [[ ! "$ENVIRONMENT" =~ ^(dev|uat|prod)$ ]]; then
        echo "Skipping invalid environment for Application ID=$APPLICATION_ID : $ENVIRONMENT"
        ((INVALID_COUNT++))
        continue
    fi

    # Write clean record
    echo "$APPLICATION_ID,$ENVIRONMENT,$VENDED_PROJECT_NAME,$CRITICALITY,$EXTRA_KEY" >> "$TEMP_SOURCE_OUTPUT"

    echo "Processed: $APPLICATION_ID | $ENVIRONMENT | $VENDED_PROJECT_NAME | $CRITICALITY"

    ((PROCESSED_COUNT++))

done

echo "===================================="
echo "Initial Source Parsing Complete"
echo "Parsed Output File : $TEMP_SOURCE_OUTPUT"
echo "Processed Rows     : $PROCESSED_COUNT"
echo "Invalid Rows       : $INVALID_COUNT"
echo "===================================="

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
# Download Existing Lookup
# -------------------------
echo "Downloading existing lookup file..."

curl -sk -X GET "$CRIBL_URL/api/v1/m/default/system/lookups/$LOOKUP_FILENAME" \
    -H "Authorization: Bearer $TOKEN" \
    -o "$DEST_CSV"

cp "$DEST_CSV" "${DEST_CSV}.bak"

echo "Lookup file downloaded and backed up."

# -------------------------
# Compare + Append Missing
# -------------------------
ADDED_COUNT=0
SKIPPED_COUNT=0

tail -n +2 "$TEMP_SOURCE_OUTPUT" | while IFS=',' read -r APPLICATION_ID ENVIRONMENT VENDED_PROJECT_NAME CRITICALITY EXTRA_KEY; do

    if grep -q "^${APPLICATION_ID},${ENVIRONMENT},${VENDED_PROJECT_NAME},${CRITICALITY},${EXTRA_KEY}$" "$DEST_CSV"; then
        echo "Skipping existing record: $APPLICATION_ID | $ENVIRONMENT"
        ((SKIPPED_COUNT++))
    else
        echo "$APPLICATION_ID,$ENVIRONMENT,$VENDED_PROJECT_NAME,$CRITICALITY,$EXTRA_KEY" >> "$DEST_CSV"
        echo "Added missing record: $APPLICATION_ID | $ENVIRONMENT"
        ((ADDED_COUNT++))
    fi

done

# -------------------------
# Upload Updated Lookup
# -------------------------
echo "Uploading updated lookup file..."

UPLOAD_RESPONSE=$(curl -sk -X PUT "$CRIBL_URL/api/v1/m/default/system/lookups/$LOOKUP_FILENAME" \
    -H "Authorization: Bearer $TOKEN" \
    -F "file=@$DEST_CSV")

echo "Upload Response:"
echo "$UPLOAD_RESPONSE"

# -------------------------
# Final Summary
# -------------------------
echo "===================================="
echo "Cribl Lookup Sync Complete"
echo "Working Directory : $CURRENT_DIR"
echo "Parsed Temp File  : $TEMP_SOURCE_OUTPUT"
echo "Lookup File       : $DEST_CSV"
echo "Backup File       : ${DEST_CSV}.bak"
echo "Added Records     : $ADDED_COUNT"
echo "Skipped Existing  : $SKIPPED_COUNT"
echo "===================================="

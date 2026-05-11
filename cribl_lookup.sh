#!/bin/bash

# ============================================================
# Cribl Lookup Table Sync Script
# ============================================================
# Current Phase:
# 1. Parse source CSV first
# 2. Extract required fields into temp CSV
# 3. Validate extraction
# 4. Optional Cribl sync once server is available
#
# Required Source Headers:
# - Application Id
# - Environments
# - Critical
# - Vended Project Name
#
# Destination Format:
# application_id,environment,vended_project_name,critical,extra_key
#
# Unique Key (current):
# application_id + environment + critical + vended_project_name
#
# Future:
# - extra_key can be added later
# ============================================================

set -euo pipefail

# -------------------------
# Variables
# -------------------------
SOURCE_CSV=""
CRIBL_URL=""
LOOKUP_FILENAME=""
TEST_ONLY=false

# -------------------------
# Usage
# -------------------------
usage() {
    echo "Usage:"
    echo "$0 -source-csv <source.csv> [-cribl-url <url> -lookup-file <lookup.csv>] [-test-only]"
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
        -cribl-url)
            CRIBL_URL="$2"
            shift 2
            ;;
        -lookup-file)
            LOOKUP_FILENAME="$2"
            shift 2
            ;;
        -test-only)
            TEST_ONLY=true
            shift
            ;;
        *)
            usage
            ;;
    esac
done

# -------------------------
# Validate Inputs
# -------------------------
if [[ -z "$SOURCE_CSV" ]]; then
    usage
fi

if [[ ! -f "$SOURCE_CSV" ]]; then
    echo "Source CSV not found: $SOURCE_CSV"
    exit 1
fi

# -------------------------
# Working Files
# -------------------------
CURRENT_DIR=$(pwd)
TEMP_SOURCE_OUTPUT="${CURRENT_DIR}/parsed_source_lookup.csv"

# -------------------------
# Initialize Temp Output
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
    COLUMN_NAME=$(echo "${HEADER_COLUMNS[$i]}" | tr -d '"' | xargs)

    case "$COLUMN_NAME" in
        "Application Id")
            APP_ID_INDEX=$i
            ;;
        "Environments")
            ENV_INDEX=$i
            ;;
        "Critical")
            CRITICAL_INDEX=$i
            ;;
        "Vended Project Name")
            PROJECT_INDEX=$i
            ;;
    esac
done

# -------------------------
# Validate Required Headers
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

echo "Source headers mapped successfully:"
echo "Application Id index      : $APP_ID_INDEX"
echo "Environments index        : $ENV_INDEX"
echo "Critical index            : $CRITICAL_INDEX"
echo "Vended Project Name index : $PROJECT_INDEX"

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

    APPLICATION_ID=$(echo "${ROW[$APP_ID_INDEX]}" | tr -d '"' | xargs)
    ENVIRONMENT=$(echo "${ROW[$ENV_INDEX]}" | tr '[:upper:]' '[:lower:]' | tr -d '"' | xargs)
    CRITICALITY=$(echo "${ROW[$CRITICAL_INDEX]}" | tr -d '"' | xargs)
    VENDED_PROJECT_NAME=$(echo "${ROW[$PROJECT_INDEX]}" | tr -d '"' | xargs)

    EXTRA_KEY=""

    # Validate fields
    if [[ -z "$APPLICATION_ID" || -z "$ENVIRONMENT" || -z "$CRITICALITY" || -z "$VENDED_PROJECT_NAME" ]]; then
        echo "Skipping incomplete row."
        ((INVALID_COUNT++))
        continue
    fi

    # Validate environment
    if [[ ! "$ENVIRONMENT" =~ ^(dev|uat|prod)$ ]]; then
        echo "Skipping invalid environment for Application ID=$APPLICATION_ID : $ENVIRONMENT"
        ((INVALID_COUNT++))
        continue
    fi

    # Write to temp output
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
# Stop if test-only mode
# -------------------------
if [[ "$TEST_ONLY" == true ]]; then
    echo "Test-only mode enabled. Skipping Cribl sync."
    exit 0
fi

# -------------------------
# Validate Cribl Params
# -------------------------
if [[ -z "$CRIBL_URL" || -z "$LOOKUP_FILENAME" ]]; then
    echo "Cribl URL and lookup filename required for full sync."
    exit 1
fi

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
DEST_CSV="${CURRENT_DIR}/${LOOKUP_FILENAME}"

echo "Downloading existing lookup file..."

curl -sk -X GET "$CRIBL_URL/api/v1/m/default/system/lookups/$LOOKUP_FILENAME" \
    -H "Authorization: Bearer $TOKEN" \
    -o "$DEST_CSV"

cp "$DEST_CSV" "${DEST_CSV}.bak"

echo "Lookup file downloaded and backed up."

# -------------------------
# Sync Missing Records
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

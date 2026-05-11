#!/bin/bash

# ============================================================
# Cribl Lookup Sync Script
# ============================================================
# Steps:
# 1. Parse source CSV
# 2. Extract required fields into temp CSV
# 3. Prompt for Cribl credentials
# 4. Download current lookup file
# 5. Append missing records
# 6. Upload updated lookup
#
# Required Source Headers:
# - Application Id
# - Environments
# - Critical
# - Vended Project Name
# ============================================================

set -e

SOURCE_CSV=""
CRIBL_URL=""
LOOKUP_FILENAME=""

usage() {
    echo "Usage:"
    echo "$0 -source-csv <source.csv> -cribl-url <url> -lookup-file <lookup.csv>"
    exit 1
}

# -------------------------
# Parse arguments
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
        *)
            usage
            ;;
    esac
done

if [[ -z "$SOURCE_CSV" || -z "$CRIBL_URL" || -z "$LOOKUP_FILENAME" ]]; then
    usage
fi

CURRENT_DIR=$(pwd)
TEMP_SOURCE_OUTPUT="${CURRENT_DIR}/parsed_source_lookup.csv"
DEST_CSV="${CURRENT_DIR}/${LOOKUP_FILENAME}"

# -------------------------
# Create temp parsed file
# -------------------------
echo "application_id,environment,vended_project_name,critical,extra_key" > "$TEMP_SOURCE_OUTPUT"

HEADER=$(head -n 1 "$SOURCE_CSV")
IFS=',' read -ra HEADER_COLUMNS <<< "$HEADER"

for i in "${!HEADER_COLUMNS[@]}"; do
    COLUMN_NAME=$(echo "${HEADER_COLUMNS[$i]}" | tr -d '"' | xargs)

    [[ "$COLUMN_NAME" == "Application Id" ]] && APP_ID_INDEX=$i
    [[ "$COLUMN_NAME" == "Environments" ]] && ENV_INDEX=$i
    [[ "$COLUMN_NAME" == "Critical" ]] && CRITICAL_INDEX=$i
    [[ "$COLUMN_NAME" == "Vended Project Name" ]] && PROJECT_INDEX=$i
done

echo "Parsing source CSV..."

tail -n +2 "$SOURCE_CSV" | while IFS=',' read -ra ROW; do

    APPLICATION_ID=$(echo "${ROW[$APP_ID_INDEX]}" | tr -d '"' | xargs)
    ENVIRONMENT=$(echo "${ROW[$ENV_INDEX]}" | tr '[:upper:]' '[:lower:]' | tr -d '"' | xargs)
    CRITICALITY=$(echo "${ROW[$CRITICAL_INDEX]}" | tr -d '"' | xargs)
    VENDED_PROJECT_NAME=$(echo "${ROW[$PROJECT_INDEX]}" | tr -d '"' | xargs)

    EXTRA_KEY=""

    echo "$APPLICATION_ID,$ENVIRONMENT,$VENDED_PROJECT_NAME,$CRITICALITY,$EXTRA_KEY" >> "$TEMP_SOURCE_OUTPUT"

    echo "Processed: $APPLICATION_ID | $ENVIRONMENT | $VENDED_PROJECT_NAME | $CRITICALITY"

done

echo "Source parsing complete: $TEMP_SOURCE_OUTPUT"

# -------------------------
# Prompt for credentials
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

# -------------------------
# Download current lookup
# -------------------------
echo "Downloading existing lookup file..."

curl -sk -X GET "$CRIBL_URL/api/v1/m/default/system/lookups/$LOOKUP_FILENAME" \
    -H "Authorization: Bearer $TOKEN" \
    -o "$DEST_CSV"

cp "$DEST_CSV" "${DEST_CSV}.bak"

# -------------------------
# Append missing records
# -------------------------
echo "Comparing and appending missing records..."

tail -n +2 "$TEMP_SOURCE_OUTPUT" | while IFS=',' read -r APPLICATION_ID ENVIRONMENT VENDED_PROJECT_NAME CRITICALITY EXTRA_KEY; do

    if grep -q "^${APPLICATION_ID},${ENVIRONMENT},${VENDED_PROJECT_NAME},${CRITICALITY},${EXTRA_KEY}$" "$DEST_CSV"; then
        echo "Skipping existing: $APPLICATION_ID | $ENVIRONMENT"
    else
        echo "$APPLICATION_ID,$ENVIRONMENT,$VENDED_PROJECT_NAME,$CRITICALITY,$EXTRA_KEY" >> "$DEST_CSV"
        echo "Added: $APPLICATION_ID | $ENVIRONMENT"
    fi

done

# -------------------------
# Upload updated lookup
# -------------------------
echo "Uploading updated lookup..."

curl -sk -X PUT "$CRIBL_URL/api/v1/m/default/system/lookups/$LOOKUP_FILENAME" \
    -H "Authorization: Bearer $TOKEN" \
    -F "file=@$DEST_CSV"

echo ""
echo "===================================="
echo "Cribl Lookup Sync Complete"
echo "Parsed Source File : $TEMP_SOURCE_OUTPUT"
echo "Lookup File        : $DEST_CSV"
echo "Backup File        : ${DEST_CSV}.bak"
echo "===================================="

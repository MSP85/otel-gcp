#!/bin/bash

# ============================================================
# Cribl Lookup Table Sync Script
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
# Helpers
# -------------------------
trim() {
    echo "$1" | sed 's/^ *//;s/ *$//' | tr -d '\r'
}

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
[[ -z "$SOURCE_CSV" ]] && usage
[[ ! -f "$SOURCE_CSV" ]] && { echo "Source CSV not found"; exit 1; }

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
    COLUMN_NAME=$(trim "${HEADER_COLUMNS[$i]}" | tr -d '"')

    case "$COLUMN_NAME" in
        "Application Id") APP_ID_INDEX=$i ;;
        "Environments") ENV_INDEX=$i ;;
        "Critical") CRITICAL_INDEX=$i ;;
        "Vended Project Name") PROJECT_INDEX=$i ;;
    esac
done

if [[ $APP_ID_INDEX -lt 0 || $ENV_INDEX -lt 0 || $CRITICAL_INDEX -lt 0 || $PROJECT_INDEX -lt 0 ]]; then
    echo "Required source headers not found."
    exit 1
fi

echo "Headers mapped successfully"

# -------------------------
# Parse Source CSV
# -------------------------
PROCESSED_COUNT=0
INVALID_COUNT=0

echo "Parsing source CSV..."

tail -n +2 "$SOURCE_CSV" | while IFS=',' read -ra ROW; do

    APPLICATION_ID=$(trim "${ROW[$APP_ID_INDEX]}" | tr -d '"')
    ENVIRONMENT=$(trim "${ROW[$ENV_INDEX]}" | tr '[:upper:]' '[:lower:]' | tr -d '"')
    CRITICALITY=$(trim "${ROW[$CRITICAL_INDEX]}" | tr -d '"')
    VENDED_PROJECT_NAME=$(trim "${ROW[$PROJECT_INDEX]}" | tr -d '"')

    EXTRA_KEY=""

    # Required field validation (keeps data clean)
    if [[ -z "$APPLICATION_ID" || -z "$ENVIRONMENT" || -z "$VENDED_PROJECT_NAME" ]]; then
        echo "Skipping incomplete row"
        ((INVALID_COUNT++))
        continue
    fi

    # Environment validation
    if [[ ! "$ENVIRONMENT" =~ ^(dev|uat|prod)$ ]]; then
        echo "Skipping invalid env: $ENVIRONMENT"
        ((INVALID_COUNT++))
        continue
    fi

    echo "$APPLICATION_ID,$ENVIRONMENT,$VENDED_PROJECT_NAME,$CRITICALITY,$EXTRA_KEY" >> "$TEMP_SOURCE_OUTPUT"
    echo "Processed: $APPLICATION_ID | $ENVIRONMENT | $VENDED_PROJECT_NAME | $CRITICALITY"

    ((PROCESSED_COUNT++))

done

echo "===================================="
echo "Parsing Complete"
echo "Output: $TEMP_SOURCE_OUTPUT"
echo "Processed: $PROCESSED_COUNT"
echo "Invalid: $INVALID_COUNT"
echo "===================================="

# -------------------------
# Stop if test mode
# -------------------------
if [[ "$TEST_ONLY" == true ]]; then
    exit 0
fi

# -------------------------
# Cribl sync section (unchanged logic)
# -------------------------
[[ -z "$CRIBL_URL" || -z "$LOOKUP_FILENAME" ]] && exit 0

read -p "Enter Cribl Username: " CRIBL_USERNAME
read -s -p "Enter Cribl Password: " CRIBL_PASSWORD
echo ""

TOKEN=$(curl -sk -X POST "$CRIBL_URL/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$CRIBL_USERNAME\",\"password\":\"$CRIBL_PASSWORD\"}" \
    | jq -r '.token')

DEST_CSV="${CURRENT_DIR}/${LOOKUP_FILENAME}"

curl -sk -X GET "$CRIBL_URL/api/v1/m/default/system/lookups/$LOOKUP_FILENAME" \
    -H "Authorization: Bearer $TOKEN" \
    -o "$DEST_CSV"

cp "$DEST_CSV" "${DEST_CSV}.bak"

ADDED_COUNT=0
SKIPPED_COUNT=0

tail -n +2 "$TEMP_SOURCE_OUTPUT" | while IFS=',' read -r APPLICATION_ID ENVIRONMENT VENDED_PROJECT_NAME CRITICALITY EXTRA_KEY; do

    if grep -q "^${APPLICATION_ID},${ENVIRONMENT},${VENDED_PROJECT_NAME},${CRITICALITY},${EXTRA_KEY}$" "$DEST_CSV"; then
        ((SKIPPED_COUNT++))
    else
        echo "$APPLICATION_ID,$ENVIRONMENT,$VENDED_PROJECT_NAME,$CRITICALITY,$EXTRA_KEY" >> "$DEST_CSV"
        ((ADDED_COUNT++))
    fi

done

curl -sk -X PUT "$CRIBL_URL/api/v1/m/default/system/lookups/$LOOKUP_FILENAME" \
    -H "Authorization: Bearer $TOKEN" \
    -F "file=@$DEST_CSV"

echo "Done"

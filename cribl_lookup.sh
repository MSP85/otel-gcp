#!/bin/bash

# ============================================================
# Cribl Lookup Table Upload Script
# ============================================================
# Usage: ./cribl_lookup.sh -e <dev|uat|nonprd|prod>
#
# Flow:
# 1. Parse environment flag
# 2. Prompt for Cribl credentials
# 3. Authenticate and retrieve token
# 4. Stage CSV file (PUT) - returns a temp filename
# 5. Commit lookup (POST) - registers the temp file as the lookup
# ============================================================

set -euo pipefail

# -------------------------
# Static Configuration
# -------------------------
CRIBL_URL="https://your-cribl-instance"
CRIBL_GROUP="default"
LOOKUP_FILENAME="your_lookup_file.csv"
LOOKUP_ID="your_lookup_id"

# -------------------------
# Parse Arguments
# -------------------------
usage() {
    echo "Usage: $0 -e <dev|uat|nonprd|prod>"
    exit 1
}

ENV=""
while getopts ":e:" opt; do
    case $opt in
        e) ENV="$OPTARG" ;;
        *) usage ;;
    esac
done

case "$ENV" in
    dev|uat|nonprd|prod) ;;
    *) echo "Invalid or missing environment. Must be one of: dev, uat, nonprd, prod"; usage ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CSV="${SCRIPT_DIR}/${ENV}/${LOOKUP_FILENAME}"

# -------------------------
# Validate Source File
# -------------------------
if [[ ! -f "$SOURCE_CSV" ]]; then
    echo "Source CSV not found: $SOURCE_CSV"
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
    | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "Failed to retrieve Cribl auth token."
    exit 1
fi

echo "Authentication successful."

# -------------------------
# Step 1: Stage the CSV file
# -------------------------
echo "Staging lookup file..."

STAGE_RESPONSE=$(curl -sk -X PUT "$CRIBL_URL/api/v1/m/$CRIBL_GROUP/system/lookups?filename=$LOOKUP_FILENAME" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: text/csv" \
    --data-binary "@$SOURCE_CSV")

echo "Stage Response: $STAGE_RESPONSE"

TEMP_FILENAME=$(echo "$STAGE_RESPONSE" | grep -o '"filename":"[^"]*"' | cut -d'"' -f4)

if [[ -z "$TEMP_FILENAME" ]]; then
    echo "Failed to get temp filename from staging response."
    exit 1
fi

echo "Staged as: $TEMP_FILENAME"

# -------------------------
# Step 2: Commit the lookup (PATCH to update, POST to create)
# -------------------------
echo "Committing lookup..."

PATCH_RESPONSE=$(curl -sk -o /dev/null -w "%{http_code}" -X PATCH "$CRIBL_URL/api/v1/m/$CRIBL_GROUP/system/lookups/$LOOKUP_ID" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"$LOOKUP_ID\",\"fileInfo\":{\"filename\":\"$TEMP_FILENAME\"}}")

if [[ "$PATCH_RESPONSE" == "200" ]]; then
    echo "Lookup updated successfully (PATCH $PATCH_RESPONSE)."
else
    echo "Lookup not found (PATCH $PATCH_RESPONSE), creating new lookup..."
    COMMIT_RESPONSE=$(curl -sk -X POST "$CRIBL_URL/api/v1/m/$CRIBL_GROUP/system/lookups" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"id\":\"$LOOKUP_ID\",\"fileInfo\":{\"filename\":\"$TEMP_FILENAME\"}}")
    echo "Commit Response: $COMMIT_RESPONSE"
fi

echo "===================================="
echo "Cribl Lookup Upload Complete"
echo "Environment : $ENV"
echo "Source File : $SOURCE_CSV"
echo "Lookup ID   : $LOOKUP_ID"
echo "Lookup File : $LOOKUP_FILENAME"
echo "===================================="

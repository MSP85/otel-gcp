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
# 4. Upload CSV to Cribl lookup
# ============================================================

set -euo pipefail

# -------------------------
# Static Configuration
# -------------------------
CRIBL_URL="https://your-cribl-instance"
LOOKUP_FILENAME="your_lookup_file.csv"

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
    | jq -r '.token')

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "Failed to retrieve Cribl auth token."
    exit 1
fi

echo "Authentication successful."

# -------------------------
# Upload Lookup File
# -------------------------
echo "Uploading lookup file to [$ENV]..."

UPLOAD_RESPONSE=$(curl -sk -X PUT "$CRIBL_URL/api/v1/m/default/system/lookups/$LOOKUP_FILENAME" \
    -H "Authorization: Bearer $TOKEN" \
    -F "file=@$SOURCE_CSV")

echo "Upload Response:"
echo "$UPLOAD_RESPONSE"

echo "===================================="
echo "Cribl Lookup Upload Complete"
echo "Environment : $ENV"
echo "Source File : $SOURCE_CSV"
echo "Lookup Name : $LOOKUP_FILENAME"
echo "===================================="

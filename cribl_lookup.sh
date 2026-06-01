#!/bin/bash

# ============================================================
# Cribl Lookup Table Sync Script
# ============================================================
# Flow:
# 1. Prompt for Cribl credentials
# 2. Download existing lookup
# 3. Append missing records from source CSV
# 4. Upload updated lookup
# ============================================================

set -euo pipefail

# -------------------------
# Static Configuration
# -------------------------
SOURCE_CSV="/path/to/source.csv"
CRIBL_URL="https://your-cribl-instance"
LOOKUP_FILENAME="your_lookup_file.csv"

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
DEST_CSV="${CURRENT_DIR}/${LOOKUP_FILENAME}"

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
# Append Missing Records
# -------------------------
ADDED_COUNT=0
SKIPPED_COUNT=0

tail -n +2 "$SOURCE_CSV" | while IFS= read -r LINE; do
    if grep -qF "$LINE" "$DEST_CSV"; then
        ((SKIPPED_COUNT++))
    else
        echo "$LINE" >> "$DEST_CSV"
        echo "Added: $LINE"
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
echo "Lookup File       : $DEST_CSV"
echo "Backup File       : ${DEST_CSV}.bak"
echo "Added Records     : $ADDED_COUNT"
echo "Skipped Existing  : $SKIPPED_COUNT"
echo "===================================="

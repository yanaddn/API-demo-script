#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

# -----------------------------------------------------------------------------
# Load .env file (if present)
# -----------------------------------------------------------------------------

if [[ -f ".env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source <(grep -v '^\s*#' .env | grep -v '^\s*$')
    set +a
fi

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

COMPANY_URL="${COMPANY_URL:-https://stage.company.com/api}"
TOKEN="${TOKEN:-}"
TYPE_ID="${TYPE_ID:-200}"
BATCH_SIZE="${BATCH_SIZE:-1000}"

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME --file <input.xls|input.xlsx|input.csv> --queue-id <queue_id> [options]

Options:
  --file        Input Excel/CSV file
  --queue-id    Company queue ID
  --output      Result log file path (optional)
  --dry-run     Generate and display payload chunks without sending
  --help        Show this help

Environment / .env:
  COMPANY_URL   Company API base URL (default: https://stage.Company.com/api)
  TOKEN         Company API access token
  TYPE_ID       Communication type ID (default: 200)
  BATCH_SIZE    Chunk size for batch processing (default: 1000)
EOF
}

# -----------------------------------------------------------------------------
# Arguments Parse
# -----------------------------------------------------------------------------

INPUT_FILE=""
QUEUE_ID=""
OUTPUT_FILE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)
            INPUT_FILE="${2:?Missing value for --file}"
            shift 2
            ;;
        --queue-id)
            QUEUE_ID="${2:?Missing value for --queue-id}"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="${2:?Missing value for --output}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

if [[ -z "$INPUT_FILE" ]]; then
    echo "ERROR: --file is required" >&2
    exit 1
fi

if [[ -z "$QUEUE_ID" ]]; then
    echo "ERROR: --queue-id is required" >&2
    exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "ERROR: Input file does not exist: $INPUT_FILE" >&2
    exit 1
fi

if [[ "$DRY_RUN" == false && -z "$TOKEN" ]]; then
    echo "ERROR: TOKEN is missing! Set it in environment or in .env file." >&2
    exit 1
fi

if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="${INPUT_FILE%.*}_result.txt"
fi

# -----------------------------------------------------------------------------
# Dependency Check
# -----------------------------------------------------------------------------

for command in mlr jq curl; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $command" >&2
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# Setup Temporary Directory
# -----------------------------------------------------------------------------

TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

CSV_FILE="$TMP_DIR/contacts.csv"
RECORDS_FILE="$TMP_DIR/records.json"
FILTERED_RECORDS="$TMP_DIR/filtered_records.json"

# -----------------------------------------------------------------------------
# Convert Input File to CSV
# -----------------------------------------------------------------------------

echo "Processing input file: $INPUT_FILE"

case "$INPUT_FILE" in
    *.xls|*.xlsx|*.XLS|*.XLSX)
        if ! command -v ssconvert >/dev/null 2>&1; then
            echo "ERROR: ssconvert (gnumeric) is required for Excel files." >&2
            exit 1
        fi
        ssconvert --export-type=Gnumeric_stf:stf_csv "$INPUT_FILE" "$CSV_FILE" >/dev/null 2>&1
        ;;
    *.csv|*.CSV)
        cp "$INPUT_FILE" "$CSV_FILE"
        ;;
    *)
        echo "ERROR: Unsupported file format. Use .xls, .xlsx, or .csv" >&2
        exit 1
        ;;
esac

if [[ ! -s "$CSV_FILE" ]]; then
    echo "ERROR: Converted/Input CSV file is empty" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Detect Columns
# -----------------------------------------------------------------------------

HEADER="$(head -n 1 "$CSV_FILE")"
RAW_NAME_COL=""
RAW_DEST_COL=""

IFS=',' read -ra COLUMNS <<< "$HEADER"
for column in "${COLUMNS[@]}"; do
    clean_col="$(echo "$column" | tr -d '"' | xargs)"
    case "$clean_col" in
        "Name"|"Name / ПІБ"|"Name/ПІБ"|"ПІБ")
            RAW_NAME_COL="$clean_col"
            ;;
        "Destination"|"Destination / Номер"|"Destination/Номер"|"Номер")
            RAW_DEST_COL="$clean_col"
            ;;
    esac
done

if [[ -z "$RAW_NAME_COL" || -z "$RAW_DEST_COL" ]]; then
    echo "ERROR: Required columns not found. Must contain Name/ПІБ and Destination/Номер." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Normalize Data & Sanitize Phone Numbers (залишаємо лише цифри)
# -----------------------------------------------------------------------------

mlr --icsv --ojson cat "$CSV_FILE" > "$RECORDS_FILE"

jq \
    --arg type_id "$TYPE_ID" \
    --arg name_col "$RAW_NAME_COL" \
    --arg dest_col "$RAW_DEST_COL" '
map({
    raw_name: (.[$name_col] // "" | tostring | gsub("^\\s+|\\s+$"; "")),
    raw_dest: (.[$dest_col] // "" | tostring | gsub("^\\s+|\\s+$"; "")),
    clean_dest: (.[$dest_col] // "" | tostring | gsub("[^0-9]"; ""))
})
| map(
    if .raw_name != "" and .clean_dest != "" then
        . + {
            valid: true,
            item: {
                name: .raw_name,
                communications: [{
                    destination: .clean_dest,
                    type: { id: ($type_id | tonumber) }
                }]
            }
        }
    else
        . + { valid: false, error: "Validation Error: Missing Name or Invalid Phone" }
    end
)
' "$RECORDS_FILE" > "$FILTERED_RECORDS"

TOTAL_COUNT="$(jq 'length' "$FILTERED_RECORDS")"
VALID_COUNT="$(jq '[.[] | select(.valid == true)] | length' "$FILTERED_RECORDS")"
INVALID_COUNT=$((TOTAL_COUNT - VALID_COUNT))

echo "Total records in file: $TOTAL_COUNT"
echo "Valid records ready for import: $VALID_COUNT"
echo "Invalid/Validation errors: $INVALID_COUNT"

if [[ "$VALID_COUNT" -eq 0 ]]; then
    echo "ERROR: No valid records to import." >&2
    exit 1
fi

# Ініціалізація лог-файлу результатів
echo "=== Import Log & Results: $(date) ===" > "$OUTPUT_FILE"
echo "Source File: $INPUT_FILE" >> "$OUTPUT_FILE"
echo "Queue ID: $QUEUE_ID" >> "$OUTPUT_FILE"
echo "--------------------------------------------------" >> "$OUTPUT_FILE"

# -----------------------------------------------------------------------------
# Batch Processing and API Dispatch
# -----------------------------------------------------------------------------

CLEAN_BASE_URL="${COMPANY_URL%/call_center/queues/*}"
CLEAN_BASE_URL="${CLEAN_BASE_URL%/}"
API_URL="${CLEAN_BASE_URL}/call_center/queues/${QUEUE_ID}/members/bulk"

FILE_NAME="$(basename "$INPUT_FILE")"
TOTAL_BATCHES=$(( (VALID_COUNT + BATCH_SIZE - 1) / BATCH_SIZE ))
SUCCESS_COUNT=0
FAILED_BATCH_COUNT=0
NETWORK_ERROR_COUNT=0
HTTP_ERROR_COUNT=0

VALID_ITEMS_FILE="$TMP_DIR/valid_items.json"
jq '[.[] | select(.valid == true)]' "$FILTERED_RECORDS" > "$VALID_ITEMS_FILE"

echo -e "\nStarting API Batch Processing (${TOTAL_BATCHES} batches)..."

for (( batch=0; batch<TOTAL_BATCHES; batch++ )); do
    OFFSET=$(( batch * BATCH_SIZE ))
    PAYLOAD_FILE="$TMP_DIR/payload_${batch}.json"
    RESPONSE_FILE="$TMP_DIR/response_${batch}.json"

    jq \
        --arg file_name "$FILE_NAME" \
        --argjson offset "$OFFSET" \
        --argjson limit "$BATCH_SIZE" '
    {
        file_name: $file_name,
        items: [.[$offset : $offset + $limit] | .[].item]
    }
    ' "$VALID_ITEMS_FILE" > "$PAYLOAD_FILE"

    BATCH_ITEMS_COUNT="$(jq '.items | length' "$PAYLOAD_FILE")"
    echo -n "Batch $((batch + 1))/$TOTAL_BATCHES ($BATCH_ITEMS_COUNT records) ... "

    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN - NOT SENT]"
        jq . "$PAYLOAD_FILE"
        continue
    fi

    # Виконання запиту з обробкою мережевих помилок
    HTTP_CODE=0
    if HTTP_CODE="$(
        curl \
            --silent \
            --show-error \
            --connect-timeout 10 \
            --max-time 120 \
            --output "$RESPONSE_FILE" \
            --write-out '%{http_code}' \
            --request POST \
            --header "X-Company-Access: ${TOKEN}" \
            --header "Content-Type: application/json" \
            --data-binary "@$PAYLOAD_FILE" \
            "$API_URL"
    )"; then
        :
    else
        CURL_EXIT_CODE=$?
        echo "NETWORK ERROR (curl exit code: $CURL_EXIT_CODE)" >&2
        echo "API BATCH ERROR | Batch $((batch + 1)) | Network Failure / Timeout (curl status: $CURL_EXIT_CODE)" >> "$OUTPUT_FILE"
        NETWORK_ERROR_COUNT=$((NETWORK_ERROR_COUNT + BATCH_ITEMS_COUNT))
        FAILED_BATCH_COUNT=$((FAILED_BATCH_COUNT + 1))
        continue
    fi

    # Перевірка HTTP статусів (2xx vs 4xx/5xx)
    if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + BATCH_ITEMS_COUNT))
        echo "SUCCESS (HTTP $HTTP_CODE)"
        echo "API BATCH SUCCESS | Batch $((batch + 1)) | HTTP $HTTP_CODE | Sent: $BATCH_ITEMS_COUNT" >> "$OUTPUT_FILE"
    else
        HTTP_ERROR_COUNT=$((HTTP_ERROR_COUNT + BATCH_ITEMS_COUNT))
        FAILED_BATCH_COUNT=$((FAILED_BATCH_COUNT + 1))
        
        # Витягуємо повідомлення про помилку з відповіді сервера
        SERVER_ERR_MSG="$(jq -r '.message // .detail // .detail_message // "Unknown Server Error"' "$RESPONSE_FILE" 2>/dev/null || cat "$RESPONSE_FILE")"
        
        echo "HTTP ERROR $HTTP_CODE: $SERVER_ERR_MSG" >&2
        echo "API BATCH ERROR | Batch $((batch + 1)) | HTTP $HTTP_CODE | Server Message: $SERVER_ERR_MSG" >> "$OUTPUT_FILE"
    fi
done

# -----------------------------------------------------------------------------
# Write Order-Preserved Output File
# -----------------------------------------------------------------------------

echo -e "\nWriting item-by-item status to $OUTPUT_FILE..."

echo -e "\n--- Detailed Item List ---" >> "$OUTPUT_FILE"
jq -r '
.[] | 
if .valid then
    "SUCCESS | Name: " + .raw_name + " | Phone: " + .clean_dest
else
    "FAILED  | Name: " + .raw_name + " | Phone: " + .raw_dest + " | Reason: " + .error
end
' "$FILTERED_RECORDS" >> "$OUTPUT_FILE"

TOTAL_FAILED_API=$((NETWORK_ERROR_COUNT + HTTP_ERROR_COUNT))
TOTAL_ERRORS=$((INVALID_COUNT + TOTAL_FAILED_API))

echo "--------------------------------------------------" >> "$OUTPUT_FILE"
echo "SUMMARY:" >> "$OUTPUT_FILE"
echo "  Total Records in File:   $TOTAL_COUNT" >> "$OUTPUT_FILE"
echo "  Successfully Processed:  $SUCCESS_COUNT" >> "$OUTPUT_FILE"
echo "  Total Errors:            $TOTAL_ERRORS" >> "$OUTPUT_FILE"
echo "    - Validation Errors:   $INVALID_COUNT" >> "$OUTPUT_FILE"
echo "    - HTTP 4xx/5xx Errors: $HTTP_ERROR_COUNT" >> "$OUTPUT_FILE"
echo "    - Network/Timeouts:    $NETWORK_ERROR_COUNT" >> "$OUTPUT_FILE"

# -----------------------------------------------------------------------------
# Final Console Output
# -----------------------------------------------------------------------------

echo "Import Finished!"
echo "Results Log: $OUTPUT_FILE"

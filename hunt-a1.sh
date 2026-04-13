#!/bin/bash
# hunt-a1.sh — OCI Ampere A1 Capacity Hunter
# Automatically provisions an Oracle Cloud Free Tier A1.Flex instance by retrying
# across availability domains until capacity is found.
#
# Oracle's Always Free A1 instances (up to 4 OCPU / 24 GB RAM) are rarely available.
# This script runs via cron every 2 minutes and tries each AD in sequence.
# On success: sends an email notification (optional) and disables the cron job.
#
# Setup:
#   1. Install and configure OCI CLI: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm
#   2. Copy hunt-a1.conf.example to ~/hunt-a1.conf — fill in your values
#   3. chmod 600 ~/hunt-a1.conf
#   4. chmod +x hunt-a1.sh
#   5. crontab -e → */2 * * * * /bin/bash ~/hunt-a1.sh >> ~/hunt-a1.log 2>&1
#   6. tail -f ~/hunt-a1.log to watch progress
#
# Requirements: oci-cli, curl (for email), python3, flock
# License: MIT

set -euo pipefail

CONF_FILE="${HUNT_A1_CONF:-${HOME}/hunt-a1.conf}"
LOCK_FILE="${HOME}/.hunt-a1.lock"
SUCCESS_FILE="${HOME}/.hunt-a1.success"

# --- Load config ---
if [[ ! -f "$CONF_FILE" ]]; then
    echo "[$(date -Is)] ERROR: Config file not found: $CONF_FILE"
    echo "  Copy hunt-a1.conf.example to $CONF_FILE and fill in your values."
    exit 1
fi
# shellcheck source=/dev/null
source "$CONF_FILE"

# --- Validate required config ---
required_vars=(
    COMPARTMENT_ID SUBNET_ID IMAGE_ID
    SSH_KEY_PATH INSTANCE_NAME SHAPE OCPUS MEMORY_GB
)
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "[$(date -Is)] ERROR: $var is missing in $CONF_FILE"
        exit 1
    fi
done

# At least one availability domain required
if [[ -z "${AD_1:-}" ]]; then
    echo "[$(date -Is)] ERROR: At least AD_1 must be set in $CONF_FILE"
    exit 1
fi

# Build AD list dynamically (supports 1 to 3 ADs)
ADS=("$AD_1")
[[ -n "${AD_2:-}" ]] && ADS+=("$AD_2")
[[ -n "${AD_3:-}" ]] && ADS+=("$AD_3")

# --- Guard: already succeeded ---
if [[ -f "$SUCCESS_FILE" ]]; then
    echo "[$(date -Is)] INFO: Instance already created (success file exists). Skipping."
    exit 0
fi

# --- Guard: prevent concurrent runs via flock ---
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date -Is)] INFO: Another instance is already running. Skipping."
    exit 0
fi

# --- Helper: send email (optional — silently skipped if SMTP not configured) ---
send_email() {
    local subject="$1"
    local body="$2"

    if [[ -z "${SMTP_USER:-}" || -z "${SMTP_PASS:-}" || -z "${NOTIFY_TO:-}" ]]; then
        return 0
    fi

    echo -e "Subject: ${subject}\nFrom: ${SMTP_USER}\nTo: ${NOTIFY_TO}\n\n${body}" | \
        curl -s --ssl-reqd \
            --url "smtps://${SMTP_HOST:-smtp.gmail.com}:${SMTP_PORT:-465}" \
            --netrc-file <(printf "machine %s login %s password %s\n" \
                "${SMTP_HOST:-smtp.gmail.com}" "${SMTP_USER}" "${SMTP_PASS}") \
            --mail-from "${SMTP_USER}" \
            --mail-rcpt "${NOTIFY_TO}" \
            -T - || echo "[$(date -Is)] WARN: Email send failed (non-blocking)."
}

# --- Helper: remove hunt-a1 cron entry ---
disable_cron() {
    crontab -l 2>/dev/null | grep -v "hunt-a1" | crontab - 2>/dev/null || true
    echo "[$(date -Is)] INFO: Cron entry removed."
}

# --- Helper: fetch public IP from VNIC (fallback when not in launch response) ---
fetch_public_ip() {
    local instance_id="$1"
    sleep 10

    local vnic_attachments
    vnic_attachments=$(oci compute vnic-attachment list \
        --compartment-id "$COMPARTMENT_ID" \
        --instance-id "$instance_id" 2>/dev/null || echo "")

    if [[ -z "$vnic_attachments" ]]; then
        echo "UNKNOWN"
        return
    fi

    local vnic_id
    vnic_id=$(echo "$vnic_attachments" | \
        python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(d[0]['vnic-id'] if d else '')" \
        2>/dev/null || echo "")

    if [[ -z "$vnic_id" ]]; then
        echo "UNKNOWN"
        return
    fi

    oci network vnic get --vnic-id "$vnic_id" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['data']['public-ip'])" \
        2>/dev/null || echo "UNKNOWN"
}

# --- Main: try each availability domain ---
echo "[$(date -Is)] INFO: Capacity hunt starting — ${#ADS[@]} AD(s) to try..."

for AD in "${ADS[@]}"; do
    echo "[$(date -Is)] INFO: Trying AD: $AD"

    RESULT=$(oci compute instance launch \
        --compartment-id "$COMPARTMENT_ID" \
        --availability-domain "$AD" \
        --shape "$SHAPE" \
        --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}" \
        --image-id "$IMAGE_ID" \
        --subnet-id "$SUBNET_ID" \
        --ssh-authorized-keys-file "$SSH_KEY_PATH" \
        --display-name "$INSTANCE_NAME" \
        --assign-public-ip true \
        --wait-for-state RUNNING \
        --max-wait-seconds 300 \
        2>&1) || true

    # --- Success: instance is RUNNING ---
    if echo "$RESULT" | grep -q '"lifecycle-state": "RUNNING"'; then
        INSTANCE_ID=$(echo "$RESULT" | \
            python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" \
            2>/dev/null || echo "UNKNOWN")

        PUBLIC_IP=$(echo "$RESULT" | \
            python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('data',{}).get('metadata',{}).get('public_ip',''))" \
            2>/dev/null || echo "")

        if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == "UNKNOWN" ]]; then
            PUBLIC_IP=$(fetch_public_ip "$INSTANCE_ID")
        fi

        echo "[$(date -Is)] SUCCESS: Instance created!"
        echo "  Instance ID: $INSTANCE_ID"
        echo "  Public IP:   $PUBLIC_IP"
        echo "  AD:          $AD"
        echo "  Shape:       $SHAPE ($OCPUS OCPU / $MEMORY_GB GB)"

        echo "$INSTANCE_ID" > "$SUCCESS_FILE"

        send_email \
            "[hunt-a1] Instance CREATED — $PUBLIC_IP" \
            "A1 instance provisioned!\n\nInstance ID: ${INSTANCE_ID}\nPublic IP: ${PUBLIC_IP}\nAD: ${AD}\nShape: ${SHAPE} (${OCPUS} OCPU / ${MEMORY_GB} GB)\nDate: $(date -Is)\n\nNext step:\n  ssh ubuntu@${PUBLIC_IP}"

        disable_cron
        exit 0
    fi

    # --- Retryable: out of capacity or rate-limited ---
    if echo "$RESULT" | grep -qi "OUT_OF_HOST_CAPACITY\|Out of host capacity\|InternalError\|TooManyRequests"; then
        echo "[$(date -Is)] RETRY: $AD — no capacity or throttled."
        continue
    fi

    # --- Fatal: config/auth error (try remaining ADs, might be AD-specific) ---
    if echo "$RESULT" | grep -qi "LimitExceeded\|NotAuthorized\|InvalidParameter\|NotAuthenticated\|ServiceError"; then
        echo "[$(date -Is)] FATAL: Config error on $AD"
        echo "$RESULT"
        send_email "[hunt-a1] ERROR on $AD" "Fatal error on AD ${AD}:\n\n${RESULT}\n\nCheck hunt-a1.conf."
        continue
    fi

    # --- Unknown response ---
    echo "[$(date -Is)] WARN: Unexpected response on $AD"
    echo "$RESULT" | head -20
done

echo "[$(date -Is)] INFO: No capacity on any AD. Will retry next cron cycle."

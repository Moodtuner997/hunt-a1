#!/bin/bash
# hunt-a1.sh — OCI Ampere A1 Capacity Hunter
# Automatically provisions an Oracle Cloud Free Tier A1.Flex instance by retrying
# across availability domains until capacity is found.
#
# Oracle's Always Free A1 instances (2 OCPU / 12 GB RAM since June 15, 2026)
# are rarely available. This script runs via cron every 2 minutes and tries
# each AD in sequence.
# On success: sends an email notification (optional) and disables the cron job.
# On repeated fatal errors (bad config, LimitExceeded): a circuit breaker
# disarms the cron and sends a single alert instead of retrying forever.
#
# Setup:
#   1. Install and configure OCI CLI: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm
#   2. Copy hunt-a1.conf.example to ~/hunt-a1.conf — fill in your values
#   3. chmod 600 ~/hunt-a1.conf
#   4. chmod +x hunt-a1.sh
#   5. crontab -e → */2 * * * * /bin/bash ~/hunt-a1.sh >> ~/hunt-a1.log 2>&1
#   6. tail -f ~/hunt-a1.log to watch progress
#
# Requirements: oci-cli, curl (for email), flock. python3 is optional
# (used for robust JSON parsing when present; grep fallback otherwise).
# License: MIT

set -euo pipefail

CONF_FILE="${HUNT_A1_CONF:-${HOME}/hunt-a1.conf}"
LOCK_FILE="${HOME}/.hunt-a1.lock"
SUCCESS_FILE="${HOME}/.hunt-a1.success"
FATAL_FILE="${HOME}/.hunt-a1.fatal"
FAIL_COUNT_FILE="${HOME}/.hunt-a1.failcount"

# --- Guard: circuit breaker already tripped ---
# The breaker also removes the cron entry, so this is a belt-and-braces guard.
# Silent on purpose: no log spam if a stale cron entry survives.
# To resume hunting after fixing your config: rm ~/.hunt-a1.fatal
if [[ -f "$FATAL_FILE" ]]; then
    exit 0
fi

# --- Load config ---
if [[ ! -f "$CONF_FILE" ]]; then
    echo "[$(date -Is)] ERROR: Config file not found: $CONF_FILE"
    echo "  Copy hunt-a1.conf.example to $CONF_FILE and fill in your values."
    exit 1
fi
# Warn if the config file is world/group readable (it may contain SMTP creds)
CONF_PERMS=$(stat -c '%a' "$CONF_FILE" 2>/dev/null || stat -f '%Lp' "$CONF_FILE" 2>/dev/null || echo "")
if [[ -n "$CONF_PERMS" && "$CONF_PERMS" != "600" && "$CONF_PERMS" != "400" ]]; then
    echo "[$(date -Is)] WARN: $CONF_FILE has permissions $CONF_PERMS — run: chmod 600 $CONF_FILE"
fi

# shellcheck source=/dev/null
source "$CONF_FILE"

# Circuit breaker threshold (overridable in the conf file)
MAX_CONSECUTIVE_FATALS="${MAX_CONSECUTIVE_FATALS:-30}"

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

# --- Helper: remove hunt-a1 cron entry (idempotent) ---
disable_cron() {
    crontab -l 2>/dev/null | grep -v "hunt-a1" | crontab - 2>/dev/null || true
    echo "[$(date -Is)] INFO: Cron entry removed."
}

# --- Helper: extract a field from an OCI JSON response (stdin) ---
# Uses python3 for real JSON parsing when available, grep fallback otherwise.
json_field() {
    local field="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import sys, json
d = json.load(sys.stdin).get('data')
if isinstance(d, list):
    d = d[0] if d else {}
print((d or {}).get(sys.argv[1]) or '')" "$field" 2>/dev/null || echo ""
    else
        grep -o "\"${field}\": *\"[^\"]*\"" | head -1 | sed 's/^[^:]*: *"//; s/"$//' || echo ""
    fi
}

# --- Helpers: consecutive fatal-error counter (circuit breaker) ---
read_fail_count() {
    local count
    count=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    echo "$count"
}

reset_fail_count() {
    rm -f "$FAIL_COUNT_FILE"
}

trip_breaker() {
    local last_error="$1"
    {
        echo "Tripped: $(date -Is)"
        echo "Reason: ${MAX_CONSECUTIVE_FATALS} consecutive fatal errors (LimitExceeded / NotAuthorizedOrNotFound / config)."
        echo "Fix ${CONF_FILE}, then re-arm with: rm ${FATAL_FILE}"
        echo ""
        echo "Last error:"
        echo "$last_error"
    } > "$FATAL_FILE"
    disable_cron
    echo "[$(date -Is)] FATAL: Circuit breaker tripped after ${MAX_CONSECUTIVE_FATALS} consecutive fatal errors. Cron disarmed."
    echo "  Fix your config, then re-arm with: rm ${FATAL_FILE}"
    send_email \
        "[hunt-a1] STOPPED — circuit breaker tripped" \
        "hunt-a1 hit ${MAX_CONSECUTIVE_FATALS} consecutive fatal errors and stopped itself.\n\nThis usually means the requested shape exceeds your service limits (Free Tier since June 2026: 2 OCPU / 12 GB total, max 2 instances) or the OCI config is wrong.\n\nLast error:\n${last_error}\n\nThe cron entry has been removed. Fix ${CONF_FILE}, then re-arm with:\n  rm ${FATAL_FILE}\nand re-add the cron entry."
    exit 1
}

# --- Helper: fetch public IP from VNIC (not present in the launch response) ---
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
    vnic_id=$(echo "$vnic_attachments" | json_field "vnic-id")

    if [[ -z "$vnic_id" ]]; then
        echo "UNKNOWN"
        return
    fi

    local public_ip
    public_ip=$(oci network vnic get --vnic-id "$vnic_id" 2>/dev/null | json_field "public-ip")
    echo "${public_ip:-UNKNOWN}"
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
        reset_fail_count

        INSTANCE_ID=$(echo "$RESULT" | json_field "id")
        INSTANCE_ID="${INSTANCE_ID:-UNKNOWN}"

        PUBLIC_IP=$(fetch_public_ip "$INSTANCE_ID")

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

    # --- Retryable: out of capacity or rate-limited (this is normal) ---
    if echo "$RESULT" | grep -qi "OUT_OF_HOST_CAPACITY\|Out of host capacity\|InternalError\|TooManyRequests"; then
        echo "[$(date -Is)] RETRY: $AD — no capacity or throttled."
        reset_fail_count
        continue
    fi

    # --- Fatal: config/limit/auth error (counted by the circuit breaker) ---
    # No per-error email here: on a misconfigured account (e.g. OCPUS=4 on a
    # post-June-2026 Free Tier) every attempt fails with LimitExceeded, and
    # emailing each one is inbox spam. One email is sent when the breaker trips.
    if echo "$RESULT" | grep -qi "LimitExceeded\|NotAuthorized\|InvalidParameter\|NotAuthenticated\|ServiceError"; then
        FAIL_COUNT=$(( $(read_fail_count) + 1 ))
        echo "$FAIL_COUNT" > "$FAIL_COUNT_FILE"
        echo "[$(date -Is)] FATAL: Config/limit error on $AD (consecutive fatal ${FAIL_COUNT}/${MAX_CONSECUTIVE_FATALS})"
        echo "$RESULT" | head -20
        if (( FAIL_COUNT >= MAX_CONSECUTIVE_FATALS )); then
            trip_breaker "$(echo "$RESULT" | head -20)"
        fi
        continue
    fi

    # --- Unknown response ---
    echo "[$(date -Is)] WARN: Unexpected response on $AD"
    echo "$RESULT" | head -20
done

echo "[$(date -Is)] INFO: No capacity on any AD. Will retry next cron cycle."

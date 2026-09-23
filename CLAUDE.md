# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Public MIT project: a single dependency-free bash script (`hunt-a1.sh`) that retries `oci compute instance launch` across availability domains via cron until Oracle Cloud Always Free Ampere A1 capacity is found. Differentiator vs other hunters: only bash + the OCI CLI, auditable in minutes.

## Commands

```bash
cp hunt-a1.conf.example ~/hunt-a1.conf && chmod 600 ~/hunt-a1.conf   # config (script warns if perms != 600/400)
bash hunt-a1.sh                     # one manual run (logs to stdout with ISO timestamps)
HUNT_A1_CONF=/other/path.conf bash hunt-a1.sh   # alternate config location
shellcheck hunt-a1.sh               # lint (script carries `# shellcheck source=/dev/null` for the conf source)
bash -n hunt-a1.sh                  # syntax check without running

# cron install (every 2 min) — this is the "deploy"
chmod +x hunt-a1.sh
crontab -e   # */2 * * * * /bin/bash /path/to/hunt-a1.sh >> ~/hunt-a1.log 2>&1
tail -f ~/hunt-a1.log

# re-arm after the circuit breaker tripped
rm ~/.hunt-a1.fatal   # then re-add the cron line
```

There is no test suite and no mock of the OCI CLI; a real run needs `oci` configured (`oci setup config`), `curl`, `flock`, optionally `python3`.

## Architecture (execution flow of `hunt-a1.sh`)

1. `set -euo pipefail`. Exit silently if `~/.hunt-a1.fatal` exists (breaker guard, no log spam from a stale cron).
2. Load `$HUNT_A1_CONF` (default `~/hunt-a1.conf`); validate `COMPARTMENT_ID SUBNET_ID IMAGE_ID SSH_KEY_PATH INSTANCE_NAME SHAPE OCPUS MEMORY_GB` and at least `AD_1`. `AD_2`/`AD_3` are optional; the AD list is built dynamically.
3. Exit if `~/.hunt-a1.success` exists; take a non-blocking `flock` on `~/.hunt-a1.lock` (fd 9).
4. For each AD: `oci compute instance launch ... --wait-for-state RUNNING --max-wait-seconds 300`, output captured with `|| true`. Then classify the response by grep:
   - `"lifecycle-state": "RUNNING"` -> success: write instance id to the success file, fetch public IP via vnic-attachment + `oci network vnic get`, email, `disable_cron`, exit 0.
   - `OUT_OF_HOST_CAPACITY|Out of host capacity|InternalError|TooManyRequests` -> retryable: reset fail counter, next AD.
   - `LimitExceeded|NotAuthorized|InvalidParameter|NotAuthenticated|ServiceError` -> fatal: increment `~/.hunt-a1.failcount`; at `MAX_CONSECUTIVE_FATALS` (default 30) `trip_breaker` writes `~/.hunt-a1.fatal`, removes the cron line, sends ONE email, exit 1.
   - anything else -> WARN with first 20 lines.
5. `disable_cron` = `crontab -l | grep -v hunt-a1 | crontab -` (matches on the string `hunt-a1`, so the cron line must contain it).
6. Email is optional: skipped unless `SMTP_USER`, `SMTP_PASS`, `NOTIFY_TO` are all set; sent with curl `smtps://` and a `--netrc-file` process substitution (defaults `smtp.gmail.com:465`). Failures are non-blocking.
7. `json_field` parses OCI JSON with python3 when present, grep/sed fallback otherwise.

State files all live in `$HOME`: `.hunt-a1.lock`, `.hunt-a1.success`, `.hunt-a1.fatal`, `.hunt-a1.failcount` (all gitignored, as are `*.conf` except the example and `*.log`).

## Conventions and gotchas

- Public repo: keep it user-agnostic — no real OCIDs, regions, emails or hostnames in committed files. Real values live only in `~/hunt-a1.conf`.
- Free Tier A1 limits (see README 'June 2026 Free Tier change') are 2 OCPU / 12 GB total, max 2 instances; keep README, conf example, script and this line in sync. Asking for more on Free Tier yields `LimitExceeded` on every attempt and is exactly what the circuit breaker exists for.
- Keep the script single-file and zero-dependency; do not add Python/Node tooling.
- Log lines follow `[$(date -Is)] LEVEL: message` with levels INFO / RETRY / FATAL / WARN / SUCCESS / ERROR — the README tells users to `grep SUCCESS`.
- README is English; commit messages English. The README links to hitrov/oci-arm-host-capacity as the archived historical reference.

<!-- chaine-release -->
## Release

Fleet rule in the workspace `CLAUDE.md` (`../CLAUDE.md`, "Commits et release"). Here: release-please type
`simple`, `bash scripts/release.sh hunt-a1` from the workspace root; after the release PR is merged it
stops at tag + changelog, nothing is deployed. Versions: https://github.com/Moodtuner997/hunt-a1/releases

# hunt-a1

Automated capacity hunter for Oracle Cloud Always Free A1 instances.

Oracle's Ampere A1 Flex instances (ARM64, up to 4 OCPU / 24 GB RAM) are [Always Free](https://www.oracle.com/cloud/free/) but almost never available — new launches fail with `OUT_OF_HOST_CAPACITY`. This script retries automatically via cron until it succeeds.

## How it works

```
cron (every 2 min)
  └─ hunt-a1.sh
       ├─ Try AD-1 → oci compute instance launch → OUT_OF_HOST_CAPACITY → next
       ├─ Try AD-2 → oci compute instance launch → OUT_OF_HOST_CAPACITY → next
       ├─ Try AD-3 → oci compute instance launch → RUNNING ✓
       │    ├─ Save instance ID to ~/.hunt-a1.success
       │    ├─ Send email notification (optional)
       │    └─ Remove itself from crontab
       └─ No capacity → exit, retry next cycle
```

**Safety features:**
- `flock` prevents concurrent runs
- Success file stops all future attempts
- Cron self-disables after provisioning
- Fatal errors (auth, quota) are reported but don't kill the loop
- Email notifications are optional

## Prerequisites

- An [Oracle Cloud account](https://cloud.oracle.com/) (Free Tier works)
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) installed and configured (`oci setup config`)
- A VCN + public subnet created in your tenancy ([quickstart](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/quickstartnetworking.htm))
- An SSH key pair (`ssh-keygen -t ed25519`)
- A Linux machine to run the cron (your existing server, a free E2 micro instance, WSL, etc.)

## Quick start

```bash
# 1. Clone
git clone https://github.com/YOUR_USERNAME/hunt-a1.git
cd hunt-a1

# 2. Configure
cp hunt-a1.conf.example ~/hunt-a1.conf
nano ~/hunt-a1.conf          # Fill in your OCI values
chmod 600 ~/hunt-a1.conf     # Protect credentials

# 3. Test once manually
bash hunt-a1.sh

# 4. Set up cron (retries every 2 minutes)
chmod +x hunt-a1.sh
crontab -e
# Add this line:
# */2 * * * * /bin/bash /path/to/hunt-a1.sh >> ~/hunt-a1.log 2>&1

# 5. Watch progress
tail -f ~/hunt-a1.log
```

## Configuration

See [`hunt-a1.conf.example`](hunt-a1.conf.example) for all options. Key values you need to find:

| Variable | How to find it |
|---|---|
| `COMPARTMENT_ID` | OCI Console → Identity → Compartments → copy OCID |
| `SUBNET_ID` | OCI Console → Networking → VCN → Subnets → copy OCID |
| `IMAGE_ID` | `oci compute image list --compartment-id $CID --shape "VM.Standard.A1.Flex" --query 'data[0].id'` |
| `AD_1`, `AD_2`... | `oci iam availability-domain list --query 'data[].name' --output table` |

### Email notifications (optional)

Set `SMTP_USER`, `SMTP_PASS`, and `NOTIFY_TO` in your config to get an email when the instance is created. For Gmail, use an [App Password](https://myaccount.google.com/apppasswords). Leave all three empty to disable.

## After success

Once `hunt-a1.sh` creates your instance:

```bash
# Check the log
cat ~/hunt-a1.log | grep SUCCESS

# SSH into your new server
ssh ubuntu@<PUBLIC_IP>

# The cron job is already removed, but verify
crontab -l | grep hunt-a1    # Should return nothing

# Clean up state files
rm ~/.hunt-a1.lock ~/.hunt-a1.success
```

## FAQ

**Can I run this from my local machine instead of a server?**
Yes, but your machine needs to be on 24/7 for cron to run. A free Oracle E2.Micro instance (x86, Always Free) is a good place to run it.

**How long does it take to find capacity?**
Anywhere from minutes to weeks. Popular regions (Frankfurt, London, Phoenix) are harder. Less popular regions may have immediate availability.

**Can I split the 4 OCPU across multiple instances?**
Yes. Change `OCPUS` and `MEMORY_GB` in the config. The Free Tier total is 4 OCPU + 24 GB across all A1 instances. Run the script once per instance you want.

**Will Oracle ban me for this?**
This script uses the official OCI CLI at a gentle rate (1 call per 2 minutes). There are no reports of accounts being terminated for API-based provisioning. That said, Oracle reserves the right to terminate Free Tier accounts at their discretion — this applies to all Free Tier usage, not just automation.

**What's the difference between this and [hitrov/oci-arm-host-capacity](https://github.com/hitrov/oci-arm-host-capacity)?**
hitrov's tool is a PHP/Docker solution with a web UI. This is a single bash script with zero dependencies beyond the OCI CLI. Pick whichever fits your setup.

## Disclaimer

This tool is provided as-is. It uses Oracle Cloud's official API within documented rate limits. However, Oracle Cloud Free Tier accounts are subject to Oracle's terms and may be reclaimed or terminated at Oracle's sole discretion. Use at your own risk.

This project is not affiliated with, endorsed by, or sponsored by Oracle Corporation.

## License

[MIT](LICENSE)

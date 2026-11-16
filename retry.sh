#!/usr/bin/env bash
# One attempt to create a cloud instance that is often "out of capacity". Started every few minutes (see run.yml).
#
# Public repo rules: nothing identifying lives in this file, the workflow, the logs or the issues.
#   - All settings come from one secret, RETRY_CONFIG (KEY=VALUE lines), and every value is masked in the log.
#   - Issue titles/bodies are generic; error messages have cloud ids and long base64 blobs removed.
#
# Exit codes are chosen so GitHub does NOT email on every out-of-capacity run:
#   exit 0  = fine / keep trying next run (out of capacity, rate limit, temporary error, or done)
#   exit 1  = only for a problem that also stops the job and opens an issue (one email, not one per run)
#
# What it handles:
#   - instance already exists (earlier run, manual click)  -> issue + switch off (never a second instance)
#   - accepted but TERMINATED while starting               -> keep trying
#   - still starting after the wait                         -> issue ("check it") + switch off
#   - out of capacity / rate limit / provider 5xx / network -> quiet, try next run
#   - login or permission problem, limits exceeded          -> issue + switch off
#   - image/subnet not found (lookup worked, found nothing) -> issue + switch off
#   - missing setting, network join key about to expire     -> issue + switch off
#   - unknown error                                         -> one issue (deduplicated), keep trying
# "Switch off" = this workflow AND the cron-job.org job that starts it (CRONJOB_API_KEY + CRONJOB_JOB_ID, best effort).
set -uo pipefail

SHAPE="VM.Standard.A1.Flex"
WAIT_SECONDS="${WAIT_SECONDS:-900}"
REPO="${GITHUB_REPOSITORY:-local/test}"
WORKFLOW_FILE="${WORKFLOW_FILE:-run.yml}"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"

mask() { [ "${#1}" -ge 4 ] && echo "::add-mask::$1"; return 0; }   # GitHub hides this value from then on

load_config() { # RETRY_CONFIG: KEY=VALUE lines -> the variables below, each value masked first
  [ -z "${RETRY_CONFIG:-}" ] && return 0
  local line k v
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
    k="${line%%=*}"; v="${line#*=}"
    mask "$v"
    case "$k" in
      OCI_USER)        export OCI_CLI_USER="$v" ;;
      OCI_TENANCY)     export OCI_CLI_TENANCY="$v" ;;
      OCI_FINGERPRINT) export OCI_CLI_FINGERPRINT="$v" ;;
      OCI_REGION)      export OCI_CLI_REGION="$v" ;;
      INSTANCE_NAME)   export INSTANCE_NAME="$v" ;;
      SUBNET_NAME)     export SUBNET_NAME="$v" ;;
      TS_TAG)          export TS_TAG="$v" ;;
      CRONJOB_JOB_ID)  export CRONJOB_JOB_ID="$v" ;;
      SSH_PUBLIC_KEY)  export SSH_PUBLIC_KEY="$v" ;;
      *)               echo "(ignoring an unknown setting in RETRY_CONFIG)" ;;
    esac
  done <<<"$RETRY_CONFIG"
}
load_config
for _v in OCI_CLI_USER OCI_CLI_TENANCY OCI_CLI_FINGERPRINT INSTANCE_NAME SUBNET_NAME TS_TAG SSH_PUBLIC_KEY; do
  [ -n "${!_v:-}" ] && mask "${!_v}"
done

redact() { # drop secrets, cloud ids, join keys and long base64 (the first-boot script travels base64-encoded)
  local s; s=$(cat)
  [ -n "${TS_AUTHKEY:-}" ] && s="${s//"$TS_AUTHKEY"/[secret]}"
  printf '%s\n' "$s" | sed -E 's/ocid1\.[A-Za-z0-9._-]+/[id]/g; s/tskey-[A-Za-z0-9-]+/[secret]/g; s/[A-Za-z0-9+\/=_-]{40,}/[redacted]/g' | cut -c1-300
}

provider_message() { # the provider's error code + message only
  local m
  m=$(grep -oE '"(code|message)": "[^"]*"' <<<"$1" | head -2)
  if [ -n "$m" ]; then printf '%s\n' "$m" | redact
  else grep -m1 -iE 'error|exception|timed out|refused' <<<"$1" | redact; fi
}

classify() { # -> capacity | rate | auth | limit | transient | unknown
  local t="$1"
  if grep -qiE 'out of (host )?capacity' <<<"$t"; then echo capacity
  elif grep -qE 'TooManyRequests|"status": 429' <<<"$t"; then echo rate
  elif grep -qE 'NotAuthenticated|NotAuthorized|"status": 40[13]|private key|fingerprint|key_content|key_file' <<<"$t"; then echo auth
  elif grep -qiE 'LimitExceeded|QuotaExceeded|limit exceeded' <<<"$t"; then echo limit
  elif grep -qiE '"status": 5[0-9][0-9]|InternalError|ServiceUnavailable|RequestException|ConnectionError|ConnectTimeout|ReadTimeout|timed out|Max retries exceeded|name resolution|Connection reset|EOF occurred|RemoteDisconnected' <<<"$t"; then echo transient
  else echo unknown; fi
}

open_issue() { # $1 title, $2 body — skipped if an open issue with this exact title exists
  local n
  n=$(gh issue list --repo "$REPO" --state open --search "\"$1\" in:title" --json title \
        --jq "[.[] | select(.title == \"$1\")] | length" 2>/dev/null || echo 0)
  local body="$2"
  # Mentioning the owner makes GitHub treat it as "participating", so the email arrives even with quiet settings.
  [ -n "${NOTIFY_USER:-}" ] && body="$body"$'\n\n'"@${NOTIFY_USER} (notification from this job)"
  if [ "${n:-0}" = "0" ]; then
    gh issue create --repo "$REPO" --title "$1" --body "$body" >/dev/null || { echo "(could not open issue)"; return 1; }
  else
    echo "(issue already open: $1)"
  fi
}

trigger_off() { # switch the cron-job.org job off too (its API: PATCH /jobs/<id> {"job":{"enabled":false}})
  # returns 0 = switched off, 1 = API call failed, 2 = no key configured
  if [ -z "${CRONJOB_API_KEY:-}" ] || [ -z "${CRONJOB_JOB_ID:-}" ]; then
    echo "(no cron-job.org key set: switch the cron-job.org job off by hand)"
    return 2
  fi
  local i
  for i in 1 2; do
    if curl -fsS -m 20 -X PATCH -H 'Content-Type: application/json' \
         -H "Authorization: Bearer ${CRONJOB_API_KEY}" -d '{"job":{"enabled":false}}' \
         "https://api.cron-job.org/jobs/${CRONJOB_JOB_ID}" >/dev/null 2>&1; then
      echo "cron-job.org job switched off."; return 0
    fi
    sleep 5
  done
  echo "(could not switch the cron-job.org job off: do it by hand at cron-job.org → Cronjobs)"
  return 1
}

stop_job() { # $1 title, $2 body — stops everything: issue, this workflow, and the cron-job.org trigger
  open_issue "$1" "$2" || true
  gh workflow disable "$WORKFLOW_FILE" --repo "$REPO" >/dev/null 2>&1 || echo "(could not switch the workflow off)"
  trigger_off || true
}

# Run an oci command: stdout -> $OUT, stdout+stderr -> $ALL, exit code -> $RC
run_oci() {
  local err="$TMP/oci_err.txt"
  OUT=$(oci "$@" 2>"$err"); RC=$?
  ALL="$OUT"$'\n'"$(cat "$err" 2>/dev/null)"
  rm -f "$err"
}

# A failed command that is not "capacity": decide what to do. $1 = what we were doing.
handle_failure() {
  local kind; kind=$(classify "$ALL")
  echo "$1 failed ($kind):"; provider_message "$ALL"
  case "$kind" in
    capacity)  echo "out of capacity — will try again next run"; exit 0 ;;
    rate)      echo "rate limited — will try again next run"; exit 0 ;;
    transient) echo "temporary problem — will try again next run"; exit 0 ;;
    auth)      stop_job "Stopped: login or permission problem" \
                 "While **$1**, the provider refused the request for a login/permission reason. Nothing was created. Check the API key and the repo secrets, then re-enable the workflow in the Actions tab."
               exit 1 ;;
    limit)     stop_job "Stopped: free limits already used" \
                 "While **$1**, the provider said a limit is exceeded. Something else may be using the free resources. Nothing was created by this run."
               exit 1 ;;
    *)         open_issue "Retry: unexpected error" \
                 "While **$1**, the provider returned an error this job does not recognise. It keeps retrying. Latest message:"$'\n\n```\n'"$(provider_message "$ALL")"$'\n```'
               exit 0 ;;
  esac
}

# --- Test mode (manual run only): prove the cron-job.org key works; touches nothing else ------------------
if [ "${MODE:-retry}" = "test-trigger-off" ]; then
  echo "TEST MODE: switching the cron-job.org job off. The provider and this workflow are not touched."
  if trigger_off; then echo "Test passed. Switch the cron-job.org job back on."; exit 0; fi
  exit 1
fi

# --- Test mode 2 (manual run only): real issue + email, and the workflow off/on round trip -------------------
if [ "${MODE:-retry}" = "test-success-path" ]; then
  echo "TEST MODE: opening a test issue and switching this workflow off and back on. Nothing else is touched."
  bad=0
  if open_issue "TEST notification (safe to close)" \
       "Test of the 'done' notification. If you got an email for this, notifications work. Nothing was created and retries continue. You can close this issue."; then
    echo "test issue step done."
  else echo "(could not open the test issue)"; bad=1; fi
  if gh workflow disable "$WORKFLOW_FILE" --repo "$REPO" >/dev/null 2>&1; then echo "workflow switched off."
  else echo "(could not switch the workflow off)"; bad=1; fi
  if gh workflow enable "$WORKFLOW_FILE" --repo "$REPO" >/dev/null 2>&1; then echo "workflow switched back on."
  else echo "(could not switch the workflow back on: re-enable it in the Actions tab)"; bad=1; fi
  [ $bad -eq 0 ] && echo "Test passed."
  exit $bad
fi

# --- 0. Preconditions ---------------------------------------------------------------------------------------
for v in OCI_CLI_USER OCI_CLI_TENANCY OCI_CLI_FINGERPRINT OCI_CLI_REGION OCI_CLI_KEY_CONTENT TS_AUTHKEY SSH_PUBLIC_KEY \
         INSTANCE_NAME SUBNET_NAME TS_TAG; do
  if [ -z "${!v:-}" ]; then
    stop_job "Stopped: missing setting $v" "The value **$v** is empty. Add it (RETRY_CONFIG or the repo secrets), then re-enable the workflow."
    exit 1
  fi
done
if [ -n "${TS_KEY_STOP_AFTER:-}" ]; then
  now=$(date -u +%s); stop=$(date -u -d "$TS_KEY_STOP_AFTER" +%s 2>/dev/null || echo 0)
  if [ "$stop" -gt 0 ] && [ "$now" -ge "$stop" ]; then
    stop_job "Paused: network join key expiring" \
      "The one-off network join key (TS_AUTHKEY) is about to expire, so an instance created now could not join. Make a new one, update the TS_AUTHKEY secret and TS_KEY_STOP_AFTER in the workflow, then re-enable the workflow."
    exit 0
  fi
fi
T="$OCI_CLI_TENANCY"
NAME="$INSTANCE_NAME"

# --- 1. Already there? --------------------------------------------------------------------------------------
run_oci compute instance list -c "$T" --display-name "$NAME" --all \
  --query 'length(data[?"lifecycle-state"!=`TERMINATED` && "lifecycle-state"!=`TERMINATING`])' --raw-output
[ $RC -ne 0 ] && handle_failure "checking for an existing instance"
existing="${OUT//[[:space:]]/}"; existing="${existing:-0}"   # prints nothing when the list is empty
if ! [[ "$existing" =~ ^[0-9]+$ ]]; then echo "unexpected list output"; provider_message "$ALL"; exit 0; fi
if [ "$existing" -gt 0 ]; then
  echo "the instance already exists — switching the retry job off."
  stop_job "Done: instance already exists" \
    "The instance already exists, so this retry job has switched itself off (and its cron trigger). Next steps are in your private notes."
  exit 0
fi

# --- 2. Look up zone, subnet and image by name (no hard-coded ids) ------------------------------------------
run_oci iam availability-domain list -c "$T" --query 'data[0].name' --raw-output
[ $RC -ne 0 ] && handle_failure "looking up the availability domain"
AD="${OUT//[[:space:]]/}"; mask "$AD"

run_oci network subnet list -c "$T" --display-name "$SUBNET_NAME" --all --query 'data[0].id' --raw-output
[ $RC -ne 0 ] && handle_failure "looking up the subnet"
SUBNET="${OUT//[[:space:]]/}"; mask "$SUBNET"

IMG_FILTER='data[?!contains("display-name", `Minimal`)] | [0]'
run_oci compute image list -c "$T" --operating-system "Canonical Ubuntu" --operating-system-version "26.04" \
  --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC --all --query "$IMG_FILTER.id" --raw-output
[ $RC -ne 0 ] && handle_failure "looking up the Ubuntu image"
IMAGE="${OUT//[[:space:]]/}"
run_oci compute image list -c "$T" --operating-system "Canonical Ubuntu" --operating-system-version "26.04" \
  --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC --all --query "$IMG_FILTER.\"display-name\"" --raw-output
IMAGE_NAME="${OUT//[[:space:]]/}"
echo "image: ${IMAGE_NAME:-none}"

for pair in "availability domain:$AD" "subnet:$SUBNET" "Ubuntu 26.04 Arm image:$IMAGE"; do
  label="${pair%%:*}"; val="${pair#*:}"
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    stop_job "Stopped: $label not found" \
      "The provider answered but no **$label** was found, so the launch settings need a look. Nothing was created."
    exit 1
  fi
done

# --- 3. First-boot script: join the private network, retrying through network hiccups. Never printed. --------
umask 077
CI="$TMP/cloud-init.yaml"
cat > "$CI" <<EOF
#cloud-config
runcmd:
  - |
    for i in \$(seq 1 20); do curl -fsSL https://tailscale.com/install.sh | sh && break; sleep 30; done
    for i in \$(seq 1 20); do tailscale up --auth-key='${TS_AUTHKEY}' --ssh --hostname='${NAME}' --advertise-tags='${TS_TAG}' && break; sleep 30; done
EOF
SSH_PUB="$TMP/ssh.pub"
printf '%s\n' "$SSH_PUBLIC_KEY" > "$SSH_PUB"

# --- 4. One launch attempt; wait until it is RUNNING (or TERMINATED) ----------------------------------------
run_oci compute instance launch \
  --compartment-id "$T" --availability-domain "$AD" --display-name "$NAME" \
  --shape "$SHAPE" --shape-config '{"ocpus": 2, "memoryInGBs": 12}' \
  --image-id "$IMAGE" --subnet-id "$SUBNET" --assign-public-ip true \
  --boot-volume-size-in-gbs 100 --is-pv-encryption-in-transit-enabled true \
  --ssh-authorized-keys-file "$SSH_PUB" --user-data-file "$CI" \
  --instance-options '{"areLegacyImdsEndpointsDisabled": true}' \
  --agent-config '{"isMonitoringDisabled": false, "isManagementDisabled": false, "pluginsConfig": [{"name": "Compute Instance Monitoring", "desiredState": "ENABLED"}, {"name": "Compute Instance Run Command", "desiredState": "ENABLED"}]}' \
  --wait-for-state RUNNING --wait-for-state TERMINATED --max-wait-seconds "$WAIT_SECONDS" --wait-interval-seconds 20 \
  --query 'data."lifecycle-state"' --raw-output --no-retry
rm -f "$CI"
STATE="${OUT//[[:space:]]/}"

case $RC in
  0)
    if [ "$STATE" = "RUNNING" ]; then
      echo "SUCCESS — the instance is RUNNING."
      stop_job "Done: instance created" \
        "The instance is running. This retry job has switched itself off (and its cron trigger). Next steps are in your private notes."
      exit 0
    fi
    echo "the launch was accepted but the instance ended up ${STATE:-unknown} — will try again next run."
    exit 0 ;;
  2)
    echo "launch accepted, still not RUNNING after ${WAIT_SECONDS}s."
    stop_job "Check: instance still starting" \
      "The launch was accepted but the instance was not RUNNING after ${WAIT_SECONDS}s. This job switched itself off so it can't create a second one. Check the instance in the provider's console: if it is TERMINATED, re-enable the workflow."
    exit 0 ;;
  *)
    handle_failure "launching the instance" ;;
esac

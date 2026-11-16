#!/usr/bin/env bash
# Runs retry.sh against a fake `oci` and fake `gh` for every edge case. Usage: bash tests/test_retry.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; BIN="$WORK/bin"; mkdir -p "$BIN"
PASS=0; FAIL=0

cat > "$BIN/oci" <<'EOF'
#!/usr/bin/env bash
# Fake provider CLI. Each step reads <STEP>_OUT / <STEP>_ERR / <STEP>_RC from the environment.
echo "oci $*" >> "$LOG"
q=""; prev=""; for a in "$@"; do [ "$prev" = "--query" ] && q="$a"; prev="$a"; done
case "$1 $2 $3" in
  "compute instance list")       s=LIST ;;
  "iam availability-domain list") s=AD ;;
  "network subnet list")         s=SUBNET ;;
  "compute image list")          case "$q" in *.id) s=IMG ;; *) s=IMGNAME ;; esac ;;
  "compute instance launch")     s=LAUNCH
     f=""; prev=""; for a in "$@"; do [ "$prev" = "--user-data-file" ] && f="$a"; prev="$a"; done
     [ -n "$f" ] && cp "$f" "$WORKDIR/cloud-init.copy" ;;
  *) s=OTHER ;;
esac
o="${s}_OUT"; e="${s}_ERR"; r="${s}_RC"
[ -n "${!o:-}" ] && printf '%s\n' "${!o}"
[ -n "${!e:-}" ] && printf '%s\n' "${!e}" >&2
exit "${!r:-0}"
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$LOG"
case "$*" in
  "issue list"*) echo "${OPEN_ISSUES:-0}" ;;
  "issue create"*) printf '%s\n' "$*" >> "$LOG.issues"; exit "${GH_ISSUE_RC:-0}" ;;
  "workflow enable"*) exit "${GH_ENABLE_RC:-0}" ;;
esac
exit 0
EOF
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl: records the call (headers included, only in the private log) and fails if CURL_RC says so.
echo "curl $*" >> "$LOG"
[ "${CURL_RC:-0}" = 0 ] && echo "{}"
exit "${CURL_RC:-0}"
EOF
chmod +x "$BIN/oci" "$BIN/gh" "$BIN/curl"

CAP_ERR='ServiceError:
{
    "code": "InternalError",
    "message": "Out of host capacity.",
    "opc-request-id": "ABC/DEF",
    "status": 500
}'

run_case() { # name, expected_exit, then env assignments
  local name="$1" want="$2"; shift 2
  export LOG="$WORK/$name.log" WORKDIR="$WORK"; : > "$LOG"; : > "$LOG.issues"; rm -f "$WORK/cloud-init.copy"
  local out rc
  out=$(env -i PATH="$BIN:/usr/bin:/bin:$PATH" HOME="$HOME" LOG="$LOG" WORKDIR="$WORK" RUNNER_TEMP="$WORK" \
        GITHUB_REPOSITORY="me/retry-runner" OCI_CLI_USER=u OCI_CLI_TENANCY=t OCI_CLI_FINGERPRINT=f \
        INSTANCE_NAME="sampleinst" SUBNET_NAME="public subnet-sample-vcn" TS_TAG="tag:sampleinst" \
        OCI_CLI_REGION=r OCI_CLI_KEY_CONTENT="PRIVATEKEYSECRET" TS_AUTHKEY="tskey-auth-SECRET123" \
        SSH_PUBLIC_KEY="ssh-rsa AAAA test" AD_OUT="zZzz:SAMPLE-REGION-1-AD-1" SUBNET_OUT="ocid1.subnet.x" \
        IMG_OUT="ocid1.image.x" IMGNAME_OUT="Canonical-Ubuntu-26.04-aarch64-sample" WAIT_SECONDS=5 \
        CRONJOB_API_KEY="cjkeySECRET" CRONJOB_JOB_ID="123456" NOTIFY_USER="owner1" \
        "$@" bash "$HERE/retry.sh" 2>&1); rc=$?
  printf '%s\n' "$out" > "$WORK/$name.out"
  if [ "$rc" = "$want" ]; then CASE_OK=1; else CASE_OK=0; echo "  exit $rc, wanted $want"; fi
}
nope() { if "$@"; then CASE_OK=0; echo "  should not have: $*"; fi; }
check() { # command...
  if "$@"; then :; else CASE_OK=0; echo "  failed check: $*"; fi
}
finish() {
  if [ "$CASE_OK" = 1 ]; then PASS=$((PASS+1)); echo "PASS $1"; else FAIL=$((FAIL+1)); echo "FAIL $1"; sed 's/^/    /' "$WORK/$1.out"; fi
}
issued()   { grep -q "gh issue create" "$LOG"; }
disabled() { grep -q "gh workflow disable" "$LOG"; }
launched() { grep -q "instance launch" "$LOG"; }
trigger_off() { grep -q 'curl .*-X PATCH.*Authorization: Bearer cjkeySECRET.*{"job":{"enabled":false}}.*https://api.cron-job.org/jobs/123456' "$LOG"; }
flat_has() { tr '\n' ' ' < "$LOG" | grep -qE "$1"; }   # match across the line breaks inside issue bodies
curl_called() { grep -q '^curl' "$LOG"; }
no_leak()  { ! grep -qE 'SECRET|PRIVATEKEY|[A-Za-z0-9+/=]{40,}' "$WORK/$1.out"; }

run_case capacity 0 LAUNCH_RC=1 LAUNCH_ERR="$CAP_ERR"
check launched; nope issued; nope disabled; check grep -q "out of capacity" "$WORK/capacity.out"; check no_leak capacity
finish capacity

run_case success 0 LAUNCH_OUT=RUNNING
check issued; check disabled; check grep -q "SUCCESS" "$WORK/success.out"
check grep -q 'tskey-auth-SECRET123' "$WORK/cloud-init.copy"
check grep -qF 'for i in $(seq 1 20)' "$WORK/cloud-init.copy"
check grep -qF -- "--advertise-tags='tag:sampleinst'" "$WORK/cloud-init.copy"
check test ! -e "$WORK/cloud-init.yaml"; check no_leak success
finish success

run_case accepted_then_terminated 0 LAUNCH_OUT=TERMINATED
nope issued; nope disabled
finish accepted_then_terminated

run_case still_starting 0 LAUNCH_RC=2 LAUNCH_ERR="Timed out waiting for resource"
check issued; check disabled
finish still_starting

run_case already_exists 0 LIST_OUT=1
check issued; check disabled; nope launched
finish already_exists

run_case empty_list_means_none 0 LIST_OUT="" LAUNCH_RC=1 LAUNCH_ERR="$CAP_ERR"
check launched
finish empty_list_means_none

run_case auth_problem 1 LIST_RC=1 LIST_ERR='ServiceError: {"code": "NotAuthenticated", "message": "The required information to complete authentication was not provided.", "status": 401}'
check issued; check disabled; nope launched
finish auth_problem

run_case rate_limited 0 LAUNCH_RC=1 LAUNCH_ERR='ServiceError: {"code": "TooManyRequests", "message": "Too many requests for the user", "status": 429}'
nope issued; nope disabled
finish rate_limited

run_case transient_500_on_lookup 0 SUBNET_RC=1 SUBNET_ERR='ServiceError: {"code": "InternalServerError", "message": "Internal error", "status": 500}'
nope issued; nope disabled; nope launched
finish transient_500_on_lookup

run_case network_blip 0 LIST_RC=1 LIST_ERR='RequestException: HTTPSConnectionPool: Max retries exceeded (Connection reset by peer)'
nope issued; nope launched
finish network_blip

run_case limit_exceeded 1 LAUNCH_RC=1 LAUNCH_ERR='ServiceError: {"code": "LimitExceeded", "message": "The following service limits were exceeded: standard-a1-core-count", "status": 400}'
check issued; check disabled
finish limit_exceeded

run_case unknown_error 0 LAUNCH_RC=1 LAUNCH_ERR='ServiceError: {"code": "Conflict", "message": "Something odd", "status": 409}'
check issued; nope disabled
finish unknown_error

run_case unknown_error_no_duplicate_issue 0 OPEN_ISSUES=1 LAUNCH_RC=1 LAUNCH_ERR='ServiceError: {"code": "Conflict", "message": "Something odd", "status": 409}'
nope issued
finish unknown_error_no_duplicate_issue

run_case image_not_found 1 IMG_OUT=""
check issued; check disabled; nope launched
finish image_not_found

run_case subnet_not_found 1 SUBNET_OUT="null"
check issued; check disabled; nope launched
finish subnet_not_found

run_case missing_secret 1 TS_AUTHKEY=""
check issued; check disabled; nope launched
finish missing_secret

run_case tailscale_key_expiring 0 TS_KEY_STOP_AFTER="2000-01-01T00:00:00Z"
check issued; check disabled; nope grep -q "^oci" "$LOG"
finish tailscale_key_expiring

run_case key_deadline_in_future 0 TS_KEY_STOP_AFTER="2099-01-01T00:00:00Z" LAUNCH_RC=1 LAUNCH_ERR="$CAP_ERR"
check launched; nope issued
finish key_deadline_in_future

LEAKY_ERR='ServiceError: {"code": "InvalidParameter", "message": "bad user_data dGhpcyBpcyBhIGxvbmcgYmFzZTY0IHN0cmluZyB0c2tleS1hdXRoLVNFQ1JFVDEyMw== tskey-auth-SECRET123", "status": 400}'
run_case no_secret_in_logs 0 LAUNCH_RC=1 LAUNCH_ERR="$LEAKY_ERR"
check no_leak no_secret_in_logs
finish no_secret_in_logs

# --- cron-job.org trigger: switched off whenever the job stops itself, never while still retrying ----------
run_case trigger_off_on_success 0 LAUNCH_OUT=RUNNING
check trigger_off; check no_leak trigger_off_on_success
finish trigger_off_on_success

run_case trigger_off_when_exists 0 LIST_OUT=1
check trigger_off
finish trigger_off_when_exists

run_case trigger_off_on_login_problem 1 LIST_RC=1 LIST_ERR='ServiceError: {"code": "NotAuthenticated", "message": "no", "status": 401}'
check trigger_off
finish trigger_off_on_login_problem

run_case trigger_off_on_key_expiry 0 TS_KEY_STOP_AFTER="2000-01-01T00:00:00Z"
check trigger_off
finish trigger_off_on_key_expiry

run_case trigger_untouched_while_retrying 0 LAUNCH_RC=1 LAUNCH_ERR="$CAP_ERR"
nope curl_called
finish trigger_untouched_while_retrying

run_case trigger_untouched_on_unknown_error 0 LAUNCH_RC=1 LAUNCH_ERR='ServiceError: {"code": "Conflict", "message": "odd", "status": 409}'
nope curl_called
finish trigger_untouched_on_unknown_error

run_case no_trigger_key_still_finishes 0 CRONJOB_API_KEY="" LAUNCH_OUT=RUNNING
nope curl_called; check issued; check disabled; check grep -q "cron-job.org" "$WORK/no_trigger_key_still_finishes.out"
finish no_trigger_key_still_finishes

run_case trigger_api_down_still_finishes 0 CURL_RC=22 LAUNCH_OUT=RUNNING
check issued; check disabled; check grep -q "could not switch the cron-job.org job off" "$WORK/trigger_api_down_still_finishes.out"
check no_leak trigger_api_down_still_finishes
finish trigger_api_down_still_finishes

# --- test mode: only switches the cron-job.org job off, touches nothing else -----------------------------
run_case test_mode_switches_trigger_off_only 0 MODE=test-trigger-off
check trigger_off; nope launched; nope issued; nope disabled; check no_leak test_mode_switches_trigger_off_only
nope grep -q "^oci" "$LOG"
finish test_mode_switches_trigger_off_only

run_case test_mode_fails_loudly_when_key_bad 1 MODE=test-trigger-off CURL_RC=22
nope launched; nope issued; check grep -q "could not switch the cron-job.org job off" "$WORK/test_mode_fails_loudly_when_key_bad.out"
finish test_mode_fails_loudly_when_key_bad

run_case test_mode_without_key_fails 1 MODE=test-trigger-off CRONJOB_API_KEY=""
nope curl_called; nope launched
finish test_mode_without_key_fails

run_case normal_mode_is_default 0 MODE="" LAUNCH_RC=1 LAUNCH_ERR="$CAP_ERR"
check launched; nope curl_called
finish normal_mode_is_default

# --- the real "created" issue mentions the owner so GitHub emails them ------------------------------------
run_case success_issue_mentions_owner 0 LAUNCH_OUT=RUNNING
check flat_has 'gh issue create .*--title Done: instance created .*@owner1'
finish success_issue_mentions_owner

# --- test mode 2: real issue + workflow off/on round trip, nothing else -------------------------------------
run_case test_success_path_mode 0 MODE=test-success-path
check grep -q 'gh issue create .*--title TEST notification' "$LOG"
check flat_has 'gh issue create .*TEST notification.*@owner1'
check grep -q 'gh workflow disable' "$LOG"; check grep -q 'gh workflow enable' "$LOG"
nope launched; nope curl_called; nope grep -q "^oci" "$LOG"
finish test_success_path_mode

run_case test_success_path_reenable_fails_loudly 1 MODE=test-success-path GH_ENABLE_RC=1
check grep -qi 'could not switch the workflow back on' "$WORK/test_success_path_reenable_fails_loudly.out"
finish test_success_path_reenable_fails_loudly

run_case test_success_path_issue_fails_loudly 1 MODE=test-success-path GH_ISSUE_RC=1
check grep -q 'gh workflow enable' "$LOG"
check grep -qi 'could not open the test issue' "$WORK/test_success_path_issue_fails_loudly.out"
finish test_success_path_issue_fails_loudly

# --- public repo: nothing identifying in issues or logs -------------------------------------------------------
visible_has() { grep -v "^::add-mask::" "$WORK/$1.out" | grep -qiE "$2"; }   # what GitHub would actually show
issues_clean() { ! grep -qiE 'sampleinst|sample-region|zZzz|subnet-|tag:|ocid1\.|[o]racle' "$LOG.issues"; }

run_case public_issue_text_generic_on_success 0 LAUNCH_OUT=RUNNING
check issued; check issues_clean
finish public_issue_text_generic_on_success

run_case public_issue_text_generic_when_exists 0 LIST_OUT=1
check issued; check issues_clean
finish public_issue_text_generic_when_exists

run_case public_issue_text_generic_subnet_missing 1 SUBNET_OUT="null"
check issued; check issues_clean
finish public_issue_text_generic_subnet_missing

run_case public_issue_text_generic_key_expiring 0 TS_KEY_STOP_AFTER="2000-01-01T00:00:00Z"
check issued; check issues_clean
finish public_issue_text_generic_key_expiring

OCID_ERR='ServiceError: {"code": "Conflict", "message": "Instance ocid1.instance.oc1.sample-region-1.anqwgljrabcdef123 is busy", "status": 409}'
run_case ocids_never_shown 0 LAUNCH_RC=1 LAUNCH_ERR="$OCID_ERR"
nope visible_has ocids_never_shown 'ocid1\.'; check issued; check issues_clean
finish ocids_never_shown

run_case zone_name_not_printed 0 LAUNCH_RC=1 LAUNCH_ERR="$CAP_ERR"
nope visible_has zone_name_not_printed 'zZzz|SAMPLE-REGION|sampleinst'
finish zone_name_not_printed

CONFIG=$'OCI_USER=ocid1.user.oc1..cfguser\nOCI_TENANCY=ocid1.tenancy.oc1..cfgten\nOCI_FINGERPRINT=aa:bb:cc\nOCI_REGION=sample-region-1\nINSTANCE_NAME=sampleinst\nSUBNET_NAME=public subnet-sample-vcn\nTS_TAG=tag:sampleinst\nCRONJOB_JOB_ID=123456\nSSH_PUBLIC_KEY=ssh-rsa AAAA cfgkey'
run_case settings_from_one_secret 0 OCI_CLI_USER= OCI_CLI_TENANCY= OCI_CLI_FINGERPRINT= OCI_CLI_REGION= INSTANCE_NAME= \
  SUBNET_NAME= TS_TAG= SSH_PUBLIC_KEY= CRONJOB_JOB_ID= RETRY_CONFIG="$CONFIG" LAUNCH_RC=1 LAUNCH_ERR="$CAP_ERR"
check launched; check grep -q -- '-c ocid1.tenancy.oc1..cfgten' "$LOG"
check grep -qF '::add-mask::ocid1.user.oc1..cfguser' "$WORK/settings_from_one_secret.out"
check grep -qF '::add-mask::ocid1.tenancy.oc1..cfgten' "$WORK/settings_from_one_secret.out"
check grep -qF '::add-mask::sampleinst' "$WORK/settings_from_one_secret.out"
check grep -qF '::add-mask::ssh-rsa AAAA cfgkey' "$WORK/settings_from_one_secret.out"
finish settings_from_one_secret

run_case settings_secret_with_windows_line_endings 0 OCI_CLI_TENANCY= RETRY_CONFIG=$'OCI_TENANCY=ocid1.tenancy.oc1..crlf\r\n' LAUNCH_RC=1 LAUNCH_ERR="$CAP_ERR"
check grep -q -- '-c ocid1.tenancy.oc1..crlf ' "$LOG"
finish settings_secret_with_windows_line_endings

run_case disables_this_workflow_file 0 LAUNCH_OUT=RUNNING
check grep -q 'gh workflow disable run.yml' "$LOG"
finish disables_this_workflow_file

echo "---- $PASS passed, $FAIL failed"
rm -rf "$WORK"
[ "$FAIL" = 0 ]

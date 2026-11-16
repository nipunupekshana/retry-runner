# retry-runner

Retries creating a cloud instance that is often "out of capacity", one try per run, until it succeeds.
An outside cron starts the `retry` workflow every few minutes; when the instance exists the job opens an issue
(the owner gets an email), switches this workflow off, and switches the outside cron off.

- `retry.sh` — one try, with every outcome handled (see its header).
- `.github/workflows/run.yml` — the workflow.
- `tests/test_retry.sh` — runs `retry.sh` against a fake CLI/GitHub/cron for each case: `bash tests/test_retry.sh`.

Nothing identifying is stored here: all settings come from the encrypted secret `RETRY_CONFIG`
(KEY=VALUE lines, masked in logs), plus the secrets `OCI_PRIVATE_KEY`, `TS_AUTHKEY` and `CRONJOB_API_KEY`.

**Stop it early:** Actions → retry → ⋯ → Disable workflow (and pause the outside cron job).
**Test without side effects:** Run workflow → mode `test-trigger-off` or `test-success-path`.

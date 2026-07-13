# V13 engine report

The Hebrew PDF is a code-backed, end-to-end audit of Engine 13. It covers the
absolute-altitude delta model, accuracy and precision, buffers, time domains and
timeouts, landing confirmation, Workout/Always On behavior, and the exact field
and unit contracts for Session JSON, KSLG replay logs, and Live reporting. The
latest one-minute cloud session remains as a worked regression example.

Build from the repository root:

```bash
node docs/v13-engine-report/prepare-data.mjs
node docs/v13-engine-report/render-pdf.mjs
```

The renderer expects Playwright at `/tmp/v13-pdf-tools`. Install it with:

```bash
npm install --prefix /tmp/v13-pdf-tools playwright@1.53.2
/tmp/v13-pdf-tools/node_modules/.bin/playwright install chromium-headless-shell
```

Primary inputs:

- `cloud_logs_20260711_latest_now/log_20260711_195534_8D524BE5.samples.csv`
- `cloud_logs_20260711_latest_now/replay_v13_final/log_20260711_195534_8D524BE5.actual.json`
- the current watchOS implementation under `Kiters/Kiters Watch App`
- the current replay implementation under `Kiters/Tools/JumpReplay`

Output: `V13_Engine_13_End_to_End_HE.pdf`.

The follow-up audit is built with:

```bash
node docs/v13-engine-report/render-pdf.mjs audit.html V13_Buffer_Filter_Rejection_Audit_HE.pdf audit-preview
```

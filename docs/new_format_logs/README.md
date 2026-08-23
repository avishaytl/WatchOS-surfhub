# new_format_logs — binary (KLOG) examples

Every log the watch sends to the server, encoded in the production binary
format (`BinaryLogEnvelope`, magic `KLOG`). Same schema/fields as before —
only the serialization is binary (no JSON, no CSV, no base64).

| file | source | content-type on wire |
|------|--------|----------------------|
| `1_diagnostic_session_log.klog` | `CloudSyncService.uploadLog` | `application/octet-stream` |
| `2_watch_ingest_start.klog`     | `WatchSessionUploader.start`  | `application/octet-stream` |
| `3_watch_ingest_ping.klog`      | `WatchSessionUploader.ping`   | `application/octet-stream` |
| `4_watch_ingest_record.klog`    | `WatchSessionUploader.record` | `application/octet-stream` |
| `5_watch_ingest_end.klog`       | `WatchSessionUploader.end`    | `application/octet-stream` |

For each `*.klog` there is a `*.decoded.json` (the bytes decoded back, proving
the schema round-trips) and a `*.hex` dump.

Regenerate:
```
swiftc "SPOTEQ/SPOTEQ Watch App/Services/BinaryLogEnvelope.swift" \
       new_format_logs/make_new_format_logs.swift -o /tmp/gen && /tmp/gen
```

## Sizes
- `1_diagnostic_session_log.klog` — 50937 bytes
- `2_watch_ingest_start.klog` — 91 bytes
- `3_watch_ingest_ping.klog` — 101 bytes
- `4_watch_ingest_record.klog` — 112 bytes
- `5_watch_ingest_end.klog` — 472 bytes

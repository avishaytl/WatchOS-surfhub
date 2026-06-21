# KLOG — Server-Side Decoder Document

How the server decodes the binary logs the Kiters watch now uploads.

The watch stopped sending JSON/CSV. Every log that reaches the server is a
**binary `KLOG` payload** (`Content-Type: application/octet-stream`). The schema
and field names are **unchanged** — only the serialization is binary, so the
edge functions need a small decoder that turns the bytes back into the same
object they used to get from `await req.json()`.

- Encoder (watch): [`BinaryLogEnvelope.swift`](../../Kiters/Kiters%20Watch%20App/Services/BinaryLogEnvelope.swift)
- Decoder (server): [`klog_decoder.ts`](./klog_decoder.ts) — ready-to-use Deno/TS module
- Live examples: every `*.klog` in [`new_format_logs/`](../) with a matching `*.decoded.json`

---

## 1. Which logs arrive in this format

| Endpoint | Source on watch | Body |
|----------|-----------------|------|
| `POST /functions/v1/watch-ingest` | `WatchSessionUploader` (`start`/`ping`/`record`/`end`) | KLOG object of the lifecycle fields |
| `POST /functions/v1/calib-log` | `CloudSyncService.uploadLog` | KLOG object whose `content` field is the raw `.kslog` file bytes |

---

## 2. Wire format

All multi-byte integers are **little-endian**.

### Container

| bytes | field | value |
|-------|-------|-------|
| 4 | magic | `"KLOG"` = `4B 4C 4F 47` |
| 1 | version | `1` |
| 1 | flags | `0` (reserved) |
| … | root value | always an **object** (tag `0x07`) |

### Value encoding — `type byte` + payload

| tag | type | payload |
|-----|------|---------|
| `0x00` | null | — |
| `0x01` | bool | `UInt8` (0/1) |
| `0x02` | int | `Int64` LE (8 bytes) |
| `0x03` | double | `Float64` IEEE-754 bits, LE (8 bytes) |
| `0x04` | string | `UInt32` len + UTF-8 bytes |
| `0x05` | blob | `UInt32` len + raw bytes (e.g. the `.kslog` file, embedded as-is — **no base64**) |
| `0x06` | array | `UInt32` count + each element value |
| `0x07` | object | `UInt32` count + repeated( `UInt16` keyLen + key UTF-8 + value ) |

Field/key order is preserved on encode; decoders rebuild a normal object/map.

> **Int precision:** all real integer fields (`sessId`, coordinates ×1e4,
> timestamps, heights in cm) sit far inside JS's safe-integer range. The decoder
> reads `Int64` via `getBigInt64` and narrows to `number`. Widen to `BigInt`
> only if you ever encode values beyond 2^53.

---

## 3. Decoder (Deno / TypeScript)

The full module is in [`klog_decoder.ts`](./klog_decoder.ts). Core entry points:

```ts
import { decodeKlog, isKlog, readPayload } from "./klog_decoder.ts";

isKlog(bytes)            // true if bytes start with the KLOG magic
decodeKlog(bytes)        // Uint8Array -> { ...sameFieldsAsBefore }
await readPayload(req)   // drop-in replacement for `await req.json()`
                         //   (accepts KLOG, falls back to JSON during rollout)
```

`readPayload` is the recommended integration point — it accepts **both** the new
binary format and legacy JSON, so old and new watch builds keep working during
the rollout:

```ts
const buf = new Uint8Array(await req.arrayBuffer());
return isKlog(buf) ? decodeKlog(buf) : JSON.parse(new TextDecoder().decode(buf));
```

---

## 4. Integration — `watch-ingest`

Replace the body read; everything downstream is identical because the field
names match the old JSON exactly.

```ts
// Before:
// const body = await req.json();

// After:
import { readPayload } from "../_shared/klog_decoder.ts";
const body = await readPayload(req);

switch (body.type) {
  case "start":  /* body.lat, body.lng, body.startedAt */            break;
  case "ping":   /* body.sessId, body.lat, body.lng, body.jmax? */   break;
  case "record": /* body.sessId, body.jumpM?, body.airS?, …      */  break;
  case "end":    /* body.sessId, body.durMin, body.track[[…]], body.jData[{…}] */ break;
}
```

Decoded `end` example (from [`5_watch_ingest_end.klog`](../5_watch_ingest_end.klog)):

```json
{
  "type": "end", "sessId": 8842, "durMin": 47, "jmax": 3.5, "jcnt": 2,
  "airS": 1.9, "spdKmh": 38, "distKm": 12.4, "stars": 4,
  "windKts": 18, "dir": "NW", "avgKmh": 24.6,
  "track": [[328354, 349671], [328369, 349653], [328380, 349640]],
  "jData": [
    { "t": 8, "h": 130, "a": 14, "s": 34, "d": 12, "y": 328354, "x": 349671 },
    { "t": 16, "h": 350, "a": 19, "s": 41, "d": 18, "y": 328369, "x": 349653 }
  ]
}
```

---

## 5. Integration — `calib-log`

The `content` field comes back as a **`Uint8Array`** holding the raw `.kslog`
bytes — write it straight to storage, no base64 decode needed.

```ts
import { readPayload } from "../_shared/klog_decoder.ts";

const log = await readPayload(req);
// log.type === "session_log"
// log.filename, log.contentType, log.contentEncoding === "binary"
// log.appVersion, log.build, log.uploadedAt
// log.content : Uint8Array  (the raw .kslog file)

const device  = new URL(req.url).searchParams.get("device") ?? "watch";
const path    = `logs/${device}/${log.filename}`;
await supabase.storage.from("session-logs").upload(path, log.content as Uint8Array, {
  contentType: log.contentType as string,
  upsert: true,
});

return new Response(JSON.stringify({ ok: true, status: "uploaded", path }), {
  headers: { "content-type": "application/json" },
});
```

---

## 6. Verifying

The committed examples are produced by the real Swift encoder and decode cleanly
with this module (Swift encode → TS decode round-trip):

```bash
# regenerate the binary examples from the production codec
swiftc "Kiters/Kiters Watch App/Services/BinaryLogEnvelope.swift" \
       new_format_logs/make_new_format_logs.swift -o /tmp/gen && /tmp/gen

# decode them back with this server module (Deno)
deno eval '
  import { decodeKlog } from "./new_format_logs/server/klog_decoder.ts";
  const b = new Uint8Array(Deno.readFileSync("./new_format_logs/5_watch_ingest_end.klog"));
  console.log(decodeKlog(b));
'
```

Each `*.klog` has a sibling `*.decoded.json` showing the expected decoded shape.

---

## 7. Rollout checklist

1. Deploy `klog_decoder.ts` to both functions (e.g. `supabase/functions/_shared/`).
2. Swap `await req.json()` → `await readPayload(req)` in `watch-ingest` and `calib-log`.
3. In `calib-log`, store `content` as raw bytes (drop the old base64 decode).
4. Keep the JSON fallback in `readPayload` until every watch is on the binary build.
5. Once telemetry shows no JSON bodies, remove the fallback to make the format mandatory.

# `calib-log` — exactly what the server has to change

The watch side is done and shipped in `CloudSyncService.swift`. This is the
matching server work. The Edge Function source is not in this repo and not on
the machine this was written on, so nothing here is applied — it is a spec.

Until it lands, a new watch build cannot upload at all: it sends a gzipped body
that the current function will not understand. Uploads fail closed (the log
stays on the watch and retries), but they do not land.

---

## Change 1 — accept a gzipped request body

**Where:** the POST handler, between reading the body and calling `isKlog()`.

**Rule:** if the request carries `Content-Encoding: gzip`, gunzip the body and
continue with the decompressed bytes. Everything downstream — `isKlog`, the
parse, the storage write — sees exactly the bytes it sees today.

Three things this must get right:

1. **Absence of the header is the untouched path.** Older watch builds, and any
   new build whose compression did not pay off, send no `Content-Encoding` and
   a plain body. That case must behave bit-for-bit as it does now.
2. **A failed gunzip is not an error.** If the body does not decode, treat it as
   already-plain and carry on. Some gateways decompress request bodies
   themselves and leave the header in place; whether Supabase's does was not
   verified, and this makes the answer not matter.
3. **Decompression must be BOUNDED.** `await new Response(stream).arrayBuffer()`
   materialises the whole thing before you can measure it, so a 1 MB body can
   become gigabytes before any check runs. Read the stream in chunks with a
   running total and abort the moment it passes the ceiling.

```ts
class TooLarge extends Error {}

async function gunzipBounded(raw: Uint8Array, limit: number): Promise<Uint8Array> {
  const reader = new Blob([raw]).stream()
    .pipeThrough(new DecompressionStream("gzip"))
    .getReader();

  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > limit) {                 // abort BEFORE buffering more
      await reader.cancel();
      throw new TooLarge();
    }
    chunks.push(value);
  }

  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { out.set(chunk, offset); offset += chunk.byteLength; }
  return out;
}
```

```ts
// in the handler, replacing today's single body read:
let raw = new Uint8Array(await req.arrayBuffer());

if (raw.byteLength > MAX_COMPRESSED_BYTES) return tooLargeResponse();

if (req.headers.get("content-encoding")?.toLowerCase() === "gzip") {
  try {
    raw = await gunzipBounded(raw, MAX_UPLOAD_BYTES);
  } catch (err) {
    if (err instanceof TooLarge) return tooLargeResponse();
    // not gzip after all — already decompressed upstream. Keep `raw` as is.
  }
}

if (raw.byteLength > MAX_UPLOAD_BYTES) return tooLargeResponse();

// unchanged from here: isKlog(raw) → parse → store.
```

Note the `TooLarge` rethrow. Without it a zip bomb is silently swallowed by the
same `catch` that handles "this wasn't gzip", and the ceiling stops working.

`DecompressionStream("gzip")` is built into Deno. No dependency is added.

## Change 2 — raise the size ceilings

`MAX_UPLOAD_BYTES` is 20 MB (per your reading, at `calib-log/index.ts:69` and
`:194` — I could not verify the line numbers, the source is not here). A 22 MB
log exceeds it, and the KLOG envelope is slightly larger again, so even a
completed upload came back `413`.

Two constants, not one, because they now measure different things:

| constant | value | applies to |
|---|---|---|
| `MAX_COMPRESSED_BYTES` | 16 MB | the body as received — a cheap early rejection |
| `MAX_UPLOAD_BYTES` | 64 MB | the body after gunzip — the real ceiling |

64 MB gives roughly 3x headroom over today's largest log. 16 MB on the wire is
about 80–160 MB of log at the measured 5–10x ratio, so it constrains nothing
real while capping what a bomb can even attempt.

If Supabase enforces its own request-body limit below these numbers, that limit
wins and this is moot for the compressed side — worth confirming, I could not.

## Change 3 — nothing else

Stated explicitly because these are the ways this goes wrong quietly:

- **Store the DECOMPRESSED bytes.** The artifact in the bucket must stay a raw
  `.kslog`, byte-identical to what an uncompressed upload produces. `?path=`
  keeps returning it verbatim; every analysis tool downstream is unaware any of
  this happened.
- **Do not touch the response shape.** The watch decodes `{id, status, message,
  ok, path}` and persists `path` into `cloudLastLogPath` for the fetch-back
  path. Any non-2xx is thrown as `serverStatus` and retried later.
- **Do not read the envelope's `contentEncoding` field for this.** It still says
  `binary` and describes the INNER log bytes. The gzip is transport-level and
  lives only in the HTTP header. Confusing the two will reject valid uploads.
- **CORS**, only if a browser ever posts here: `Content-Encoding` has to be in
  `Access-Control-Allow-Headers`. The watch sends no preflight, so this is not
  on the critical path.

---

## What the watch sends, precisely

```
POST /functions/v1/calib-log?device=<id>&session=<name>
X-Calib-Token: <token>
Content-Type: application/octet-stream
Content-Encoding: gzip          ← only when the body is actually gzipped
<gzipped KLOG envelope>
```

The body is RFC 1952 with a real header and CRC/ISIZE trailer — verified with
`gzip -t`, a byte-identical round trip, and Python's `gzip.decompress`, which
checks both. Measured 4.8x on log-shaped data, so a 22 MB log leaves as ~4.5 MB.

## Acceptance

1. Same log twice — once plain, once gzipped. Both return 2xx, and the two
   stored objects are byte-identical. This is the test that matters.
2. An old-build upload (no `Content-Encoding`) still succeeds.
3. A body with `Content-Encoding: gzip` that is NOT gzip is accepted if it is
   valid KLOG (the gateway-already-decompressed case).
4. A gzip body that expands past `MAX_UPLOAD_BYTES` returns 413 and does not
   exhaust memory.
5. Fetch back via `?path=` and diff against the original `.kslog`.

```
gzip -c some_session.klog > body.gz
curl -i -X POST "$BASE/functions/v1/calib-log?device=watch&session=test" \
  -H "X-Calib-Token: $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  -H "Content-Encoding: gzip" \
  --data-binary @body.gz
```

## Rollout order

Server first, or both together. A new watch against an un-patched server fails
every upload; an old watch against a patched server is unaffected.

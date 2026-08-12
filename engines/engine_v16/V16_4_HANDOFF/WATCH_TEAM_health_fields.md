# For the watch team — add `calories` + `maxHr` to the `end` message

We want to show two health numbers on the **session detail page** in the phone
app: **calories burned** and **max heart rate**. Both come from the watch's own
workout session, so please add them to the **`end`** lifecycle upload.

> This is the **session upload** (`watch-ingest`, the `end` message that carries
> the jump metrics + `jData` + `track`). It is **not** the diagnostic
> `calib-log` / KLOG sensor-log upload — that one is unchanged.

## What to add — two new fields on `end`

The `end` message is the same KLOG-encoded object you already send. Add two
**optional** top-level fields next to `jmax` / `airS` / `spdKmh`:

| field      | meaning                                   | unit the app stores | type |
|------------|-------------------------------------------|---------------------|------|
| `calories` | active energy burned over the session     | **kcal** (int)      | number |
| `maxHr`    | peak heart rate seen during the session   | **bpm** (int)       | number |

- Send **whole integers** (round on the watch): `calories: 412`, `maxHr: 168`.
- **camelCase**, exactly `calories` and `maxHr` — same casing convention as
  `airS` / `spdKmh` / `distKm`.
- These are **active** calories (the workout's active energy), not total/resting.
- `maxHr` is the **session maximum** heart rate, not the average.

### Desired shape (only the two new fields shown)

```jsonc
{
  "type": "end",
  "sessId": 123,
  "durMin": 96,
  "jmax": 4.3, "jcnt": 21, "airS": 2.4, "spdKmh": 41, "distKm": 18.2,
  "windKts": 22, "dir": "NW", "stars": 4,
  "calories": 412,     // ← new — kcal, int
  "maxHr": 168,        // ← new — bpm, int
  "track": [ /* … */ ],
  "jData": [ /* … */ ]
}
```

## If a value isn't available

Both are **optional** — omit the field, or send `0`. The server treats a
missing / non-positive / non-finite value as "not reported" and stores `NULL`,
and the app renders a dash (`—`) for it. So:

- No HR sensor / HR permission denied → omit `maxHr` (or send `0`).
- Energy not tracked → omit `calories` (or send `0`).

Don't send placeholder/fake numbers — a real `0` and an omitted field are both
handled, but a made-up value would show as a real reading.

## Server + app — already done on our side ✅

- `watch-ingest` reads `calories` / `maxHr` on `end`, sanitises them to positive
  ints (else `NULL`), and writes `sessions.calories` / `sessions.max_hr`.
- DB columns added (migration `20260808000000_sessions_calories_max_hr.sql`),
  both nullable.
- The phone's session detail page now shows **Calories** and **Max HR** in place
  of the old wind-speed / wind-direction tiles. `windKts` / `dir` are still
  stored and still used elsewhere (share card, coach) — **keep sending them.**

Nothing else changes: magic, tags, `start` / `ping` / `record`, `track`, and
`jData` are all unchanged. Once `end` carries `calories` + `maxHr`, the two tiles
light up automatically for every new session.

# V16.7 Integration Notes

## Production source

The watch app and the Swift package both compile the production source at
`engines/engine_v16/JumpEngineV16.swift`. The `V16_7_HANDOFF` directory is an
unaltered research handoff and is excluded from the package target.

Do not copy the handoff Swift file over the production file. The snapshot does
not type-check as supplied (`plateau`/`f2` are stale aliases and `G0` is out of
scope), and it does not contain production-only jump diagnostics and arc fields.

## Shipped operating point

- Engine banner: `16.7`
- Height pre-roll: `0.5 s`
- Conditional post-roll: `0.8 s`
- Post-roll gates: airtime `>= 4.0 s` or first-pass height `>= 3.5 m`
- Requested height-window floor: `5.0 s`
- Reference calibration: `1.0 * h + 0.0 m`
- Free-fall windows remain exempt from post-roll extension.
- At the `7.5 s` evaluation deadline, the engine uses the tail available in the
  ring instead of waiting indefinitely.

## Validation completed for this release

- `swift test --package-path engines/engine_v16`: 39 tests passed.
- Native Release replay matched the supplied TypeScript twin for all 37
  emissions in the four locally runnable sessions (SMALL, 287, NEG and CLEAN):
  zero height or airtime delta and maximum takeoff-time delta below `0.3 us`.
- Generic iOS Release build and signed archive succeeded with the embedded
  watchOS app at version `1.3` build `167`.
- The live `watch-ingest` path was checked against recent production rows: it
  preserves present V16 optional fields and leaves missing fields absent rather
  than normalizing them to zero.

## Remaining field/research checks

- The packaged reference CLI omits GAVRI and KINERET and several source logs are
  absent, so the complete nine-session report cannot be independently replayed
  from this checkout.
- Native `JumpReplay` currently drops KSLG2 GPS coordinates, so distance parity
  is not covered by the native comparison.
- Confirm non-empty continuous absolute-altitude diagnostics and investigate the
  observed relative-altimeter cadence on a physical watch. Absolute altitude is
  diagnostic-only for V16 height.

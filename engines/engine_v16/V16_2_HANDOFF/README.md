# V16.2 handoff

Read `00_INSTRUCTIONS.md` first — it is the complete change list with the
measurement behind each decision.

```
00_INSTRUCTIONS.md     what to change, why, and how to verify
01_ENGINE/             the two Swift files to copy over
02_PATCHES/            Session.swift edits
03_DOCS/               findings and rejected experiments
04_REFERENCE/          TS twin, the verification CLI, the golden reference
```

Headline: recall 31/39 -> 36/39, phantoms 9 -> 8, tallest phantom 3.73 m ->
2.54 m, pooled height MAE 0.575 m -> 0.300 m, and bench throws detected for the
first time (0/4 -> 3/4). Airtime regressed 0.34 s -> 0.46 s and that was
accepted.

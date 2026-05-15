# archive/

Reference apps that aren't on the active build path right now — parked
here while the umbrella organisation around them firms up. Nothing here
is dead code; each one still builds against `bithuman-sdk-public`
(legacy bitHumanKit SwiftPM) and ships features that may not yet exist
in their canonical replacement.

## What's here

- [`iPhone/`](iPhone/) — iOS Expression demo. Portrait-locked, smaller
  LLM (Gemma 3 1B QAT 4-bit) sized to the iOS memory budget. Parked
  because the iPhone 16 Pro 8 GB memory ceiling is too tight to host
  the full Expression stack alongside a usable LLM. Phase 2 work — a
  leaner on-device LLM track or a cloud LLM/TTS path for iPhone — will
  unblock revival.

The Mac and iPad Expression demos that previously lived here were
promoted to [`../expression/mac/`](../expression/mac/) and
[`../expression/ipad/`](../expression/ipad/). To revive iPhone the
same way once the compute story improves:

```sh
git mv archive/iPhone expression/iphone
```

then refresh its `bithuman-sdk-public` SwiftPM pin (currently `0.8.1`,
governed by [`../version.yml`](../version.yml)) to resolve against the
latest tag.

## When something else lands here

- A reference app that's *being decommissioned*: move it here, write a
  one-liner under "What's here" pointing at the rationale + any
  successor.
- A reference app *waiting for a successor* (this iPhone case): same —
  and link to the umbrella that the successor will live under.

## When something leaves here

It either gets revived (back to its umbrella; e.g. `expression/`) or
fully retired (deleted, with a CHANGELOG note in the repo root if the
removal is user-visible).

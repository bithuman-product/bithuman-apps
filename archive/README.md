# archive/

Reference apps that aren't on the active build path right now — parked
here while the umbrella organisation around them firms up. Nothing here
is dead code; each one still builds against `bithuman-sdk-public`
(legacy bitHumanKit SwiftPM) and ships features that may not yet exist
in their canonical replacement.

## What's here

- [`iPad/`](iPad/) — iPadOS Expression demo. Stage-Manager floating
  widget, draggable Picture-in-Picture, PhotosPicker face swap. Targets
  M4+ iPad Pro with `increased-memory-limit` entitlement.
- [`iPhone/`](iPhone/) — iOS Expression demo. Portrait-locked, smaller
  LLM (Gemma 3 1B QAT 4-bit) sized to the iOS memory budget.

The macOS Expression demo that previously lived here has been promoted
to [`../expression/mac/`](../expression/mac/) as the canonical Expression
reference. The iPad and iPhone variants follow the same scope; revive
either with:

```sh
git mv archive/iPad   expression/ipad
git mv archive/iPhone expression/iphone
```

after which their `bithuman-sdk-public` SwiftPM pin (currently `0.8.1`,
governed by [`../version.yml`](../version.yml)) needs a refresh to
resolve against the latest tag.

## When something else lands here

- A reference app that's *being decommissioned*: move it here, write a
  one-liner under "What's here" pointing at the rationale + any
  successor.
- A reference app *waiting for a successor* (this iPad/iPhone case):
  same — and link to the umbrella that the successor will live under.

## When something leaves here

It either gets revived (back to its umbrella; e.g. `expression/`) or
fully retired (deleted, with a CHANGELOG note in the repo root if the
removal is user-visible).

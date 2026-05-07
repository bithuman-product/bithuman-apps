# demos/

Demo and showcase apps built on the bitHuman SDK. Each demo is a self-contained project that consumes the SDK as an external dependency -- Swift apps pull `bitHumanKit` via the public SwiftPM binary package; Python apps install `bithuman` via pip. No SDK source code is vendored here; demos exercise the real published artifacts so they mirror the actual developer experience.

## Adding a new demo

1. Create a subdirectory under `demos/` named after the demo (e.g. `demos/kiosk/`).
2. Add the appropriate dependency manifest:
   - **Swift**: a `Package.swift` that declares `.package(url: "https://github.com/bithuman-product/bithuman-sdk-public.git", from: "0.8.1")`.
   - **Python**: a `requirements.txt` that includes `bithuman>=1.7.8`.
3. Add a `README.md` in the subdirectory explaining what the demo does, how to build/run it, and any hardware or credential requirements.
4. Keep the demo minimal -- focus on one use case and lean on the SDK for heavy lifting.

## Planned demos

| Demo | Description | Status |
|------|-------------|--------|
| `kiosk/` | Museum/lobby kiosk -- always-on avatar session, no idle timeout, full-screen display | Planned |
| `receptionist/` | Front-desk greeter with calendar lookup and visitor check-in via function calling | Planned |
| `tutor/` | Educational tutor that walks a student through a lesson plan with follow-up questions | Planned |
| `npc/` | Game NPC with persona constraints, short-term memory, and emotion-driven expressions | Planned |

Each demo will include build instructions and a short video or screenshot of the running app.

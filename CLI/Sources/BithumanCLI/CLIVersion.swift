// Build-stamped version string surfaced via `bithuman-cli --version`.
//
// The committed value is always `0.0.0-dev` so unreleased local builds
// answer truthfully. `release.sh` rewrites this constant to the
// release tag (e.g. `0.19.3`) immediately before the xcodebuild step
// and `git checkout`s it back afterwards, so:
//
//   - `swift build` from a clean tree → `0.0.0-dev`
//   - `release.sh 0.19.3` → binary stamped `0.19.3`, source tree
//     restored to `0.0.0-dev` after the build completes
//
// If you ever need to override at dev time (e.g. to test the
// formatting), edit this file directly — just don't commit the bump.

let cliVersion = "0.0.0-dev"

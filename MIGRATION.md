# Migration — staging this directory into github.com/bithuman-product/bithuman-apps

Maintainer doc. Not for external developers.

This directory was generated from `swift-voice-chat/Apps/Bithuman{Mac,Pad,Phone}/`
as a snapshot. The dev repo (`swift-voice-chat`) keeps its
`Apps/Bithuman*/` tree as the source of truth — edits there are
periodically re-snapshot-ed into this directory and pushed to the
public `bithuman-apps` repo.

## Pre-flight — what must be true before the first public commit

1. **`bithuman-kit` v0.1.0 must be tagged and public.** The Mac
   `Package.swift` and the iPad/iPhone `App/project.yml` files all
   declare `from: "0.7.1"` against
   `https://github.com/bithuman-product/bithuman-kit.git`. If that tag
   doesn't exist, every fresh clone breaks at `swift package resolve`.
   Verify:
   ```sh
   git ls-remote https://github.com/bithuman-product/bithuman-kit.git refs/tags/0.1.0
   ```
   should print a non-empty SHA.

2. **No private model URLs leak in source.** Grep for
   `huggingface.co/bithuman-private` and any internal-only repo
   slugs before pushing:
   ```sh
   grep -RIE 'bithuman-(private|internal|dev)' .
   ```

3. **`DEVELOPMENT_TEAM: G64NFNZX84`** (bitHuman Inc.) is hardcoded in
   the iPad/iPhone `project.yml` files. External devs cloning the
   repo will need to swap this to their own team. Either:
   - leave it as-is and document the override in the per-app
     READMEs (current state — keeps the bitHuman-internal release
     pipeline working), or
   - replace with `$(DEVELOPMENT_TEAM)` and require it as an env var.

4. **Bundle IDs** (`ai.bithuman.app.ipad`, `ai.bithuman.app.ios`) are
   bitHuman-owned. External devs must change these. Same trade-off
   as the team-id question above.

5. **App icons in `Assets.xcassets`** are bitHuman-branded. Decide
   whether to ship them (so the reference build looks good out of
   the box) or strip them (so external apps can't accidentally
   submit a clone with our branding).

## Push to the new repo

From this directory (`release-staging/bithuman-apps/`):

```sh
# Initialise + first commit
git init
git checkout -b main
git add .
git commit -m "Initial public release of bitHuman reference apps"

# Wire to the new GitHub repo (must already exist; create it from
# https://github.com/organizations/bithuman-product/repositories/new
# with NO README / .gitignore / license — we ship our own).
git remote add origin git@github.com:bithuman-product/bithuman-apps.git
git push -u origin main

# Tag matching the SDK release for clarity:
git tag -a v0.1.0 -m "Tracks bithuman-kit 0.1.0"
git push origin v0.1.0
```

## Known gotchas

### 1. xcodegen regeneration is required after clone

The iPad/iPhone `App/` directories deliberately do NOT contain a
`.xcodeproj` — it's generated from `project.yml` on demand. Anyone
cloning has to run `xcodegen generate` once before opening Xcode.
This is in each per-app README, but worth flagging in the top-level
release notes too.

### 2. Generated/Info.plist is ignored

xcodegen writes `App/Generated/Info.plist` from the YAML. Add
`App/Generated/` to `.gitignore` (along with `App/*.xcodeproj/`)
before the first commit, otherwise contributor PRs will churn.

Suggested `.gitignore` additions:

```
# Xcode / xcodegen
**/App/Generated/
**/App/*.xcodeproj/
.build/
.swiftpm/
xcuserdata/
DerivedData/

# Build outputs
dist/
*.dmg
*.ipa
*.xcarchive
```

### 3. Code-sign identity drift

The iPad/iPhone `project.yml` files set
`CODE_SIGN_IDENTITY: "Apple Development"` so simulator + on-device
debug builds work without a distribution cert. The release scripts
(`Scripts/build-{ipad,iphone}-app.sh`) override this at archive-time
via `xcodebuild -allowProvisioningUpdates` (Apple Distribution).

External devs without the bitHuman team-id will see signing failures
unless they edit `project.yml`. README each app explains the swap;
make sure that text doesn't get stripped during snapshot updates.

### 4. Sparkle keys are NOT shipped

`Mac/Resources/Info.plist` references `SUFeedURL` + `SUPublicEDKey`
placeholders. The actual EdDSA keys live ONLY on the bitHuman release
machine (`~/.bithuman-sparkle/`). External devs running
`swift run BithumanMac` get the binary; only the official build
pipeline produces a Sparkle-updateable .app.

This is intentional: we don't want forks to accidentally inherit our
update channel. Document this in the Mac README under "shipping your
own builds" if forks become a concern.

### 5. Resources/ duplicates App/ entitlements

The iPad/iPhone trees have BOTH:
- `App/<App>.entitlements` — used by xcodebuild via the
  `CODE_SIGN_ENTITLEMENTS` setting in `project.yml`.
- `Resources/<App>.entitlements` — used by the SPM smoke build, which
  pulls them in via `resources: [.copy(...)]`.

These are intentionally byte-identical. If you edit one, edit the
other. A future cleanup PR could symlink them, but symlinks survive
poorly through `git archive` / GitHub's tarball download path so the
duplication is the safer choice.

### 6. The MacOSStub.swift files are required

`Apps/BithumanPad/Sources/MacOSStub.swift` and the equivalent in
BithumanPhone exist because `swift build` on a Mac host (without an
iOS triple) treats those targets as macOS executables. Without the
stub `@main`, `swift build` fails with "no main found". Don't delete
them, even though they look pointless.

## Re-snapshot from the dev repo

When the dev repo's `Apps/Bithuman*/` trees evolve and you want to
roll those changes into this public repo:

```sh
# From the dev repo's working copy:
DEV=~/bithuman/swift-voice-chat
PUB=~/path/to/bithuman-apps    # checkout of the public repo

for variant in Mac Pad Phone; do
  case "$variant" in
    Mac)   dst="Mac"   ;;
    Pad)   dst="iPad"  ;;
    Phone) dst="iPhone";;
  esac

  # Sync (delete-then-copy keeps removed files from sticking):
  rm -rf "$PUB/$dst/Sources" "$PUB/$dst/Resources" \
         "$PUB/$dst/Scripts" "$PUB/$dst/docs"
  cp -R "$DEV/Apps/Bithuman$variant/Sources"   "$PUB/$dst/Sources"
  cp -R "$DEV/Apps/Bithuman$variant/Resources" "$PUB/$dst/Resources"
  cp -R "$DEV/Apps/Bithuman$variant/Scripts"   "$PUB/$dst/Scripts"
  cp -R "$DEV/Apps/Bithuman$variant/docs"      "$PUB/$dst/docs"
done

# iPad / iPhone also have App/ scaffolds:
for variant in Pad Phone; do
  case "$variant" in
    Pad)   dst="iPad"  ;;
    Phone) dst="iPhone";;
  esac
  rm -rf "$PUB/$dst/App"
  cp -R "$DEV/Apps/Bithuman$variant/App" "$PUB/$dst/App"
  rm -rf "$PUB/$dst/App/Bithuman$variant.xcodeproj" \
         "$PUB/$dst/App/Generated"
  # CRITICAL: re-apply the local-path -> remote-URL fix in project.yml.
  # See sed snippet below or just diff against the previous version.
done
```

After the cp pass, **the project.yml files still contain
`path: ../../..`** (the dev repo uses local-path SPM). Either:
- maintain a small patch file under `release-staging/patches/` and
  apply it with `git apply` after copying, or
- run a one-shot sed replace:

```sh
for f in $PUB/iPad/App/project.yml $PUB/iPhone/App/project.yml; do
  python3 - <<PY
import re, sys
p = "$f"
s = open(p).read()
s = re.sub(
    r"packages:\s*\n  bithuman-kit:\s*\n    path: \.\.\/\.\.\/\.\.",
    "packages:\n  bithuman-kit:\n    url: https://github.com/bithuman-product/bithuman-kit.git\n    from: 0.1.0",
    s,
)
open(p, "w").write(s)
PY
done
```

Either workflow keeps the `local-path -> remote-URL` swap from being
the step that gets forgotten. Worth automating before the second
re-snapshot.

# Sparkle auto-update — first-time setup

Once the BithumanMac target is wired up (see `PACKAGE_INTEGRATION.md`),
`bitHuman.app` ships an embedded `Sparkle.framework`. For Sparkle to
actually work, three things have to be true:

1. The .app's `Info.plist` carries a real `SUFeedURL` (the appcast)
   and `SUPublicEDKey` (an EdDSA verification key).
2. There's a public HTTPS host for `appcast.xml` and the DMG.
3. Each release zips/dmgs the .app, EdDSA-signs the artefact, and
   adds an entry to `appcast.xml` whose `sparkle:edSignature`
   attribute matches.

This doc walks through (1) and (2). Step (3) — generating an
appcast.xml entry per release — is the next thing to script, but
isn't required for the very first manual DMG drop.

## 1. Generate the EdDSA key pair (one-time, never repeat)

Sparkle ships a tool called `generate_keys` inside the framework.
After `swift package resolve` pulls Sparkle, you can find it at:

```
~/Library/Developer/Xcode/DerivedData/<bithuman-kit-…>/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```

If you can't find it, the alternative is to download Sparkle's
release zip from <https://sparkle-project.org/> — `bin/generate_keys`
is in there.

Run it once on a trusted machine:

```sh
mkdir -p ~/.bithuman-sparkle
cd ~/.bithuman-sparkle
generate_keys
```

This writes:

- `~/.bithuman-sparkle/<base64>.priv` — the EdDSA private key. **Never
  commit this. Never email it. Back it up to a password manager.**
  If this leaks, anyone can ship a fake "update" to every existing
  user. Rotating the key requires shipping a new release with the
  new public key embedded, so a leak is *catastrophic* — treat it
  like a code-signing key.
- The same tool prints the matching public key to stdout. Save it:

```sh
generate_keys -p > ~/.bithuman-sparkle/public.pem
```

## 2. Wire the keys into the build

`build-mac-app.sh` reads two environment variables and substitutes
them into `Info.plist` at packaging time:

```sh
export SU_FEED_URL="https://updates.bithuman.ai/mac/appcast.xml"
export SU_PUBLIC_ED_KEY="$(cat ~/.bithuman-sparkle/public.pem)"
./expression/mac/Scripts/build-mac-app.sh 0.1.0
```

The placeholder tokens (`__SU_FEED_URL__`, `__SU_PUBLIC_ED_KEY__`) in
`Resources/Info.plist` are intentionally syntactically-valid strings,
so a build that *forgets* to set the env vars still produces a
runnable .app — Sparkle just sees a bogus feed URL and never finds an
update. Production releases MUST set both.

## 3. Host the appcast feed

Pick any HTTPS host you control. The simplest options:

- **GitHub Pages** on `bithuman-product/homebrew-bithuman` — same
  repo as the existing tap. Add an `mac/appcast.xml` + `mac/dmg/`
  directory; Pages serves them at
  `https://bithuman-product.github.io/homebrew-bithuman/mac/`.
- **A dedicated S3 + CloudFront** at `updates.bithuman.ai`. Cleaner
  for product purposes (no `homebrew-bithuman` URL on the
  user-facing About box), but requires DNS + cert setup.

Once chosen, set `SUFeedURL` (via the env var) to the absolute URL of
the appcast XML.

## 4. Appcast entry shape (per release)

Sparkle expects an RSS feed. Minimal entry:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/"
     version="2.0">
  <channel>
    <title>bitHuman</title>
    <item>
      <title>0.1.0</title>
      <pubDate>Sat, 26 Apr 2026 12:00:00 +0000</pubDate>
      <sparkle:version>202604261200</sparkle:version>          <!-- CFBundleVersion -->
      <sparkle:shortVersionString>0.1.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://updates.bithuman.ai/mac/dmg/bitHuman-0.1.0.dmg"
        sparkle:edSignature="<base64-edsig-from-sign_update>"
        length="<bytes>"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
```

The `sparkle:edSignature` value comes from another Sparkle helper,
`sign_update`, which lives next to `generate_keys`:

```sh
sign_update dist/bitHuman-0.1.0.dmg ~/.bithuman-sparkle/<base64>.priv
```

## 5. Where this is automated next

The first DMG is fine to upload by hand. Once you're shipping more
than once a quarter, automate it:

1. `release-mac.sh` calls `build-mac-app.sh`, then runs `sign_update`
   on the resulting DMG.
2. Append a new `<item>` to `appcast.xml` with the version + EdSig.
3. Push the DMG and updated `appcast.xml` to the chosen host
   (probably extending `publish.sh` to handle the Mac feed alongside
   the existing Homebrew tap).

That's deliberately out of scope for this scaffolding pass — get one
DMG out the door first, validate Sparkle finds it on a fresh-install
Mac, then automate.

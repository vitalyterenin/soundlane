# SoundLane release operations

Use the refreshed [app-release skill](https://github.com/vitalyterenin/app-release-kit/blob/main/skills/app-release/SKILL.md) and its publishing, documentation and licensing rules. SoundLane supports macOS 14.2+ on Apple Silicon.

## Identity and ownership

`release.json` owns version/build, repository, permanent URLs, update public key, approved license, first-release build and certificate SHA-256. The bundle ID is `in.teren.SoundLane`; the virtual device UID is `in.teren.soundlane.microphone` and its HAL bundle ID is `in.teren.SoundLane.Driver`. Do not change these by inference.

- Source: https://github.com/vitalyterenin/soundlane
- Current DMG: https://github.com/vitalyterenin/soundlane/releases/latest/download/SoundLane.dmg
- Signed feed: https://vitalyterenin.github.io/soundlane/appcast.xml

The owner approved a public repository while reserving all rights to original SoundLane code. This is not an MIT-licensed project. LICENSE contains the approved proprietary notice. Complete dependency notices are in THIRD_PARTY_NOTICES.md, including libASPL's Apple-derived code and Sparkle. The release tooling retains its upstream MIT notice.

Releases use a distinct persistent self-signed **SoundLane Release** certificate pinned by `Resources/ReleaseSigning.cer`. It is separate from the dedicated Sparkle Ed25519 account `in.teren.SoundLane`. Private certificate/update material is outside source with a protected owner backup and encrypted repository Secrets: `SOUNDLANE_SIGNING_P12`, `SOUNDLANE_SIGNING_PASSWORD`, `SPARKLE_PRIVATE_KEY`. Never log them, copy another app's identity, regenerate keys during builds, add root trust, or fall back to ad hoc release signing.

## Distribution and updates

There is one current `SoundLane.dmg` for manual drag installation and Sparkle updates. The app contains its separately versioned HAL component and one-time component installer. Ordinary updates replace the app bundle only. They do not install or restart the system HAL component. Component version changes require their own authorized setup and a restart.

Development versions 0.2 and earlier used ad hoc identities and whole-app PKGs. The first permanent-identity app is a one-time migration; old hash-bound privacy grants cannot be promised to transfer. A legacy root-owned app can need administrator authorization once for replacement. Check ownership on the migrated app and test a real Sparkle update to another executable before claiming permission continuity. Do not overwrite the migrated app with a development signature.

The code signing gate verifies the app, HAL bundle and all updater helpers against the exact certificate and certificate-bound designated requirements. The HAL is signed before packaging its installer. App/driver notices are copied before signing; the DMG carries the same source notices. Packaging mounts the finished image read-only and checks signatures and notices.

## Checks and documentation gate

From the repository root:

```sh
python3 scripts/release.py validate
bash scripts/test.sh
bash scripts/test-stability.sh
python3 -m unittest discover -s Tests/Release -v
bash scripts/build-app.sh
```

Local ad hoc builds support development only. They do not qualify for packaging and must not be published. Review every maintained document: README, AGENTS, LICENSE, THIRD_PARTY_NOTICES, docs/usage, privacy, development, architecture, design, validation, and this guide. Check current code/settings, examples, internal/external links and screenshot rendering. Record the whole-app review scope and corrections in the PR before tagging. Upstream vendored documentation is retained as dependency material and is not the current app guide.

## Publish

1. Refresh the shared skill and inspect current public state.
2. Increase the three-part version and positive build in release.json; a build must exceed every published build.
3. Complete code, tests, license checks, documentation and repository About review.
4. Push a branch, wait for checks, and merge its exact checked revision normally.
5. Push a fresh matching `v<version>` tag on that checked commit.
6. Wait for both **build** and **publish** jobs in **Release SoundLane**.
7. Download the public DMG and feed and verify exact bytes/hashes, Ed25519 signatures, metadata, arm64 executables, persistent signer, project license and dependency notices inside the DMG and app.
8. Only after feed/download convergence remove older DMG assets; preserve tags, release records and unrelated assets.

```sh
python3 scripts/release.py validate
release_tag="$(python3 -c 'import json; print("v" + json.load(open("release.json"))["version"])')"
git tag "$release_tag"
git push origin "$release_tag"
```

Branches do not publish. A manual Actions run on a branch can prepare signed artifacts without publication; only a matching tag publishes. PR jobs have no signing secrets. Contents/Pages/OIDC write tokens are limited to the publisher. Pages uses Actions; `github-pages` permits `v*` tag deployments. Releases stay mutable for old-DMG cleanup. The workflow serializes without cancelling a publisher.

The first release may bootstrap a missing feed only at the pinned `firstReleaseBuild`, and only when both its Pages feed and latest GitHub release are absent. Every later missing feed fails closed; there is no reset to first-release behavior. Publisher validation ties artifacts to repository/tag/commit and the prior feed snapshot.

Signing imports a pinned identity into an isolated temporary CI keychain. Its search-list inclusion is temporary and restored on all paths; private material is removed even after failure. Sparkle tools and actions are pinned. Archive and single-entry feed signatures are verified before publication. GitHub controls caching; mismatched cached bytes must be rejected and retried without disabling signatures. Bounded verification precedes cleanup. A failed publisher may retry with its exact verified artifact; changed bytes require a new version/build. Never force-move a published tag.

Build/tool overrides are `SOUNDLANE_OUTPUT_DIR`, `SOUNDLANE_BUILD_DIR`, and `SOUNDLANE_TOOLS_DIR`. CI supplies `SOUNDLANE_SIGN_KEYCHAIN` and `SOUNDLANE_REQUIRE_RELEASE_SIGNING=1`. Packaging rejects absent or wrong identities. The personal website and unrelated repositories are outside this workflow.

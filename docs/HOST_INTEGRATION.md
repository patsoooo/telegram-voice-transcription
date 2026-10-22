# Pinned Telegram-iOS host integration

Build and live-smoke evidence is tracked in [BUILD_VALIDATION.md](BUILD_VALIDATION.md). Compile-only builds use intentionally invalid API values; the later transcript/summary smoke used a separately configured signed-in Premium simulator account.

> **Updated evidence (2026-10-22):** the final full host Debug simulator build **passed after all source changes: 77.927 seconds, 24 actions**. One short server transcript + AI Summary, one 1:01 chunked-speech summary and one manual word-seek interaction were observed in earlier builds on the signed-in Premium simulator. Protection and cleanup evidence is limited to code tests/static checks and the full build; no signed-in runtime testing followed the final changes, and no new live permission, cleanup or protection end-to-end validation is claimed. See the [follow-up review fixes](BUILD_VALIDATION.md#follow-up-review-fixes--2026-10-22). The separate compile-only startup reached onboarding without login.

> **Current recorded tests:** **36 XCTest cases passed with zero failures**, **526 summary smoke assertions**, **59 alignment checks**, and **18 Node fixture passes / 1 skipped real-host audit**. The core validation task passed. The former 19-pass result including the real host is historical; the generated host lockfile currently blocks the strict audit.

## Scope and current state (2026-10-22)

This feature repository is not a standalone iOS app. The official host is [TelegramMessenger/Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS), checked out separately and pinned to **`f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838`**. The full checkout, all 13 pinned submodules and Git LFS content are present. Final full Debug simulator compilation passed after all source changes, and limited live transcript/summary/seek interactions were manually observed in earlier builds. No feature-specific automated UI suite, physical-device test, broad acoustic accuracy benchmark or recipient verification is claimed.

The historical feature baseline is `abce7ccf9537b4074be346e852e2303c50b649fa` from patsoooo/telegram-voice-transcription. Do not confuse that comparison baseline with the official host pin.

| Artifact | Purpose |
| --- | --- |
| [Host manifest](../Integration/host-manifest.json) | Official repository, exact commit, version pins, patch scope and module destination. |
| [Combined host patch](../Integration/telegram-ios-f1dd7a2.patch) | Baseline integration plus direct voice-bubble entry and editable quoted-body reply. Changes 18 tracked host files and adds one host source. Excludes the feature module and optional host-only notes. |
| [Installer](../Scripts/integrate-telegram.mjs) | Node >=18, Git, no npm dependencies; read-only check by default, explicit apply only. No downloads, toolchain installation, signing or builds. |
| [Module build definition](../VoiceTranscriptScreen/BUILD) | Installed with all seven Swift sources: **8 files total**, at the module destination recorded in the manifest. |
| [Simulator compile-only example](../Integration/simulator-compile-only.example.json) | Safe template with deliberately dummy zero API values that cannot log in. Not production credentials and not a live-service test fixture. |
| [Historical patch](../changes.patch) | Earlier integration record only. **Do not apply it in addition to the combined patch.** |

Historical read-only audit: **patch applied; module files 8; byte-identical 5; `normalizedEofFiles` 3; missing 0**. Normalized matches differ only in terminal LF bytes and are left untouched. This is not an 8/8 byte-equality claim or a fresh audit pass. The obsolete host-local task file was deleted; [tasks now live in the feature repository](../.vscode/tasks.json). The current blocker is Bazel's generated host module lockfile (**139 added lines**), correctly rejected by the strict installer. Preserve/review that metadata separately; do not weaken the allowlist or infer a current 19-pass result from history.

## Check first (read-only)

Run these examples from the feature repository root. The host must be an **absolute path to the exact Git top-level**, not a subdirectory. Both invocations below perform the same read-only check:

```sh
node Scripts/integrate-telegram.mjs --host /path/to/Telegram-iOS
node Scripts/integrate-telegram.mjs --host /path/to/Telegram-iOS --check
```

The check reports whether the combined patch is applied or unapplied, which module files are missing, byte-identical or terminal-LF-normalized, and any Xcode warning. It does not change the index/worktree or perform network/build/signing operations. A successful source audit is **not build readiness**.

## Explicit installation

Only after reviewing the plan and host changes, opt into source installation:

```sh
node Scripts/integrate-telegram.mjs --host /path/to/Telegram-iOS --apply
node Scripts/integrate-telegram.mjs --host /path/to/Telegram-iOS --check
```

The host already has the patch and module; do not reapply them to bypass the generated-lockfile rejection. Review/preserve that metadata separately before expecting an audit pass. The examples are instructions, not a claim that apply was executed during documentation work.

### Safety rules and failure behavior

- Requires the **exact pinned HEAD** and exact required version values from the manifest. Another revision is refused, not automatically checked out or rebased.
- Validates patch paths and applicability. Exactly one of forward/reverse applicability checks must succeed; mixed, ambiguous or incompatible patch states are refused.
- Rejects unrelated staged, unstaged or untracked host changes. Allowed scope is the combined patch paths, the module destination and the one optional host-note path explicitly allowed by the installer. This allowance is not permission for arbitrary edits: patch applicability is still required.
- Applying an **unapplied** patch requires a **completely clean host Git status**. An already-applied patch may coexist with allowed integration changes; checks do not demand that the integrated checkout be globally clean.
- Copies only missing module files, exclusively; never overwrites a different existing module. Unexpected destination files, symlink path components and unsafe paths are refused. Terminal LF bytes alone are ignored for comparison; CR bytes, spaces and internal whitespace are not normalized. Such matches are counted separately and never rewritten.
- On failure, only module files created by that installer run are eligible for rollback; the host patch is **not reversed automatically**, even if just applied. Review the reported state and recheck. No reset, cleanup of unrelated work or destructive recovery is prescribed.
- Xcode checking emits a warning if full Xcode 26.6 is missing or mismatched. It does not install/select Xcode, sign, build or install an app. The warning is **not a source-apply prohibition**: explicit apply can install sources while the build remains blocked.

## What the integration implements

### Entry points

The [combined patch](../Integration/telegram-ios-f1dd7a2.patch) retains playback-header access and routes the voice bubble's transcription button directly to the sheet. The code is implemented, but eligibility, button visibility, gesture interactions and actual presentation require host/device testing. Do not describe it as missing, or as verified on every voice bubble.

### Quote/Reply: editable body plus ordinary native reply

The combined patch uses the normal native reply relationship to the voice message and prepends a timestamped **editable blockquote in the draft body**. It preserves the existing structural `ChatInputContent` blocks and shifts the existing selection by the inserted prefix length; it does not flatten the existing rich draft through an attributed-string round-trip. The shared reply-setup path serves the sheet and normal reply handling. Only the user's ordinary **Send** transmits the body; the quote can be edited or removed beforehand.

This replaces the historical fragment's local-only behavior. It is **not MTProto `quote_text`**, a server-verified transcript quote, or a guaranteed clickable audio time. Server transcript text is not the audio message's `message.text`, so treating it as a quoted substring of that field would be incorrect. Recipient visibility is implemented via ordinary message-body content, **not yet verified by sending to a recipient**. Separately, Share still sends timestamped plain text through confirmation UI.

### Protection and temporary-audio lifecycle

Message- and peer-level content protection is checked fail closed for transcript acquisition, export and AI processing, including unavailable protection state. Host quote insertion rechecks protection both synchronously and after asynchronous work. Verify these paths, including protection changes while the sheet or quote flow is open, before release.

Temporary audio copies have success/error/cancellation cleanup, including cancellation while Speech authorization is pending. The converted temporary file is retained until its writer drains on cancellation; if the converter never terminates, cleanup cannot safely complete. Task text retained in UserDefaults remains a known privacy gate. The [dated review record](BUILD_VALIDATION.md#follow-up-review-fixes--2026-10-22) details the eight additional retry, prompt, parsing, timing and overlap fixes.

### Timing providers

- **Default:** `ServerVoiceTranscriptProvider`, server text with estimated timing, `.estimated` provenance.
- **Optional measured recognition:** `RecognizedVoiceTranscriptProvider`, recognizer text and measured estimates, `.measured` provenance; words can differ from the server.
- **Optional strict matching:** `AlignedVoiceTranscriptProvider`, selected by **Match server words to speech timing (strict)**. Uses [alignVoiceTranscriptWords](../VoiceTranscriptScreen/Sources/VoiceTranscriptAlignmentCore.swift) to transfer recognition timestamps only on complete, exact normalized **positional lexical agreement**. Server word text is preserved. Insertions/deletions, tokenization or lexical mismatches and malformed timing are refused; no skipping, merging, reordering, partial output, guessed alignment or silent estimated fallback. Successful results use `.aligned` provenance.

Strict matching is not arbitrary-speech forced alignment. A manual transcript-word seek was confirmed to land on the spoken word in the tested sample. That successful sample does not benchmark strict-mode acoustic accuracy across recordings or devices: lexical agreement does not establish exact word boundaries, and measured timestamps have not been compared with ground truth. Recognition permission must already be granted, the device locale is the default (initializer override supported), and on-device-only processing is not guaranteed. Server/strict modes also require an available Telegram server transcript/entitlement.

## Build prerequisites and compile-only snapshot

The [manifest](../Integration/host-manifest.json) records the pinned host version requirements:

| Requirement | Pin |
| --- | --- |
| Host commit | `f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838` |
| Xcode | **26.6** (full installation; Command Line Tools alone are insufficient) |
| macOS | **26** |
| Bazel | **9.2.0** |
| Bazel hash from host version data | `dd466352a3e4d3581b8898740ee1ff208866ccbe25f8d367c5dcb950219587e6` |
| Deploy Xcode | **26.2** (separate manifest value, not a replacement for build Xcode) |
| Host app version | **13.0** |

Follow the [official compilation guide at the pinned commit](https://github.com/TelegramMessenger/Telegram-iOS/blob/f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838/README.md) for a complete checkout, dependencies, full Xcode setup, your own API credentials, bundle identifiers, configuration, signing and the supported build process. Use the guide and version data **at the pin**, not moving upstream HEAD. No guessed app-build command or borrowed signing/API credentials are provided here.

### Available setup

- Full expanded host checkout, all **13 pinned submodules initialized**, and Git LFS content recovered.
- **Xcode 26.6, build 17F113**; canonical developer directory was selected for local builds. Session/build-specific selection avoids relying on the system Command Line Tools fallback.
- **iOS 26.5 runtime, build 23F77**, installed; **iPhone 17 Pro** booted and used for the onboarding launch below.
- **MetalToolchain 17F109** installed; `metal` works.

### Resolved setup failures and current Bazel configuration

- **Corporate TLS / PKIX:** Bazel's Java trust was repaired using existing system public certificates in a local truststore under `~/Library/Caches/telegram-build-trust/bazel-cacerts`. Bazel is pointed at it with `--host_jvm_args=-Djavax.net.ssl.trustStore=…`. TLS verification was **not disabled**; this local trust configuration is not a production credential or a shipped feature change.
- **SDK lookup:** early `--action_env=DEVELOPER_DIR=…` attempts fell back to Command Line Tools. The successful selection uses **both** `--action_env=XCODE_VERSION_OVERRIDE=<Xcode developer directory>` and `--host_action_env=XCODE_VERSION_OVERRIDE=<Xcode developer directory>`, plus `--repo_env=DEVELOPER_DIR=…` and canonical process `DEVELOPER_DIR`. Pins are `--xcode_version=26.6`, `--ios_sdk_version=26.5` and locally `--macos_sdk_version=26.5`. `XCODE_VERSION_OVERRIDE` takes the developer directory here, not a version/build string.
- **Absolute header inclusion:** Xcode under Downloads was rejected because the generated C++ builtin include roots cover `/Applications`, `/Library`, `~/Applications` and `~/Library/Developer`, not Downloads. Moving the installation to user Applications resolves that path issue; preserving old Downloads links does not make the old location the canonical build path.
- **Stale SDK paths in artifacts:** the successful task uses isolated `~/Library/Caches/telegram-bazel-xcode266` as its output base, with no disk-cache option. Existing caches/artifacts were preserved; old disk artifacts retained stale paths. Canonical Xcode, both action environments and the new output base fully fixed the SDK/header-path failures without disabling TLS or header validation.
- **Wrapper limitations:** `Make.py` parses `--bazelArguments` but does not consume/forward it in this build path; do not recommend it for passing provisioning flags. `--disableProvisioningProfiles` is **not accepted** by the wrapper's build CLI. After the initial wrapper configuration/dependency resolution, the local build uses raw Bazel with the actual flag `--//Telegram:disableProvisioningProfiles`. These observations do not introduce a new wrapper API.

The [feature build task](../.vscode/tasks.json) invokes the already-configured host with the **pre-resolved** compile-only configuration, isolated output base and build-local truststore. It does not bootstrap a fresh checkout or resolve configuration itself. The tracked [simulator example](../Integration/simulator-compile-only.example.json) contains dummy zero API values that deliberately **cannot log in**. Keep real credentials only in the ignored `Integration/local-development.json` file.

**Final build result:** the full host Debug `sim_arm64` build **passed after all source changes, including the final fixes (77.927 seconds, 24 actions)**. The initial full build had already succeeded, including feature UI module emission and whole-app linking, without feature compile fixes. The earlier incremental repeat reported `Target //Telegram:Telegram up-to-date`, `bazel-bin/Telegram/Telegram.ipa`, and `Build completed successfully, 1 total action`. The final build is compile/link evidence only, not a new signed-in runtime check.

**Startup result:** the fresh IPA was unzipped into a temporary directory under the user cache and installed on the simulator above. Bundle `org.local.voicetranscript.CompileOnly` launched, remained alive at 20 seconds, and displayed onboarding. No login was attempted in this compile-only startup check; this does not verify transcript, summary, playback, sends or recipient behavior.

![Fresh Debug simulator onboarding: Telegram / Start Messaging, not feature UI proof](../screenshots/simulator-compile-only-startup.png)

Other screenshots are historical interface illustrations. Release/device builds, valid live configuration/signing and runtime release gates remain open.

## Verification and release gates

Current local evidence recorded on 2026-10-22:

- Foundation summary/alignment package build and Swift module syntax/whitespace checks passed.
- **526** summary smoke assertions: [runner](../Scripts/Smoke/main.swift).
- **59** alignment checks: [runner](../Scripts/AlignmentSmoke/main.swift). Tests lexical agreement and timing rejection, not acoustic accuracy or the asynchronous provider in a host app.
- **18 Node fixture tests passed; 1 real-host audit skipped**: [suite](../Tests/IntegrationInstaller.test.mjs). Strict installer rejects the generated host lockfile's 139 added lines. Former **19 passes including the real host** are historical.
- **36 XCTest cases passed with zero failures under Xcode 26.6**. [CI](../.github/workflows/swift-core.yml) is configured, not claimed run. The feature validation task includes both smoke runners and Node tests, not XCTest.
- Final full-host **Debug simulator compilation/type-check and linking passed after all source changes (77.927 seconds, 24 actions)**; the separate earlier compile-only onboarding startup passed. Earlier live smoke evidence also includes one short transcript + summary, one 1:01 chunked-speech summary, and one manual word seek. No signed-in runtime testing followed the final changes; protection and cleanup have code-test/static-check and full-build evidence only. Release, device and recipient tests remain unverified.

These are limited smoke checks, not comprehensive end-to-end feature tests. Before release, complete Release/device builds and systematically verify both entry points, default/measured/strict provider selection, strict mismatch refusal, speech permissions/locales, playback/seeks, summary API failures and recipient sends. For Quote/Reply, test rich drafts, nonempty selections, edit/removal, normal Send, ordinary reply relationships, recipient rendering, cancellation and draft persistence. Complete localization, accessibility, privacy/security, retention and logging review as detailed in [production readiness](PRODUCTION_READINESS.md).
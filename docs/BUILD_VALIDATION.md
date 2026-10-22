# Full-app validation record — 2026-10-22

## Follow-up review fixes — 2026-10-22

The actual current XCTest suite passed **36 tests with zero failures**. The core validation task passed with **526 summary smoke assertions, 59 alignment checks, 18 installer fixture passes and 1 skipped real-host audit**. The final full host Debug simulator build **passed after all source changes: 77.927 seconds, 24 actions**. User-provided live simulator evidence below refers to earlier builds. Protection and cleanup evidence is limited to code tests/static checks and the full build; no signed-in runtime testing was performed after these changes, and no new permission, cleanup or content-protection end-to-end validation is claimed.

Two high findings were addressed:

- **Temporary audio copies:** cleanup covers success, error and cancellation, including cancellation while Speech authorization is pending. The converted temporary file is retained while conversion is active; cancellation drains the writer before cleanup. If the converter never terminates, cleanup cannot safely complete; unconditional deletion is not guaranteed.
- **Content protection:** transcript acquisition, export and AI processing fail closed on message- and peer-level protection, including unavailable protection state. Host quote insertion rechecks protection in both synchronous and asynchronous paths.

Eight additional missed findings were implemented:

1. A retry waits past the stale cached server error rather than immediately treating it as the retry result.
2. AI timestamps are validated against the source times of that individual prompt, not the entire transcript.
3. Whole source lines start new prompts when they fit there; only oversized lines need splitting.
4. Strict parsing rejects empty labeled items.
5. Display timestamps floor total seconds before splitting into minutes and seconds.
6. Strict speech timing uses a chunk-scaled **90–900-second** budget; the server transcript wait has its own separate **90-second** budget.
7. All chunk word timing is validated before ownership filtering, including words that would be discarded.
8. Overlapping contexts require lexical, timing and ownership agreement; disagreements reject the transcript rather than silently choosing a chunk.

These fixes do not close the known privacy gate: task text remains stored in UserDefaults. Live permission/cleanup/protection end-to-end checks and the remaining release gates below are still open.

## What has actually been verified

| Check | Evidence / result |
| --- | --- |
| Matching Apple toolchain | Xcode 26.6, build 17F113, verified using `xcodebuild -version`. The local build used a canonical Xcode 26.6 installation. |
| XCTest on matching toolchain | Latest recorded run: **36 tests, zero failures** under Xcode 26.6. These are macOS Foundation tests, not iOS UI tests. |
| Host source completeness | Sparse checkout expanded; all 13 pinned Git submodules initialized. Git LFS installed and the interrupted wallet dependency checkout repaired. |
| Portable smoke checks | Current runs passed **526 summary assertions** and **59 alignment checks**. The assertion count grew with improved splitting coverage. These verify portable logic, not acoustic accuracy or feature UI behavior. |
| Installer tests | Current run: **18 Node fixture tests passed; 1 real-host audit skipped**. The former 19-pass result including the real host is historical, not current. |
| Initial full Debug simulator build | **Passed before the follow-up fixes:** `//Telegram:Telegram`, Debug `sim_arm64`. The feature UI module emitted and the whole app linked; no feature compile fixes were needed. |
| Final full host Debug simulator build | **Passed after all source changes, including the final review fixes:** `//Telegram:Telegram`, Debug `sim_arm64`; **77.927 seconds, 24 actions**. This verifies compilation/linking, not a new signed-in runtime test. |
| Earlier incremental repeat | `Target //Telegram:Telegram up-to-date` with `bazel-bin/Telegram/Telegram.ipa`; `Build completed successfully, 1 total action`. |
| Simulator startup | Fresh IPA installed and bundle `org.local.voicetranscript.CompileOnly` launched on iPhone 17 Pro, iOS 26.5. The app remained alive at the 20-second check; onboarding displayed **Telegram / Start Messaging**. |
| Host XCUITest `UITests/testLaunch` | **Passed: 1 test, zero failures** on the iPhone 17 Pro / iOS 26.5 runner. The test opened the app and verified foreground state. This is a launch smoke test only. |
| Live short-message transcript + AI summary | User-confirmed on the signed-in Premium simulator account. One manual transcript word tap/seek also observed. |
| Long-message chunked speech smoke | User-provided simulator screenshot showed a 1:01 voice message followed by an AI-generated summary after the optional Apple Speech chunk path was added. Manual evidence only; word accuracy and repeatability not measured. |
| Shader compiler | Apple's Metal Toolchain 17F109 downloaded; `xcrun metal --version` succeeds. |
| Secure dependency downloads | Bazel initially failed Java certificate validation. A build-local Java truststore combines Bazel's roots and public system-keychain certificates. TLS verification remains enabled; no private keys exported and no global trust changes made. |

## Full build result and resolved setup failures

The final full `//Telegram:Telegram` Debug simulator target **succeeded after all source changes (77.927 seconds, 24 actions)**, including the follow-up fixes above. The initial full build had also succeeded before those fixes. Early attempts failed on environment setup:

1. Bazel registry TLS trust-chain failure. Resolved with a local Java truststore rather than disabling certificate verification.
2. Missing Metal compiler. Downloaded Apple's Metal component.
3. SDK lookup under Bazel's empty subprocess environment. The globally selected fallback was Command Line Tools; `--action_env=XCODE_VERSION_OVERRIDE=<developer directory>` lets Bazel inject SDK and developer paths. Host tools also need the corresponding `--host_action_env` override.
4. Xcode under Downloads caused absolute-header validation failures. The generated Apple toolchain's builtin include roots accept user Applications, not Downloads. Xcode was moved to user Applications without disabling include validation.
5. Old absolute SDK paths remained in compiled artifacts/dependency files. The successful build uses isolated `--output_base=~/Library/Caches/telegram-bazel-xcode266` (expanded by the task), with **no disk-cache option**. Old artifacts were preserved rather than deleted or reused. Canonical Xcode plus **both target and host** `XCODE_VERSION_OVERRIDE` action environments and the new output base fully resolved these path failures; header validation remains enabled.

**Verified build scope:** final full Debug simulator compilation/type-checking, including the feature UI/provider module, and whole-app linking passed after all source changes. The earlier initial build and incremental repeat also succeeded without feature source compile fixes. Limited live transcript/summary interactions from earlier builds are separately recorded above; no signed-in runtime test followed the final changes. Broad end-to-end coverage and Release/device verification remain open.

## Installed artifact and startup evidence

The fresh IPA was unzipped into a `mktemp` staging directory under `~/Library/Caches`, then installed into the booted simulator and launched. A separate host XCUITest also passed its `testLaunch` foreground assertion. These establish startup only, not login or transcript-sheet behavior. No login or account creation was attempted in that test.

![Fresh Debug simulator app at Telegram / Start Messaging onboarding; not feature UI verification](../screenshots/simulator-compile-only-startup.png)

All other repository screenshots are historical interface illustrations, not evidence from this build.

## Credential-free compilation, not live testing

[Integration/simulator-compile-only.example.json](../Integration/simulator-compile-only.example.json) intentionally contains `api_id = 0` and an all-zero API hash. It is a safe template only; it must not be used for login, real service tests, distribution or production. Keep real credentials in the ignored local `Integration/local-development.json` file.

The feature workspace's [build task](../.vscode/tasks.json), **Build Telegram simulator (compile-only configuration)**, builds the already-configured host target with the canonical Xcode path, isolated output base, no disk-cache option, and `XCODE_VERSION_OVERRIDE` in **both** target and host action environments. It assumes the compile-only fixture was already resolved and the build-local truststore exists; it does not configure a fresh checkout or supply live credentials. The obsolete host-local task file was deleted; tasks now live in the feature workspace. Refer to [host integration](HOST_INTEGRATION.md) for the pinned source and supported prerequisites.

## Generated files and audit policy

Bazel added **139 lines** to the host module lockfile during dependency resolution. The strict integration installer correctly refuses that extra tracked change; the obsolete host task file is no longer the blocker. Do not weaken change-scope validation or silently discard the lockfile. Review/preserve generated metadata separately before the next source-only audit. Current Node results are **18 fixture passes and 1 skipped real-host audit**; the previous **19 passes including the real host** remain historical.

## Still required for release

### Live simulator transcription failure (2026-10-21)

The signed-in simulator reached Saved Messages and opened a real voice message's
transcript sheet. Both transcript and summary remained unavailable; the summary's
debug state reported no transcript to summarise. Speech permission was confirmed
granted, and sanitized simulator logs showed `kAFAssistantErrorDomain` code `1101`.
That code alone does not establish a specific missing model or network cause.

Two code defects were corrected: explicit speech-provider selection now requests
undetermined speech permission, and LocalAudioTranscription no longer overwrites
the runtime's on-device capability with `true`. The latter permits Apple's online
recognition when the runtime does not report on-device support; this is not an
offline-only provider. Both full Debug simulator rebuilds passed, and the latest
fresh IPA was deployed with account data preserved. The integration patch passes
reverse validation against the host; installer fixtures passed 18 tests with one
real-host audit skipped. **Successful recognition and summary generation remain
unverified pending a fresh attempt in the updated app.**

The subsequent attempt still failed. Speech-service logs now establish a runtime
asset-loading failure: `localspeechrecognition` could not create its recognizer,
and the speech asset set reported `com.apple.MobileAssetError.AutoAsset` /
`NoSharedLock(6582)` with `errno:2` while resolving its shared-lock symlink.
The app continued receiving `kAFAssistantErrorDomain` / `1101`. Permission remains
granted. This is evidence of an unavailable/broken speech-asset path in this
simulator, not evidence that the recording contains no speech. Retrying permission
selection cannot repair it. Physical-device recognition and server transcription
are separate paths that remain unverified; neither is established working by this
diagnosis. No runtime assets or user data were removed or reset.

As a targeted simulator workaround, the speech request now sets
`requiresOnDeviceRecognition = false` only for Simulator builds, allowing Apple's
network recognizer if available; physical devices continue to follow Apple's
reported on-device capability. This permits speech audio to be processed by
Apple's service and is not an offline guarantee. The updated Debug build succeeded
and was installed over the existing app bundle after backing up that bundle; the
separate account data container was not changed. This fallback still needs a live
transcription attempt and is not yet confirmed to overcome the simulator asset or
network failure.

**Initial retest:** the screenshot showed `PREMIUM_ACCOUNT_REQUIRED`, confirming
Telegram required Premium for transcription on the signed-in account. App ID/hash
authenticate the client but do not grant this service entitlement. The local
Apple Speech option also fails in this simulator with
`kAFAssistantErrorDomain` `1101` / `MobileAssetError.AutoAsset` `6582`.

The feature uses Telegram server transcription by default and Telegram's
`composeAIMessage` for the summary. The latest build keeps that server path primary,
retries a previously stored generic server error once when the transcript sheet is
opened again, and improves the DEBUG-only summary failure hint. Build and host
module byte-parity checks passed; the updated app bundle was installed while the
account data container was preserved. The later Premium-account live result is
recorded below.

### Final Premium-account retest (2026-10-22)

After Premium was activated on the signed-in account, the diagnostic advanced to
“Telegram accepted the request; waiting for its transcript update.” The next
screenshot shows actual timestamped transcript text in the voice-message sheet.
**Telegram server transcription is verified working for this 8-second Saved
Messages voice message.** The subsequent screenshot shows a generated AI Summary
with a timestamped key point matching that transcript. **Transcript and summary
are both verified working in this simulator for this message/account.** Apple
Speech remains unavailable in this simulator; Telegram server transcription and
Telegram AI summary are the working path.

### Longer-message retry (2026-10-22)

A 1:06 voice message first showed `Telegram returned an empty transcript`; this is
not the explicit `MSG_VOICE_TOO_LONG` response and there is no one-minute duration
check in our client code. The provider retries once when a later sheet opening
finds a cached empty result. On retest, Telegram returned RPC code
`TRANSCRIPTION_FAILED`. This is a server-side transcription failure, not a client
duration cutoff. The Debug build and portable tests passed; account data was
preserved. The client cannot recover a transcript when Telegram's service returns
this failure. A local-model provider would be needed as a separate fallback if
long-message transcription must work independently of Telegram's service.

Telegram's [official transcription API](https://core.telegram.org/api/transcribe)
documents a configurable maximum duration for **non-Premium trial** requests (the
published default is 300 seconds) and separately documents `MSG_VOICE_TOO_LONG`
and `TRANSCRIPTION_FAILED` RPC errors. Thus the observed `TRANSCRIPTION_FAILED`
on a Premium account's 1:06 message is not evidence of a universal 60-second cap;
Telegram's backend failure reason is not further specified by that RPC code.

The optional **Use speech timing (device language)** provider now splits long
recordings into overlapping 45-second Apple Speech requests, offsets timestamps
back onto the original recording timeline, and keeps only words owned by each
non-overlapping interval. Chunk failure rejects the complete local transcript
rather than returning incomplete text. The chunk planner is covered by XCTest.
The user subsequently supplied a simulator screenshot showing a **1:01 voice
message followed by an AI-generated summary** containing details about the
chunking implementation. This is manual evidence that the long-message path
produced text usable by the summary flow. It does not validate every word boundary
or prove repeatable accuracy across languages. Earlier simulator attempts logged
Apple Speech asset errors (`1101`/`6582`); behavior can vary with the simulator's
Speech assets/network availability. The default Telegram server provider remains
unchanged and does not silently send audio to Apple's service after a Telegram
failure.

The transcript Copy menu was later changed to copy selected text first, then the
active search query, and the entire transcript only when neither applies. The
latest Debug app was rebuilt and installed with account data preserved. Clipboard
behavior for the selection/search cases has not yet been manually confirmed.

The user then tapped a transcript word. The shared simulator screenshot shows
“previously” selected at transcript time `0:04`, while the player position is
`0:05`; this is a successful manual word-selection/seek/highlight smoke check for
that word. The user confirms the seek lands exactly on the spoken word in this
sample and reports the translation control works. These are user-observed checks
for this message, not cross-language accuracy or failure-case coverage. Note that
the server supplies plain transcript text, and the provider currently derives
estimated word positions from that text; no server word-boundary timestamps are
available to establish a general exact-timing guarantee.

Following a copy-scope report, the transcript menu now copies selected text first,
the active search query second, and the whole transcript only when neither is
active. The Debug simulator rebuild passed and was installed while preserving the
account data container; this new selection/search copy behavior still needs a
manual clipboard check.

- Release and physical-device builds/testing; the final-change full Debug simulator build passed (77.927 seconds, 24 actions).
- Live permission, cleanup and protection end-to-end checks after the final changes; current evidence for protection and cleanup is code tests/static checks plus the full build only.
- Systematic AI Summary validation: failure/timeout/retry behavior, quotas, long-input coverage and factual accuracy. A short live summary and one chunked-speech summary were observed; these do not cover those cases.
- Remaining playback, seek, selection, copy, translation, lifecycle and recipient behavior beyond the specific manual smoke checks recorded above.
- A second test account/device for recipient-side send/reply verification; never share passwords, login codes, API hashes or signing secrets in chat.
- UI-driving automation is not currently exposed to this session through Xcode MCP. Simulator command-line boot/install/launch and screenshots are available, but interactive verification must use a supported automation connection or be performed by the user.
- The remaining privacy, localization, accessibility and lifecycle gates in [production readiness](PRODUCTION_READINESS.md).

Neither exact acoustic timing nor production correctness follows from successful lexical alignment tests. Native MTProto audio-transcript quote metadata is not supplied; the implemented recipient-visible behavior is an editable quoted message body with a normal reply relationship.
# Voice Message Transcript and AI Summary

> **Build and smoke update (2026-10-22):** the final full host Debug simulator build **passed after all source changes: 77.927 seconds, 24 actions**. Earlier builds produced Telegram transcripts and AI summaries for an 8-second message on the signed-in Premium simulator; a user-provided screenshot also showed a summary for a 1:01 message using the optional chunked speech path. One word-seek/highlight interaction was manually observed. Current automated checks: **36 XCTest passes with zero failures, 526 summary + 59 alignment smoke checks, 18 Node fixture passes and 1 skipped real-host audit**. See [build validation and follow-up review fixes](docs/BUILD_VALIDATION.md#follow-up-review-fixes--2026-10-22); protection and cleanup evidence is limited to code tests/static checks and the full build, with no signed-in runtime testing after these changes.

A redesigned way to work with voice messages in Telegram for iOS: a sheet where the audio and its text move together, with a summary of the key points on a second tab.

> **Release validation:** final Debug `sim_arm64` compilation passed after all source changes; targeted live simulator checks in earlier builds exercised transcript, summary, one long-message path and one word seek. Release readiness has not been fully validated: Release/device builds, broader interaction and recipient checks, accessibility, localization, privacy review and release checks remain open. See [host integration](docs/HOST_INTEGRATION.md) and [production readiness](docs/PRODUCTION_READINESS.md).

![The transcript sheet over a chat](screenshots/sheet-overview.png)

## Implementation comparison: upstream vs. this workspace

**Historical feature baseline:** upstream commit `abce7ccf9537b4074be346e852e2303c50b649fa`, fetched from [patsoooo/telegram-voice-transcription](https://github.com/patsoooo/telegram-voice-transcription/commit/abce7ccf9537b4074be346e852e2303c50b649fa). **Current:** local workspace changes described below; these are not claims that upstream has merged or released them. The separate **official host baseline** is `f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838` from TelegramMessenger/Telegram-iOS, recorded in the [host manifest](Integration/host-manifest.json). The [combined host patch](Integration/telegram-ios-f1dd7a2.patch) supersedes the [historical integration patch](changes.patch) for this pin; do not apply both.

**Status key:** **Implemented** means code exists in this module or, where explicitly marked, the combined host patch; it does not by itself mean every interaction was tested. **Core verified** means portable logic has local executable checks. **Live smoke observed** means a limited manual simulator check was reported, not a complete test. **Host validation required** means that specific runtime behavior still needs testing. No row certifies production readiness.

### Feature improvements and verification status

| Feature / earlier gap | Earlier implementation | Current implementation and precise boundaries | Status | Code reference / symbols |
| --- | --- | --- | --- | --- |
| Task timestamps | Tasks held only text and completion state; no audio position. | `VoiceSummary.Task.time: Double?` stores the source position. New live AI tasks require a timestamp; old stored tasks still decode with `nil` rather than an invented time. | Implemented; core verified | [Summary model and parser](VoiceTranscriptScreen/Sources/VoiceSummaryCore.swift): `VoiceSummary.Task`, `parseVoiceSummary(_:rejectMalformedItems:)` |
| Tap a task's time to seek | Task rows only toggled checkboxes. | A separate 44-point-high timestamp button seeks without toggling completion; the checkbox/text still toggles completion. | Implemented and compiled; task-time seek interaction not separately smoke-tested | [Summary UI](VoiceTranscriptScreen/Sources/VoiceTranscriptScreen.swift): `VoiceSummaryView.buildContent(_:)`, `addCard(...)` |
| Preserve task times in exported text | Task Copy/Share text contained completion marks and task text only. | Task Copy and whole-summary Share include completion marks and available timestamps. Legacy untimed tasks remain untimed. | Implemented; task export output not separately verified | [Summary export](VoiceTranscriptScreen/Sources/VoiceTranscriptScreen.swift): `shareableText`, task-card `copyText` closure |
| Access measured word timing | A measured Apple Speech provider existed, but was not selectable through this sheet; default timing was estimated. | Player menu explicitly selects speech recognition in the device language or returns to estimated server timing. Recognition can change the words; its initializer accepts `localeIdentifier`. No silent estimated fallback on recognition failure. | Implemented; one user-provided 1:01 simulator screenshot showed the chunked-speech path producing text used by Summary; broader accuracy/repeatability remains untested | [Provider switch](VoiceTranscriptScreen/Sources/VoiceTranscriptScreen.swift): `presentMoreMenu(sourceView:)`; [speech provider](VoiceTranscriptScreen/Sources/VoiceTranscriptRecognition.swift): `RecognizedVoiceTranscriptProvider` |
| Preserve server words with measured timing | No selectable strict lexical matching path. | **Match server words to speech timing (strict)** selects `AlignedVoiceTranscriptProvider`. Transfers recognition timestamps only after exact normalized, positional lexical agreement for every token; preserves server word text, refuses insertions/deletions, mismatches and invalid timing, and never guesses or returns partial alignment. | Implemented; **59 current portable alignment checks passed**. The separate manual word-tap seek landed on the spoken word in the tested sample; strict-mode acoustic accuracy is not yet benchmarked across recordings/devices. | [Alignment core](VoiceTranscriptScreen/Sources/VoiceTranscriptAlignmentCore.swift): `alignVoiceTranscriptWords`; [provider](VoiceTranscriptScreen/Sources/VoiceTranscriptAlignment.swift) |
| Understand timing accuracy | Timing limitations were documented, but the transcript model did not identify the source. | Transcript carries `.estimated`, `.measured`, `.aligned`, or `.demo`; player menu describes the source. `.aligned` means lexical agreement with transferred measured timestamps, not ground-truth accuracy or forced alignment. | Implemented; source-label presentation not separately runtime-verified | [Transcript model](VoiceTranscriptScreen/Sources/VoiceTranscriptData.swift): `VoiceTranscriptTimingProvenance`; [player menu](VoiceTranscriptScreen/Sources/VoiceTranscriptScreen.swift): `presentMoreMenu(sourceView:)` |
| Recipient-visible timestamped quotations | Quote/Reply showed timestamp and selected words only in the sender's composer; recipients received a normal voice-message reply. | Combined host patch prepends an **editable timestamped blockquote in the message body** plus an ordinary native reply to the voice message. Preserves existing `ChatInputContent` blocks and shifts the selection; only normal Send transmits it. Separate Share still offers timestamped ordinary text with confirmation. **Not MTProto `quote_text`**, server-verified quote metadata, or a guaranteed clickable audio time. | Implemented in host patch; send/recipient/device validation required | [Combined host patch](Integration/telegram-ios-f1dd7a2.patch): `voiceReplyInputState`, `setupReplyMessage`; [Share](VoiceTranscriptScreen/Sources/VoiceTranscriptScreen.swift): `presentShareQuote(text:timeText:)` |
| Open directly from a voice bubble | Historical integration opened from the playback header only. | Combined host patch routes the voice bubble's transcription button to the transcript sheet; playback-header access is retained. | Implemented in host patch; not device verified | [Combined host patch](Integration/telegram-ios-f1dd7a2.patch): `ChatMessageInteractiveFileNode` transcription-button action |
| Summary failure safety | Failed AI requests could show seeded random sample content unrelated to the recording. | Both real providers use the server summary path; failures return `.unavailable`. No sample-content fallback. Explicit demo providers still exist as fixtures. | Implemented; core placeholder rejection verified | [Server provider](VoiceTranscriptScreen/Sources/ServerVoiceTranscript.swift): `makeSummary(...)`; [speech provider](VoiceTranscriptScreen/Sources/VoiceTranscriptRecognition.swift): `summary(context:messageId:transcript:)` |
| Missing AI categories | Missing key points could be filled with randomly chosen transcript lines. | Live summary path no longer calls random completion; absent categories remain absent. This avoids disguising arbitrary transcript excerpts as AI-selected key points. | Implemented | [Server pipeline](VoiceTranscriptScreen/Sources/ServerVoiceTranscript.swift): `makeSummary(...)` |

### Reliability, privacy and test improvements added

| Improvement | Earlier behavior / risk | Current behavior | Status | Code reference / symbols |
| --- | --- | --- | --- | --- |
| Lossless long-transcript chunking | Lines exceeding the prompt budget were truncated; transcripts needing more than six chunks were sampled. | Whole source lines start new prompts when they fit; oversized lines split losslessly, preserving Unicode scalars and repeating the source timestamp on continuations. Each complete prompt is at most **900 UTF-16 units**. More than **128 parts** returns no prompts and makes the summary unavailable, rather than silently dropping content. This guarantees input coverage within the bound, not that the AI mentions every fact. | Implemented; core verified | [Chunking](VoiceTranscriptScreen/Sources/VoiceSummaryCore.swift): `voiceSummaryPrompts(lines:languageName:)` |
| No silent partial-success summary | Failed chunks could be omitted while successful chunks were presented as the result. | Every part must return a usable parsed and validated result; a failed part invalidates the whole summary. | Implemented; live API validation required | [Sequential pipeline](VoiceTranscriptScreen/Sources/ServerVoiceTranscript.swift): `makeSummary(...)`, nested `accumulate(...)` |
| Bounded request concurrency and retries | Part requests were combined concurrently; a global deadline bounded the aggregate operation. | Requests run sequentially. Generic errors receive at most one retry, within a **30-second per-part** timeout. Large accepted inputs can still take many minutes; there is no single short whole-summary deadline. | Implemented; cancellation/rate-limit testing required | [Request handling](VoiceTranscriptScreen/Sources/ServerVoiceTranscript.swift): `voiceSummaryGenerate(context:prompt:)` |
| Strict AI response parsing | Some missing/invalid times became zero; unstructured output could become a headline. | Live requests use `rejectMalformedItems: true`. Empty labeled items and invalid/missing timed items reject the response; arbitrary unlabeled prose is not accepted as a summary. Legacy parsing remains available for untimed tasks outside the strict live path. | Implemented; core verified | [Parser](VoiceTranscriptScreen/Sources/VoiceSummaryCore.swift): `voiceSummaryTime(_:)`, `parseVoiceSummary(_:rejectMalformedItems:)` |
| Source timestamp validation | Model-generated seek times were not checked against source line starts. | Rejects nonfinite, negative and unrelated times against each prompt's own source times. Accepted times snap to the nearest allowed line start only within **one second**, accommodating display rounding. Display timestamps floor total seconds first. This does not prove semantic correctness. | Implemented; core verified | [Validation](VoiceTranscriptScreen/Sources/VoiceSummaryCore.swift): `voiceSummaryValidated(_:allowedTimes:)`; [live enforcement](VoiceTranscriptScreen/Sources/ServerVoiceTranscript.swift): `makeSummary(...)` |
| Preserve merged items | Merged summaries capped key points/tasks/questions globally; deduplication by text alone lost repeated statements at different positions. | No global item-list caps. Deduplicates by lowercase text **and source time**, retains identical text at different times, and orders timed items chronologically. Chunk-level AI item limits still apply; part headlines are joined, not silently truncated for another prompt. | Implemented; core verified | [Merge](VoiceTranscriptScreen/Sources/VoiceSummaryCore.swift): `voiceSummaryCombined(_:)` |
| AI invoked by user action | Summary generation started as soon as the transcript was ready. | Generation starts only after the user opens the Summary tab, guarded against duplicate requests in the sheet. This is not a complete consent/disclosure policy. | Implemented; host validation required | [Tab/request lifecycle](VoiceTranscriptScreen/Sources/VoiceTranscriptScreen.swift): `selectTab(_:)`, `startSummary(transcript:)`, `didRequestSummary` |
| Prompt-injection mitigation | Prompt did not explicitly distinguish transcript content from instructions. | Prompt identifies transcript text as untrusted data and tells the model not to follow its commands or invent facts. This is mitigation, not an injection-proof or hallucination-proof guarantee. | Implemented; instruction covered by core checks | [Prompt](VoiceTranscriptScreen/Sources/VoiceSummaryCore.swift): `voiceSummaryInstruction(languageName:maxItems:)` |
| Summary cache isolation and retention | Summary cache persisted text in UserDefaults and was keyed by message without an account/source identity. | Locked, **32-entry memory-only** cache uses account/message identity and exact transcript text/timing identity. Restart regenerates summaries. Old disk data is neither read nor automatically deleted. | Implemented; logout erasure/storage policy still required | [Summary cache](VoiceTranscriptScreen/Sources/ServerVoiceTranscript.swift): `VoiceSummaryCache` |
| Recognized transcript cache | Recognized words persisted in files; cache identity did not include account and locale. | Locked, **32-entry memory-only** cache scoped by account, audio file and recognition locale. Legacy files remain untouched. | Implemented; host privacy review required | [Transcript cache](VoiceTranscriptScreen/Sources/VoiceTranscriptRecognition.swift): `VoiceTranscriptCache` |
| Recognition validation and deadline | Locale guesses included English; returned word ends could be clamped; timeout covered download rather than the entire path. | Uses the chosen locale, requests Speech permission on explicit selection, and validates finite/monotonic word timing. Long recordings use sequential overlapping 45-second windows; timestamps are offset to the full audio, duplicate-boundary words are excluded, and any failed chunk rejects the whole transcript. Deadline scales with chunk count up to 15 minutes. | Implemented; planner core tested; live-device accuracy still required | [Speech handling](VoiceTranscriptScreen/Sources/VoiceTranscriptRecognition.swift): `validatedVoiceTranscriptWords(_:duration:)`, `transcribeAudioInChunks(...)` |
| Safe player seeks | Seek requests were sent directly to playback controls. | Rejects nonfinite values and invalid duration; clamps valid seek targets to the current media duration. | Implemented; host validation required | [Playback](VoiceTranscriptScreen/Sources/VoiceTranscriptScreen.swift): `seek(to:)` |
| Task completion account isolation | Task state key contained message identity but not the current account. | Account identity added to versioned completion keys. Task text is **still stored in UserDefaults**; protected storage and retention review are not finished. | Implemented isolation; privacy work remains | [Task state](VoiceTranscriptScreen/Sources/VoiceTranscriptScreen.swift): `tasksKey`, `loadTaskStates`, `saveTaskStates` |
| Sensitive summary logs | Debug summary logs could contain model answers and server error details. | Current module does not print answer text, transcript contents or server error descriptions. The combined host patch's separately added AI diagnostics still need review. | Implemented in module; host review required | [Server requests](VoiceTranscriptScreen/Sources/ServerVoiceTranscript.swift): `voiceSummaryGenerate(context:prompt:)`; [combined host patch](Integration/telegram-ios-f1dd7a2.patch) |
| Portable tests and CI | Repository had no standalone Swift package or executable regression suite. | Foundation-only summary/alignment package, XCTest cases, standalone checks, macOS CI and a VS Code validation task. Installer tests exercise safety, not the iOS app. | Latest recorded run: **36 XCTest cases, zero failures**, **526 summary smoke assertions**, **59 alignment checks**, **18 Node fixture passes / 1 real-host audit skipped**. CI configured, not claimed run | [Package.swift](Package.swift), [summary XCTest](Tests/VoiceSummaryCoreTests/VoiceSummaryCoreTests.swift), [alignment XCTest](Tests/VoiceSummaryCoreTests/AlignmentTests.swift), [summary smoke](Scripts/Smoke/main.swift), [alignment smoke](Scripts/AlignmentSmoke/main.swift), [installer tests](Tests/IntegrationInstaller.test.mjs), [CI](.github/workflows/swift-core.yml), [VS Code task](.vscode/tasks.json) |

### Features that already existed and were retained

These are **not newly implemented features** and should not be counted as additions in this workspace.

| Existing feature | Upstream status | Current scope | Code reference |
| --- | --- | --- | --- |
| Transcript/AI Summary sheet | Implemented | Retained; playback-header entry retained, direct voice-bubble entry added in the combined host patch. | [Screen](VoiceTranscriptScreen/Sources/VoiceTranscriptScreen.swift): `VoiceTranscriptScreen`; [host patch](Integration/telegram-ios-f1dd7a2.patch) |
| Active line/word highlighting, tap-to-seek, Synchronize | Implemented with estimated default timing | Retained; timing choice/provenance added, but estimated timing remains the default. | [Screen](VoiceTranscriptScreen/Sources/VoiceTranscriptScreen.swift), [server timing](VoiceTranscriptScreen/Sources/ServerVoiceTranscript.swift): `approximateVoiceTranscript(text:duration:)` |
| Search, cross-line selection, Copy and Translate | Implemented | Retained; Share added separately. | [Transcript UI](VoiceTranscriptScreen/Sources/VoiceTranscriptScreen.swift): `VoiceTranscriptListView`, `menuForSelection()`, `presentTranslate(text:)` |
| Waveform, speed, skip controls, Play/Pause, neighboring voice navigation | Implemented | Retained; safe seek checks and timing-provider menu added. | [Player UI](VoiceTranscriptScreen/Sources/VoiceTranscriptScreen.swift) |
| Key points/questions and task completion controls | Implemented, with unreliable summary fallback | Retained; live summary path hardened and task timestamps added. | [Summary UI](VoiceTranscriptScreen/Sources/VoiceTranscriptScreen.swift): `VoiceSummaryView` |

## Why

Long voice messages are hard to work with. A manager dictates a pile of tasks, a friend tells a story, a classmate sends a lecture. Often you need to do more than listen: find the one thing that matters, note down a thought, or answer something that was said.

That is where it gets inconvenient. You replay the message, scrub back and forth, and try to remember where the thing you need was mentioned. When you want to reply to one specific point, you have to explain which one.

Telegram already offers a transcription (for Premium users), and it helps. But the text alone is not enough: finding a phrase, jumping to that moment in the audio, or quoting what was said is still awkward. This project turns the transcription into a tool for working with a voice message, so it can be used like regular text instead of only being listened to from start to finish.

## What it does

Tap the playback panel at the top of a chat while a voice message plays. With the combined host patch, the voice bubble's transcription button also opens the sheet directly. Both entry points lead to **Transcript** and **AI Summary** tabs; the new bubble behavior still requires host/device verification.

![The playback panel at the top of a chat](screenshots/playback-panel.png)

### Transcript

- **Text in sync with the audio.** The line being spoken is highlighted, and so is its current word. There is always exactly one active line. Pauses between words do not leave the text without an active word.
- **Tap to seek.** Tap a word (or the time of a line) and the audio jumps to that moment.

![The line and word being spoken are highlighted](screenshots/transcript-active.png)

- **Synchronize.** If you scroll away from the line being spoken while a message plays, a *Synchronize* button appears and takes you back to it. After a pause, pressing Play scrolls the text smoothly back to the active line.

![The Synchronize button over a scrolled text](screenshots/synchronize.png)

- **Selection.** Select text across several lines with handles on both ends. The menu offers **Quote**, **Copy**, **Translate**, and **Share**. Share opens Telegram's confirmation UI with timestamped plain text; it never sends automatically.

![A selection across lines with the Quote, Copy and Translate menu](screenshots/selection-menu.png)

- **Quote with a timestamp.** With the combined host patch, Quote prepares an ordinary native reply and prepends an editable body blockquote such as "0:42 — the deadline moved to Friday". Existing rich draft blocks are retained and the selection is shifted. Nothing is auto-sent; edit or remove the quote before normal Send. This is intended recipient-visible message content, not server-verified `quote_text` or a guaranteed clickable audio time. Sending and recipient rendering have not been device-tested.

![The reply field with the quoted time and words](screenshots/reply-quote.png)

- **Search.** Look for a word or a phrase inside this one voice message. Every match is highlighted in the transcript.
- **Skeleton while loading.** A shimmering placeholder is shown until the whole text has arrived. (What if a little dinosaur kept you company while you wait?)

![The skeleton shown while the transcript is loading](screenshots/skeleton.png)

### Player

The bottom of the sheet is a full player:

- a waveform you can scrub,
- elapsed and remaining time,
- playback speed,
- 5 seconds back and forward,
- animated Play/Pause,
- a **⋯** menu: *Reply*, *Copy Transcript*, *Translate Transcript*, *Forward*, *Next Voice* / *Previous Voice*, timing provenance, optional measured recognition and **Match server words to speech timing (strict)**,
- the time the message was sent.

![The player with the menu open](screenshots/player-menu.png)

### AI Summary

The key points, tasks and questions in one place:

- **Key points** with a time. Tap the time to jump to that moment in the Transcript tab and in the audio. Tap the text to open a menu with **Reply** and **Copy**.
- **Tasks** with checkboxes and source timestamps when returned by the AI. Tap a task's text or checkbox to tick it; tap its separate time button to seek without toggling completion. Copy and Share retain task times and ticks. Completion is scoped to the current account and message; legacy untimed tasks remain untimed.
- **Questions** with a time, like the key points. Tap the time to jump to that position. The text menu offers **Reply**, **Copy**, and **Share**. With the combined host patch, Reply prepares the editable timestamped body quote and ordinary reply relationship; Copy copies the text, and Share uses confirmation UI.

![The AI Summary tab: key points, tasks and questions](screenshots/summary.png)

## Limitations

Please read these before trying it.

1. **Timing depends on the selected provider.** Telegram's server returns transcript *text*, not per-word timestamps, so the default provider estimates positions by distributing words over the recording. The optional **Use speech timing (device language)** path processes audio in overlapping chunks no longer than 45 seconds, then maps word times back onto the full recording. On the tested short message, tapping a transcript word landed on the spoken word; the user confirmed that seek was exact for that sample. A user-provided simulator screenshot also shows a transcript/summary for a 1:01 message using chunked speech. Speech recognition may differ from Telegram's words and depends on Apple's Speech service, permission, locale and available assets. Strict alignment refuses non-matching words. The observed seek is a successful sample, not a benchmark across recordings, devices or languages.
2. **AI Summary is best-effort, not an authoritative record.** Generation starts only when the Summary tab is opened. Every prompt is limited to 900 UTF-16 units, and all transcript content is included without six-part sampling or line truncation. A maximum of 128 parts bounds work; larger inputs are refused rather than partially summarized. Requests run sequentially, with one retry for a generic error and a 30-second deadline per part. A failed part, malformed response, or rejected timestamp makes the entire summary unavailable. Successful items are merged without global list caps, and part headlines are joined. There is no fabricated-content fallback or random key-point filling in either real provider. AI can still omit facts or hallucinate; timestamp validation does not prove factual correctness. Results are cached only in bounded account/message/source-scoped memory and are regenerated after app restart.
3. **Telegram server transcription can fail.** Default and strict modes require Premium or an available free trial and a usable server transcript. A 1:06 message returned Telegram's `TRANSCRIPTION_FAILED` RPC even on Premium; no one-minute limit exists in this client. The optional chunked speech-recognition mode is a separate user-selected path, not an automatic upload to another provider, and still depends on Apple's Speech service. A prior simulator attempt failed because Speech assets could not load; the later 1:01 run succeeded, so availability may vary by runtime/device.
4. **Quoted body is not native transcript-quote metadata.** The historical patch displayed the fragment locally only. The combined pinned-host patch instead adds editable timestamped body text in a blockquote with an ordinary native reply; normal Send is required. It deliberately does not set MTProto `quote_text`, because the server transcript is not the audio message's `message.text`. No server verification or clickable exact-time link is claimed. Share remains a separate plain-text option.
5. **Measured and strict timing are opt-in.** The menu identifies provenance and retains estimated server timing as default. `RecognizedVoiceTranscriptProvider` may change words. `AlignedVoiceTranscriptProvider`, selected by **Match server words to speech timing (strict)**, preserves server word text only if every token agrees positionally after conservative normalization; it refuses insertion/deletion, tokenization or lexical mismatches and malformed timing instead of guessing or silently falling back. This is not arbitrary-speech forced alignment. Recognition requests Speech permission when selected and uses the device locale by default (configurable through `localeIdentifier`). Do not promise on-device-only processing: API/device capabilities determine behavior.

## How it works

| Piece | Where |
| --- | --- |
| The sheet (UI, gestures, selection, search, player) | [VoiceTranscriptScreen/Sources/VoiceTranscriptScreen.swift](VoiceTranscriptScreen/Sources/VoiceTranscriptScreen.swift) |
| Models and the provider protocol (`VoiceTranscriptProvider`) | [VoiceTranscriptScreen/Sources/VoiceTranscriptData.swift](VoiceTranscriptScreen/Sources/VoiceTranscriptData.swift) |
| Portable summary model, parser, validation, chunking and merge | [VoiceTranscriptScreen/Sources/VoiceSummaryCore.swift](VoiceTranscriptScreen/Sources/VoiceSummaryCore.swift) |
| Telegram's transcription plus approximate timing (default) | [VoiceTranscriptScreen/Sources/ServerVoiceTranscript.swift](VoiceTranscriptScreen/Sources/ServerVoiceTranscript.swift) |
| Optional Apple Speech provider (not guaranteed on-device-only) | [VoiceTranscriptScreen/Sources/VoiceTranscriptRecognition.swift](VoiceTranscriptScreen/Sources/VoiceTranscriptRecognition.swift) |
| Strict server-word/timing matching provider | [VoiceTranscriptScreen/Sources/VoiceTranscriptAlignment.swift](VoiceTranscriptScreen/Sources/VoiceTranscriptAlignment.swift) |
| Portable positional lexical matching and timing validation | [VoiceTranscriptScreen/Sources/VoiceTranscriptAlignmentCore.swift](VoiceTranscriptScreen/Sources/VoiceTranscriptAlignmentCore.swift) |

## Implementation architecture

The feature is a Telegram-iOS host module. The sheet consumes a `VoiceTranscriptProvider`; providers own transcript acquisition and summary generation, while the sheet coordinates playback, selection, navigation and presentation. Telegram server transcription is the default. Apple Speech is an explicit optional choice; a Telegram server failure does not silently send the recording to another service.

```mermaid
flowchart TD
	Bubble[Voice-message bubble or player header] --> Sheet[VoiceTranscriptScreen]
	Sheet --> Provider{Selected transcript provider}
	Provider -->|Default| RPC[Telegram messages.transcribeAudio]
	RPC --> Attribute[Message transcription attribute updates]
	Attribute --> ServerText[Transcript text plus estimated timing]
	Provider -->|User selects speech timing| Download[Download voice media]
	Download --> Convert[Convert Opus to AAC]
	Convert --> Plan[Plan overlapping windows under 45 seconds]
	Plan --> Speech[Sequential Apple Speech recognition]
	Speech --> Merge[Offset times and keep each window's owned interval]
	Merge --> MeasuredText[Transcript plus measured timing estimates]
	ServerText --> TranscriptUI[Transcript rows and synchronized player]
	MeasuredText --> TranscriptUI
	TranscriptUI --> Actions[Search, select, copy, translate, quote, seek]
	Sheet -->|Summary tab opened| Prompt[Timestamped transcript in bounded prompts]
	Prompt --> AI[Telegram composeAIMessage]
	AI --> Validate[Strict parse and source-time validation]
	Validate --> SummaryUI[Key points, tasks, questions and timestamp seeks]
```

The speech path uses overlapping audio windows so words near a cut retain context. All chunk timing is validated before ownership filtering; overlapping contexts must agree on words, timing and ownership or the transcript is rejected. Requests run sequentially. Temporary audio cleanup covers success, error and cancellation, including pending authorization; converted files remain retained until the cancelled writer drains. If conversion never terminates, cleanup cannot safely complete. Failure in any chunk rejects the whole local transcript rather than returning partial text. Strict speech timing has a chunk-scaled 90–900-second budget, separate from the 90-second server transcript wait. Actual recognition still depends on Apple Speech availability and has not been verified across devices/locales.

Message- and peer-level content protection is enforced fail closed for transcript acquisition, export and AI; host quote insertion rechecks it synchronously and asynchronously. The [dated review-fixes record](docs/BUILD_VALIDATION.md#follow-up-review-fixes--2026-10-22) lists the additional retry, prompt and parser fixes. Task text in UserDefaults remains a known privacy gate.

AI Summary is requested only when the user opens the Summary tab. Timestamped transcript lines are split losslessly into bounded prompts, sent sequentially to Telegram AI, then strictly parsed and checked against source timestamps. Failed or malformed output makes the summary unavailable; real providers do not substitute sample content. These checks validate structure and allowed timestamps, not factual accuracy.

Search highlighting is visual only. Text selection has a separate word-range model and action menu. **Copy** copies selected text, **Copy Search Query** copies the active query, and **Copy Transcript** copies all transcript text when neither is active. Quote/reply wiring lives in the host patch: it prepares an editable timestamped blockquote in the compose body plus an ordinary reply relationship; recipient behavior still requires separate verification.

`VoiceTranscriptProvider` is the sheet's content interface. `ServerVoiceTranscriptProvider` remains the default; `RecognizedVoiceTranscriptProvider` supplies optional recognition text/times, and `AlignedVoiceTranscriptProvider` supplies optional strictly matched server words with recognition times. Explicit demo providers are not production fallbacks.

## Changes outside the module

Use the [combined host patch](Integration/telegram-ios-f1dd7a2.patch), [manifest](Integration/host-manifest.json) and [installer](Scripts/integrate-telegram.mjs) for the pinned official host. The patch covers **18 tracked host files plus one new host source**, combining the original integration with direct bubble access and editable quoted-body replies. The module is installed separately, not embedded in the patch. Host source references below link to the local patch, not nonexistent host files in this feature repository.

| Host area (see patch) | Change |
| --- | --- |
| [Playback header and voice-bubble actions](Integration/telegram-ios-f1dd7a2.patch) | Header entry retained; voice transcription button opens the sheet directly. |
| [Account context and shared implementation](Integration/telegram-ios-f1dd7a2.patch) | `makeVoiceTranscriptScreen` factory and host dependency wiring. |
| [Reply state, controller and accessory panel](Integration/telegram-ios-f1dd7a2.patch) | `VoiceReplyFragment`, local time chip, shared reply setup, editable body blockquote preserving existing `ChatInputContent` blocks and adjusted selection. |
| [Media player and local transcription](Integration/telegram-ios-f1dd7a2.patch) | Audio-only seek packet filtering, recognition word times, and retained `setSoundMuted` control action (unused by this sheet). |
| [Translation and localization](Integration/telegram-ios-f1dd7a2.patch) | Translation info-button option, English transcript keys and debug AI error capture; logging/localization review still required. |

## Trying it

This is a Telegram-iOS integration, not a standalone app. Follow the [host integration guide](docs/HOST_INTEGRATION.md) for read-only checks and explicit installation. The official host is pinned to `f1dd7a2dbd02cbbf513e75d5695d8d36d1cf5838`. The earlier source audit recorded the combined patch applied and **8 module files** present: **5 byte-identical**, **3 terminal-LF-normalized**, **0 missing**; normalized files are not rewritten. This historical audit is not a current pass: Bazel's generated host lockfile has **139 added lines**, correctly rejected by the strict installer. The obsolete host-local task file was deleted; tasks live in the feature repository.

**Earlier build and smoke evidence (2026-10-22):** the initial full `//Telegram:Telegram` Debug `sim_arm64` build **succeeded**, including feature UI module emission and whole-app linking, before the follow-up review fixes. The live simulator showed a Telegram transcript and AI Summary for an 8-second message after Premium activation; after adding chunked speech recognition, a user-provided screenshot showed an AI Summary from a 1:01 voice message. One selected-word seek was also manually checked. These are successful smoke tests, not broad accuracy or release certification. The [feature build task](.vscode/tasks.json) uses a canonical Xcode 26.6 installation, isolated Bazel output base, no disk-cache option, and `XCODE_VERSION_OVERRIDE` in both target and host action environments. TLS and header validation remain enabled. See [build setup](docs/HOST_INTEGRATION.md#build-prerequisites-and-compile-only-snapshot).

The compile-only IPA startup check reached onboarding without logging in. Separately, a signed-in Premium simulator session exercised live transcription and summary. Do not confuse the onboarding screenshot below with feature evidence.

![Fresh Debug simulator startup: Telegram / Start Messaging onboarding only](screenshots/simulator-compile-only-startup.png)

The [simulator compile-only example](Integration/simulator-compile-only.example.json) deliberately uses dummy zero API values that **cannot log in**. It is a safe template, not production credentials or evidence of live transcript, summary, send/recipient or login tests. Keep real credentials only in the ignored `Integration/local-development.json` file. The manifest still pins macOS **26** and Bazel **9.2.0** with its hash; real configuration and signing remain separate release prerequisites.

After building and installing a host app, verify both entry points, strict-mode refusal and a normal quoted-body reply send to a second account. Default/strict server transcript modes need Premium or an available free trial. Earlier screenshots are illustrative, not runtime evidence for this integration.

## Validation

The [Swift package](Package.swift) builds only the Foundation-based summary and alignment cores, not the iOS sheet or Telegram integration. The **Validate Telegram feature core** VS Code task builds the package, runs both smoke executables and Node installer tests, syntax-parses module sources, and checks whitespace; it does not run XCTest or build Telegram. The separate feature-workspace build task builds the full host using the pre-resolved compile-only configuration.

Current results (2026-10-22): **36 XCTest cases passed with zero failures**, **526 summary smoke assertions**, **59 alignment checks**, and **18 Node fixture tests passed / 1 real-host audit skipped**. The core validation task passed. The final full host Debug simulator app build **passed after all source changes (77.927 seconds, 24 actions)**. Earlier live simulator smoke tests confirmed Telegram transcription + AI Summary for a short message, and a user-provided screenshot showed a summary for a 1:01 message after chunked speech recognition was added. No signed-in runtime testing was performed after the final changes; protection and cleanup have code-test/static-check and full-build evidence only. These results do not establish broad acoustic accuracy, recipient behavior, Release/device readiness or production certification. No CI execution is claimed. See [verification scope](docs/PRODUCTION_READINESS.md).

Install all **8 module files** (Bazel definition plus seven Swift sources), including both alignment files and the summary core. The Bazel source glob includes them. Do not apply either host patch to this feature repository; use only the combined pinned-host patch through the documented installer workflow.

# Seam.app 1.14.7 — mechanism analysis for a personal SwiftUI clone

Target: `/Applications/Seam.app` (bundle id `app.seam.Seam`, team `R8Q6V6H2KC` / UpSys LLC), analysed 2026-09-11 on macOS 26.x, Apple M5 Pro, built-in Liquid Retina XDR 3456×2234 (notch).

Everything below is derived from static inspection (strings, plists, entitlements, `assetutil`, on-disk state, `lsof`, `log show`). **No code or assets were copied.** Lines marked *(inference)* are my reading of the evidence, not literal strings.

Raw artifacts saved next to this file:

| File | Content |
|---|---|
| `seam-binary-strings.txt` | full `strings -n 5` of the main binary (20 042 lines) |
| `ui-strings.txt` | 491 human-readable UI strings extracted from the binary |
| `settings-keys.txt` | the contiguous UserDefaults key table lifted from the binary |
| `swift-files.txt` | 191 Swift source file names |
| `defaults-app.seam.Seam.txt` | `defaults read app.seam.Seam` |
| `en.lproj-Localizable.strings.xml` | the (tiny) English `.strings` file |
| `assets-car-info.json` | `assetutil -I` of `Assets.car` |

---

## 0. Bundle facts, frameworks, permissions

**Info.plist highlights**

- `LSUIElement = true` (agent, no Dock icon), `LSMinimumSystemVersion = 14.0`, built with macOS 26.5 SDK / Xcode 26.6.
- URL scheme `seam://` (`CFBundleURLTypes`).
- ATS exceptions for two plain-HTTP radio hosts (`mscp3.live-streams.nl`, `radio.linn.co.uk`).
- Usage strings (exact wording — these are the TCC prompts the user sees):
  - `NSMicrophoneUsageDescription`: "Seam needs microphone access to record your voice for transcription."
  - `NSBluetoothAlwaysUsageDescription`: "Seam shows a notification when your headphones connect."
  - `NSCalendarsFullAccessUsageDescription`, `NSLocationUsageDescription` / `WhenInUse`, `NSAppleEventsUsageDescription` ("…focus the browser tab playing your music…").
  - **No `NSSpeechRecognition`, no Screen Recording usage string** — nothing captures the screen.

**Entitlements** (main app; *not* sandboxed — there is no `com.apple.security.app-sandbox`):

```
com.apple.application-identifier          R8Q6V6H2KC.app.seam.Seam
com.apple.developer.team-identifier       R8Q6V6H2KC
com.apple.developer.ubiquity-kvstore-identifier  R8Q6V6H2KC.app.seam.Seam   ← iCloud KVS settings sync
com.apple.developer.weatherkit            true
com.apple.security.automation.apple-events true
com.apple.security.device.audio-input     true
com.apple.security.personal-information.calendars / .location
com.apple.security.temporary-exception.apple-events → Safari, Chrome, Firefox,
    Brave, Edge, Arc (company.thebrowser.Browser), Dia, Comet
```

**Linked frameworks** (from the load commands; `otool` was unavailable, extracted with `tr`):

AppKit, SwiftUI, Combine, Observation, QuartzCore, CoreGraphics, CoreImage, ColorSync,
CoreAudio, AVFoundation/AVFAudio/AVKit, CoreMedia, Accelerate (vDSP),
**CoreBluetooth + IOBluetooth + IOKit**, CoreLocation, MapKit, **WeatherKit**, EventKit,
**CoreML**, NaturalLanguage, **Translation + _Translation_SwiftUI**,
**QuickLookThumbnailing**, ServiceManagement (login item), Security + CryptoKit,
WebKit (YouTube player), Carbon (hotkeys), CoreDisplay + PrivateFrameworks/DisplayServices
(brightness), `libsqlite3` (Cursor's `state.vscdb`).

Note: **MediaRemote is *not* linked by the main app** — only by the XPC helper (see §1).

**Privacy manifest** declares only UserDefaults / file-timestamp / boot-time API use and DeviceID + ProductInteraction + diagnostics collected for analytics (Swetrix, self-hosted at `https://swetrix.upsys-consulting.com/backend/v1`, install id in `swetrixInstallID`).

**Permissions the clone will need**

| Permission | Needed for | How it's requested |
|---|---|---|
| Accessibility (AXIsProcessTrustedWithOptions, `AXTrustedCheckOptionPrompt`) | voice text insertion, hiding native volume/brightness HUD, the output-cycle shortcut | deep link `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` |
| Microphone | voice transcription | `x-apple.systempreferences:…?Privacy_Microphone` |
| Bluetooth | device-connection toasts | `NSBluetoothAlwaysUsageDescription` |
| Calendars (full access) | calendar feature |  |
| Location | weather |  |
| Apple Events (per-browser) | "jump to browser tab" |  |
| *None* for Screen Recording | — | app explicitly has a "Display in screenshots" (`showInScreenCapture`) toggle instead, i.e. it controls `NSWindow.sharingType` |

**Launch at login**: ServiceManagement (`SMAppService`), **not** a LaunchAgent plist — `~/Library/LaunchAgents` contains nothing Seam-related.

---

## 1. Music (Now Playing)

### Mechanism

`SeamHelper.xpc` (bundle id **`com.apple.controlcenter.SeamHelper`**, `XPCService.ServiceType = Application`, not sandboxed, 136 KB) is the only component that links
`/System/Library/PrivateFrameworks/MediaRemote.framework`. The faked `com.apple.controlcenter.*` bundle id is what gets past the macOS 15.4+ MediaRemote entitlement check.

Private symbols it imports:

```
MRMediaRemoteGetNowPlayingInfo
MRMediaRemoteGetNowPlayingApplicationIsPlaying
MRMediaRemoteGetNowPlayingClient
MRMediaRemoteGetSupportedCommands
MRMediaRemoteRegisterForNowPlayingNotifications / Unregister…
MRMediaRemoteSendCommand
MRMediaRemoteSetElapsedTime
MRNowPlayingClientGetBundleIdentifier
MRNowPlayingClientGetParentAppBundleIdentifier

kMRMediaRemoteNowPlayingInfoDidChangeNotification
kMRMediaRemoteNowPlayingApplicationDidChangeNotification
kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification
kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey
kMRMediaRemoteNowPlayingApplicationDisplayNameUserInfoKey
```

Info keys read: `Title, Artist, Album, ArtworkData, ArtworkIdentifier, Duration, ElapsedTime, PlaybackRate, MediaType`.

### XPC contract (recovered from ObjC metadata)

- `SeamHelperProtocol` (app → helper): `startMonitoring`, `stopMonitoring`, `requestFullState`, `play`, `pause`, `togglePlayPause`, `nextTrack`, `previousTrack`, `seekToPosition:`
- `SeamClientProtocol` (helper → app): `playbackStateDidChange:` (NSDictionary), `artworkDidChange:identifier:` (NSData + NSString)
- `ServiceDelegate` implements `listener:shouldAcceptNewConnection:`; `HelperService.swift` is the whole implementation.

### Helper policy objects — worth copying the *shape* of

`DebouncePolicy`, `DedupPolicy`, `AppFilterPolicy`, `ArtworkSendPolicy`, `InfoCompletenessPolicy`, `MemoryBudgetPolicy`, plus `ExtractedInfo` / `TrackIdentity`.

Tunables (names only; values are compiled-in constants):
`normalDebounceMs`, `skipDebounceMs`, `skipGracePeriodMs`, `skipCommandTime`,
`driftThresholdSeconds`, `minimumFlushIntervalSecs`, `footprintFlushThresholdBytes`,
`memoryBudget` (backed by a `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source),
`ignoredBundlePrefixes`, `fetchEpoch`, `reregistrationTimer`, `infoChangeDebounceTimer`,
dedup state `lastSentArtworkID / lastSentElapsed / lastSentIsPlaying / lastTrackIdentity`,
`cachedBundleID / cachedIsPlaying / cachedCanSkipNext / cachedCanSkipPrevious`.

*(inference)* The design: MediaRemote fires far too often, so the helper (a) debounces info changes, (b) suppresses a re-send unless title/artist/album identity, artwork id, isPlaying or elapsed-drift-beyond-threshold actually changed, (c) sends artwork only when its `ArtworkIdentifier` changes, (d) uses a shorter debounce during a skip burst plus a grace window after issuing a skip command so the UI doesn't flicker back to the old track, (e) re-registers for notifications on a timer because MediaRemote registrations silently die, and (f) flushes its artwork cache under memory pressure.

### App side

`MusicManager.swift`, `MusicConfig.swift`, `MusicView / MusicExpandedView / MediaSourceCard`, `ArtworkPipeline.swift`, `DominantColorExtractor.swift` (accent colour from artwork), `PlaybackProgressTracker.swift` (local interpolation of elapsed between XPC updates: `lastSyncTime`, `lastPosition`, `progressTimer`, states `stopped/playing/paused`), `MarqueeText.swift` (`NSMarqueeTextView`, animates `transform.translation.x` and `filters.textBlur.inputRadius` for edge fade), `MediaKeyInterceptor.swift`, `YouTubeWebPlayer.swift` (WKWebView + YouTube iframe API), `BrowserTabFocuser.swift`.

Known media bundle ids in `MusicConfig`: `com.apple.Music`, `com.spotify.client`, `com.apple.podcasts`, `com.tidal.desktop`, `com.amazon.music`, `org.mozilla.firefox`, `com.apple.WebKit.GPU`, `com.apple.WebKit.Networking`, `com.apple.QuickTimePlayerX`, `org.videolan.vlc`, `com.colliderli.iina`. Display names: "Apple Music", "Amazon Music".

`BrowserTabFocuser` runs an AppleScript that walks every window/tab of the browser, matches the tab title against the track title, and activates it (this is what the per-browser Apple Events exceptions are for). Supported: Safari, Chrome, Brave, Edge, Firefox, Arc, Dia, Comet.

### UI labels / settings (Now Playing pane)

`Now Playing activity` · `Show Now Playing` · `Show peek when song changes` · `Scroll song titles` ·
`Track change animation` · `Swipe left or right to change tracks` · `Reverse swipe direction` ·
`Show last track even when paused` · `Display when on media window` / `Show overlay when media app is focused` ·
`Jump to browser tab` / `Open the now playing tab` · `Output device picker` / `Show output switching in the expanded player` ·
`No output devices available` · feature blurb `See what's playing and control your music.`

Keys: `nowPlayingEnabled, nowPlayingScrolling, nowPlayingSource, nowPlayingTrackChangeAnimation, nowPlayingBrowserTabFocus, nowPlayingShowOnMediaApp, nowPlayingSwipeEnabled, nowPlayingSwipeReversed, nowPlayingOutputDevicePicker, musicShowWhenIdle` (an older spelling `musicShowInStackWhenIdle` also appears).

### Open questions

- Exact debounce values (ms) — not recoverable from strings; would need disassembly.
- Whether the helper is launched as a bundled `NSXPCConnection(serviceName:)` XPC service or registered separately. The `XPCService` dict says `ServiceType = Application`, and `lsof` shows the helper holding **no** files and **no** sockets, so it is a plain bundled XPC service launched on demand. `XPCManager.swift` handles reconnect (`maxReconnectAttempts`, `reconnectAttempts`, error `XPC reconnect exhausted after `, signpost `xpc.reconnect_exhausted`).

---

## 2. Voice transcription + translation

### Model & download

- Engine: **NVIDIA Parakeet TDT 0.6B v3**, CoreML, via the open-source **FluidAudio** Swift package (the on-disk layout is FluidAudio's, and `config.json` in the model dir literally references `github.com/FluidInference/FluidAudio/issues/760`). Seam's own wrapper/library names in the binary are `SwiftVibeTranscription` / `SwiftVibeUtils` / `SwiftVibeKit`.
- **CDN**: `https://pub-e4338d0560d1449f9f21bdbb7e254df4.r2.dev/` (Cloudflare R2), manifest at `…/latest/metadata.json`. Live contents of that manifest today:

```json
{ "version": "v3", "totalSize": 478244973,
  "files": [
    {"name":"Preprocessor.mlmodelc.tar.gz",   "size":    196106, "sha256":"7a2b50…"},
    {"name":"Encoder.mlmodelc.tar.gz",        "size": 432939145, "sha256":"7b8f9d…"},
    {"name":"Decoder.mlmodelc.tar.gz",        "size":  21826062, "sha256":"30a275…"},
    {"name":"JointDecision.mlmodelc.tar.gz",  "size":  11566269, "sha256":"501ffd…"},
    {"name":"JointDecisionv3.mlmodelc.tar.gz","size":  11566524, "sha256":"c1da2e…"},
    {"name":"parakeet_vocab.json",            "size":    151122, "sha256":"7ec60e…"}
  ],
  "minAppVersion":"1.0.0",
  "releaseNotes":"Parakeet TDT v3 with JointDecisionv3 (top-K outputs) for script-aware decoding" }
```

  So: **~456 MB compressed download, ~461 MB on disk**; the app's own copy says `~500 Mo storage / ~200 Mo RAM`. Each file is a gzipped tarball with a sha256 that the app verifies (`Checksum verification failed for `, `Download size mismatch: got %ld, expected %ld`, `Download failed, retry %ld/%ld`).
- **Lands at** `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/` — verified on this machine: `Encoder.mlmodelc`, `Decoder.mlmodelc`, `JointDecisionv3.mlmodelc`, `Preprocessor.mlmodelc`, `parakeet_vocab.json`, `parakeet_v3_vocab.json`, `config.json`; **461 MB**. A sibling `…-v3-coreml/` (with `JointDecision.mlmodelc`, same 461 MB) also exists, plus `silero-vad` / `silero-vad-coreml` at 1 MB each — so a **Silero VAD** CoreML model is used for endpointing too.
- Download state keys: `voiceModelInstalledVersion` / `voice_model_installed_version`, `voiceModelDownloadInProgress` / `voice_model_download_in_progress`, `voiceModelLastUpdateCheck`. Logger category `voice.modelDownload`. `ModelUpdateChecker` polls the manifest.
- Gating: **Apple Silicon only** — `Requires Apple Silicon (M1 or later)`, `Voice transcription requires Apple Silicon (M1 or later).`
- Resume-on-relaunch UX: `Download in Progress` / `Seam is downloading the transcription model. The download will continue automatically next time you open the app.` / `Continue Download`.
- Deletion is guarded: `Model deletion requires an explicit user-initiated authorization token.` (`pendingModelDeletionAuthorization`).

### Audio capture

`AudioCaptureBackend.swift` / `AudioCapturePipeline.swift` / `AudioEngineSession.swift` — `AVCaptureSession` backend (`AVCaptureSessionBackend`, `CaptureAudioDelegate`, `captureOutput:didOutputSampleBuffer:fromConnection:`) plus an AVAudioEngine path; session id `app.seam.voice.capture-session`. 16 kHz mono is required (`Invalid audio data provided. Must be at least 1 second of 16kHz audio.`). `AudioDucker.swift` / `ExternalMusicDucker.swift` duck other audio while recording (`voiceAudioDuckMode`, levels `subtle / balanced / strong`). `AudioVisualizerView` / `VoiceWaveformView` / `VoiceOrbView` use `vDSP` FFT (`vDSP_create_fftsetup failed for log2n=`).

Microphone selection: `VoiceMicrophoneSection` with a **ranked** list — `Seam records from the highest-ranked microphone that is connected.` (`voiceInputRanking` / `voice_input_ranking`), transports tagged `continuity-wireless` / `continuity-wired`.

### Inference

`TranscriberEngine.swift` drives the four CoreML models directly (`Preprocessor → Encoder → Decoder → JointDecision`), doing its own TDT loop — the error strings expose the tensor contract: `encoder_step`, `token_id`, `token_prob`, `duration`, `top_k_ids`, `top_k_logits`, `durationBins`, `tokenDurations`, `Token, timestamp, and confidence arrays are misaligned`, `Joint decision returned unexpected tensor shapes`, `Decoder projection hidden size mismatch`. `VocabularyValidator` checks `parakeet_vocab.json`.

### Text cleanup pipeline (a surprisingly large part of the feature)

Toggle-per-stage, all multilingual (regex tables for EN/FR/DE/ES/PT at least):

| Setting key | Label | Sublabel |
|---|---|---|
| `voiceNormalizeSpokenNumbers` | `Normalize numbers` | |
| `voiceNormalizePunctuation` | `Punctuation dictation` | (maps "comma", "question mark", "point d'exclamation", "auslassungspunkte", …) |
| `voiceRemoveFillerWords` | `Remove filler words` | (`um I think uh so`) |
| `voiceRemoveRepeatedPhrases` | | (`\b(\w+)\b(?:\s+\1\b)+`, `we we should go now`) |
| `voiceApplyIntentCorrections` | `Intent corrections` | ("what I meant", "let me rephrase", "change that to", "je voulais dire", "nein eigentlich", … → rewrite; demo string `send it Monday no wait Tuesday`) |
| `voiceFitToSentence` | | sentence-boundary fit |
| `voiceUseCustomDictionary` / `voiceCustomDictionary` | `Custom Replacements` / `Custom dictionary` | `Case-insensitive trigger-to-text replacements` |
| `voiceLearnCorrections` / `voiceLearnedDictionary` | `Learn from corrections` / `Learned Replacements` | `Adds words you correct after dictating` — `CorrectionObserver.swift` watches the focused field via AX (`AXFocusedUIElement`, `AXSelectedTextRange`, `AXPlaceholderValue`, `AXSecureTextField`, `FocusedFieldReader`) and diffs what the user edited |
| `voiceNormalizationLanguages` | | `Tells Seam which languages to expect. Spoken numbers and punctuation are converted for the ones that have rules.` |

`VoiceCleanupDemo.swift` renders a live before/after preview (`Point at a setting to see what it does.`).

### Insertion into the frontmost app

`voiceOutputMode` ∈ `inputDirectly | copyToClipboard | inputAndCopy`. Strategy, in order, with fallbacks logged:

1. Pasteboard write + synthetic **Cmd+V** `CGEvent` → `Paste insertion (`, failures `Paste failed: CGEvent create for Cmd+V returned nil`, `Paste failed: the pasteboard write returned false`.
2. **Unicode keystrokes** (`CGEventKeyboardSetUnicodeString`) → `Unicode keystroke insertion (`, `Unicode keystroke failed: CGEvent create returned nil`.
3. Give up → `All insertion paths failed; transcript copied to clipboard`, `No Accessibility permission; transcript copied to clipboard`, `Text copied to clipboard (`.

Clipboard etiquette: `voiceRestoreClipboard` / `Restore Clipboard` — *"Puts back what you had copied a second later, leaving the dictation just under it in your clipboard history."* Guarded by `pasteboardChangeCountOnMouseDown` and `Clipboard changed since the dictation; left alone`, `Clipboard restored (`, `Copy left on the clipboard (`. It also writes the `org.nspasteboard.TransientType` / `ConcealedType` / `AutoGeneratedType` markers so clipboard managers behave.

### Activation

`voiceActivationMode` ∈ `holdToRecord | toggleRecording` — `Hold to record, release to transcribe.` / `Press to record, press again to stop.`
`voiceModifierKey` / `featureShortcutModifierKey` ∈ `command, optionLeft, commandLeft, controlRight, shiftRight` (+ Fn): `Hold Fn, Left Option, Left Command, Right Control, or Right Shift.`
Global shortcut layer: `Shortcuts combine this modifier with Shift and a letter.` — `ModifierKeyMonitor.swift`, `FeatureHotkeyMonitor.swift`, `ShortcutRecorder.swift`, `ShortcutKeycaps.swift`, chord keys `shortcutChordFlow / FlowMusic / NowPlaying / Calendar / Weather / ClaudeUsage / CodexUsage / CursorUsage / AudioOutputCycle`.

Signposts / metric names: `VoiceRoundTrip`, `VoiceTranscribe`, `VoiceInsert`, `VoiceTranslate`.

Error toasts: `No audio detected. Check your microphone.`, `No audio recorded.`, `Transcription failed. Try again.`, `Voice session cancelled.`, `Microphone changed. Try again.`, `Selected microphone is unavailable.`, `Couldn't start recording. Check microphone access and try again.`, `Model not downloaded. Open Settings to download.`, `Model is downloading`.

### Translation

`TranslationService.swift` + `TranslationPillView.swift` + `TranslationSettingsSection.swift`, on Apple's **Translation.framework** (`_Translation_SwiftUI` also linked). `performBridgeTranslation(_:source:target:)` *(inference: pivot through a bridge language when a direct pair isn't installed)*.

- UX: `Translation Shortcuts` — `Press your voice key + a letter to transcribe and translate.`, per-mapping label `… to transcribe and translate to <language>`.
- Mappings persisted in `voiceTranslationMappings` / `voice_translation_mappings`; source language in `voiceTranslationSourceLanguage`; change notification `translationMappingsDidChange`.
- Language packs are *not* downloadable in-app: `Open Translate app to download ` + it opens `/System/Applications/Translate.app`.
- Flag art in `Assets.car`: `Flags/flag-{br,cn,de,es,fr,gb,id,in,it,jp,kr,nl,pl,pt,ru,sa,th,tr,tw,ua,vn}` plus rectangular variants `Flags/flag-rect-{bg,by,de,es,fr,gb,pt,rs,ru,ua}`. Language display names include `Chinese (Simplified)`, `Chinese (Traditional)`, `Portuguese (Brazil)`.

### Open questions

- Whether Silero VAD gates recording start/stop or only trims silence.
- Whether translation runs on-device only (the Translation.framework path implies yes when packs are installed).

---

## 3. Coding-agent activity & usage

### Activity events (live "agent is working" pill)

Installers write a shell shim and register it:

| Agent | Installer | Config touched | Hook script | Notification |
|---|---|---|---|---|
| Claude Code | `ClaudeCodeInstaller.swift` | `~/.claude/settings.json` | `~/.seam/hooks/seam-claude-code.sh` | `app.seam.claudecode.event` |
| Codex | `CodexInstaller.swift` | `~/.codex/config.toml` (block delimited by `# === managed by Seam.app - code event hooks (begin/end) ===`) | `~/.seam/hooks/seam-codex-hook.sh` (+ legacy `seam-codex-notify.sh`) | `app.seam.codex.event` |
| Cursor | `CursorInstaller.swift` | `~/.cursor/hooks.json` | `~/.seam/hooks/seam-cursor-hook.sh` | `app.seam.cursor.event` |

The scripts are embedded verbatim in the binary. Each is `#!/bin/bash`, reads the hook JSON from **stdin** into an env var, then shells out to `/usr/bin/osascript -l JavaScript` which does `ObjC.import("Foundation")` and calls
`NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(name, "seam", info, true)`.
Every script ends `>/dev/null 2>&1 || true; exit 0` with the comment *"MUST NEVER block Claude Code / Codex / Cursor"* — Cursor's adds *"Cursor waits on this script before continuing its agent loop"*.

`userInfo` keys: `stage`, `message` (the tool name), `sessionID`, `sourceApp` (taken from `$TERM_PROGRAM` for Claude Code; hard-coded `"cursor"` for Cursor).

**Stage mapping** (exact, from the embedded scripts):

*Claude Code* — `UserPromptSubmit → thinking`; `PreToolUse`: `Edit|Write|MultiEdit|Bash → writing`, `Read|Grep|Glob|Agent|Explore → analyzing`, else `thinking`; `PostToolUse → thinking` (explicitly *"keeps the activity alive between tool calls"*); `Stop → completed`.

*Codex* — handles both legacy `notify` (payload in `$1`) and new `[hooks]` (stdin). `apply_patch|shell → writing`; `read_file|view_image → analyzing`; `Stop` **or** `agent-turn-complete → completed`.

*Cursor* — `beforeSubmitPrompt → thinking`; `afterFileEdit → writing`; `preToolUse`: `Shell|Edit|Write|MultiEdit|apply_patch → writing`, `Read|Search|Grep|Glob|List|Codebase → analyzing`; `postToolUse → thinking`; `stop → input.status === "error" ? failed : completed` (an aborted turn counts as completed, not failed).

Codex TOML block registers `[[hooks.UserPromptSubmit]] / [[hooks.PreToolUse]] (matcher "*") / [[hooks.PostToolUse]] (matcher "*") / [[hooks.Stop]]` with `type = "command"` and sets `[features] hooks = true`.

Internal stage enum in the app: `analyzing, thinking, creating, posting, completed, failed` (note `creating` ≈ the scripts' `writing`). Agent enum: `claudeCode, codex, cursor`.

Terminal/editor bundle ids it recognises as "a code window" (for `codeEventsShowOnCodeApp`):
`com.apple.Terminal`, `com.googlecode.iterm2`, `dev.warp.Warp-Stable`, `com.mitchellh.ghostty`, `com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92` (Cursor).

### Usage / quota

- **Claude**: OAuth token from Keychain via `/usr/bin/security find-generic-password` on item **`Claude Code-credentials`**, then `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`. Parses `five_hour`, `seven_day`, `utilization`, `resets_at`. Class `ClaudeOAuthQuotaProbe`. Errors: `No OAuth token in Keychain`, `OAuth usage API returned `. CLI discovered at `/usr/local/bin/claude` or `/opt/homebrew/bin/claude`; UA `claude-code/unknown`.
- **Claude local token history**: scans `~/.claude/projects/**/*.jsonl` and caches into
  **`~/Library/Application Support/Seam/claude-usage-cache-v2.json`** (v1 name `claude-usage-cache.json` also present in the binary). Verified format on disk:
  ```json
  { "/Users/…/.claude/projects/<slug>/<session-uuid>.jsonl":
      { "modDate": 810833335.09, "buckets": { "2026-09-11-13": 487564, "2026-09-11-14": 115976 } } }
  ```
  i.e. per-file mtime + hourly token buckets keyed `YYYY-MM-DD-HH`. This feeds the sparkline/"pace" indicator.
- **Codex**, two probes:
  - `CodexLocalQuotaProbe.swift` — SQLite over the Codex session logs (`~/.codex/sessions`, also `codex-accounts/*/home`, `codex-runtime-home/home`): `PRAGMA table_info(logs)`, then `SELECT … FROM logs WHERE <col> LIKE '%"type":"codex.rate_limits"%' ORDER BY id DESC LIMIT 20`; fields `windowDurationMins`, `last_token_usage`. Errors: `No rate-limit records in any Codex home`, `No Codex home found`.
  - `CodexRPCQuotaProbe.swift` — launches the `codex` CLI (`/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, `~/.local/bin/codex`) as a JSON-RPC **app-server** and speaks:
    ```
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Seam","version":"1.0.0"}}}
    {"jsonrpc":"2.0","method":"initialized","params":{}}
    {"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}
    ```
    Errors: `codex app-server closed before answering`, `rate-limit response had no rateLimits payload`.
- **Cursor**: token from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` via `/usr/bin/sqlite3` —
  `SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';` — sent as cookie `WorkosCursorSessionToken=` to `https://cursor.com` endpoints `/api/usage-summary` (fields `ondemandlimitcents`, `totalpercentused`), `/api/usage?user=` (legacy), `/api/dashboard/get-filtered-usage-events` (parsed by `CursorUsageEventsParser.swift`). Errors: `No Cursor session, sign in to the Cursor app`, `Cursor rejected the stored session`, `Cursor not installed`.
- `UsageRefreshCoordinator.swift` schedules refreshes; `UsageSources.swift` holds source ids `claude`, `cursor-usage-summary`, `cursor-usage-legacy`.

### "Caffeinate agent"

Menu items `Caffeinate Agent` / `Stop Caffeinating Agent`; strings `Keep your Mac awake while agents work`, `Your Mac stays awake while agents work`, `Seam is keeping coding agents awake`, `Inserted new assertion` / `system assertion` / `user-initiated assertion` — IOKit power assertions. `codeEventsCaffeineDance` → `Agent icon sways and shifts colors while your Mac is held awake`.

### Settings keys + labels

```
codeEventsEnabled                 Show code agent activity in Surface / Show code events
codeEventsClaudeCodeEnabled / codeEventsCodexEnabled / codeEventsCursorEnabled
codeEventsShowInfo
codeEventsCompactStyle
codeEventsShowOnCodeApp           Display when on code window / Show overlay when code app is focused
codeEventsShowAnalyzing / ShowThinking / ShowCreating          (per-agent variants for Codex + Cursor)
codeEventsClaudeCodeShowWhenIdle / CodexShowWhenIdle / CursorShowWhenIdle   Display usage when idle
codeEventsPlayCompleteSound       Completion sound / Play a chime when a session completes  (seam-code-complete.caf)
codeEventsShowPace                Show pace indicator on usage bars
codeEventsCaffeineDance
```
Other labels: `Claude Code Event`, `Claude Code Usage`, `Show Claude Usage` / `Show Codex Usage` / `Show Cursor Usage`, `Receive alerts when code completed`, `Alerts may increase energy usage when running multiple code sessions.`, `Use Claude Code or Codex to see usage`, `No coding activity yet`, `See live activity when Claude Code or Codex are working.`
Icons in `Assets.car`: `ClaudeCodeIcon`, `CodexIcon`, `CursorIcon`.

### Open question

- Whether the app watches `~/.claude/settings.json` for user edits and re-installs the hook, or only installs on toggle. `ClaudeCodeInstaller` references `UserPromptSubmit` and `.claude/settings.json` directly; no file-watcher strings found.

---

## 4. Drop Zones (file stash)

### Mechanism

- **Detecting a drag anywhere on the system**: `DragObserver.swift` (`DragSession`, `isContentDragging`, `_draggingUID`) using a global `NSEvent` monitor (`addGlobalMonitorForEventsMatchingMask:handler:`) and an `eventTap`. There is a special case for `org.chromium.chromium-initiated-drag` (Chrome's private pasteboard type) — without it Chrome drags are invisible to a normal observer.
- **Catching the drop**: `DropCatcherWindow.swift` — a borderless `NSWindow` (`init(contentRect:styleMask:backing:defer:)`) that registers `registerForDraggedTypes:` and implements the full `NSDraggingDestination` set (`draggingEntered:`, `draggingUpdated:`, `draggingExited:`, plus `readableDraggedTypes`). It is shown only while a drag is in flight (`Show zones when dragging files`).
- **Dragging back out**: `DraggableStashView.swift` + `StashDragItemProvider.swift` implement `NSDraggingSource` (`beginDraggingSessionWithItems:event:source:`, `draggingSession:willBeginAtPoint:`, `movedToPoint:`, `endedAtPoint:operation:`, `sourceOperationMaskForDraggingContext:`, `setDraggingFrame:contents:`) **and `NSFilePromiseProviderDelegate`** (`StashFilePromiseDelegate`: `filePromiseProvider:fileNameForType:`, `writePromiseToURL:completionHandler:`, `operationQueueForFilePromiseProvider:`). File promises are what let you drag into Mail/Finder without materialising the file first.
- **AirDrop**: plain `NSSharingService` — `sharingServiceNamed:` (i.e. `NSSharingServiceNameSendViaAirDrop`), asset `AirDropIcon`.
- **Thumbnails**: **QuickLookThumbnailing** — `QLThumbnailRepresentation` appears in a block signature; `ThumbnailManager.swift`, `DropzonesThumbnailView.swift`, `FileThumbnailView`, `StackedThumbnails.swift` / `FileStackView.swift` (a fanned card stack with per-item `rotations`, `scales`, `depthOffsets`, `rotationSpread`, `cornerRadius`, `thumbSize`, `ThumbnailStackTokens`, `ThumbnailCardStyle`).

### On-disk state

- **No security-scoped bookmarks.** Zero `bookmark` strings anywhere in the binary — because the app is **not sandboxed**, so it keeps plain file URLs.
- Stash index lives in **UserDefaults** under `stashedFilesData` (+ `stashTimestamp`). *(inference: a JSON/plist blob of `sourceURL` + added-at; the in-memory model has `files`, `fileURL`, `sourceURL`, `stashedFiles`, `stashedFilesData`, `stashTimestamp`.)* Nothing is written to `~/Library/Application Support/Seam/` for the stash — that directory contains only `claude-usage-cache-v2.json`.
- A staging directory string exists: **`app.seam/DragStaging`** — *(inference: `NSTemporaryDirectory()/app.seam/DragStaging` or the per-user caches container `/private/var/folders/…/C/app.seam.Seam`; used to materialise file promises when dragging out. The per-user caches dir `/private/var/folders/…/C/app.seam.Seam` does exist but currently holds only Metal shader caches.)*
- `~/Library/Caches/app.seam.Seam/` holds only `Cache.db` (URLSession HTTP cache); `~/Library/HTTPStorages/app.seam.Seam/httpstorages.sqlite` holds cookies. There is **no** `~/Library/Logs/Seam`.
- The stash is explicitly temporary: setting label `Keep files temporarily`. `stashSettleTask` *(inference: a debounce before the stash UI settles/collapses after a drop.)*

### Zone layout

Types: `DropzonesConfig`, `DropzonesData`, `ZoneCard`, `ZoneCardIconSource`, `ZoneState`, `TargetedZone`, `StashPhase`, `StashDropAction`, `DropzonesSplitView`, `DropzonesExpandedView`, `DropzonesPeekRow`, `StashMenuItem`.

The zone set is **dynamic, 1–3 zones**, assembled from three toggles (the mangled Swift type `…7airdrop_AA12primaryStashAA06secondC0t` shows the config tuple is literally `(airdrop, primaryStash, secondStash)`):

| Zone | Key | Label | Sublabel | Icon |
|---|---|---|---|---|
| AirDrop | `dropzonesAirDropEnabled` | `Send files via AirDrop` | | `AirDropIcon` |
| Stash (primary) | `dropzonesFileStashEnabled` | `Keep files temporarily` | | `tray.and.arrow.down.fill` |
| Second stash zone | `dropzonesSecondStashZoneEnabled` / `dropzonesAddToStashEnabled` | `Offer Add to Stash as an extra zone` / `Offer Replace Stash as an extra zone` | | `plus.rectangle.on.rectangle` (add) |

`dropzonesStashDropAction` ∈ **`replace | addToStash`**, described as `What a drop does when the stash already has files`. When `dropzonesSecondStashZoneEnabled` is on, the *other* action appears as a third zone (`hasSecondStashZone`) — so with `stashDropAction = replace` the extra zone offers "Add to Stash", and vice versa. `hideAirDrop` collapses back to fewer zones.

Onboarding/feature blurbs: `Drag files near the Surface to AirDrop or stash.` (short) / `Drag files near the Surface to quickly AirDrop or stash them for later.` (long). Master key `dropzonesEnabled`, label `Show zones when dragging files`. Other UI: `arrow.down.circle.fill`, `document.on.document.fill` (menu bar "stash" item), `Copy to Clipboard`.

### Open questions

- Exact serialisation of `stashedFilesData` — no stash currently populated on this machine, so the blob couldn't be dumped. Re-run `defaults read app.seam.Seam stashedFilesData` after stashing a file to see it.
- Whether stashed files are copied into `DragStaging` immediately or only referenced until dragged out. *(inference: referenced; the promise delegate implies lazy materialisation.)*

---

## 5. Device connections (Bluetooth / AirPods toasts)

### Detection — it is audio-route-first, not Bluetooth-first

`ConnectivityManager.swift` + `OutputRouteWatcher.swift` + `AudioOutputCatalog.swift` (+ `LiveAudioDeviceClient`, `AudioDeviceProviding`, `AudioDeviceModel`).

`OutputRouteWatcher` uses **CoreAudio HAL property listeners** (`AudioObjectPropertyAddress`, block signature `v20@?0I8r^{AudioObjectPropertyAddress=III}12` = `AudioObjectPropertyListenerBlock`). A packed table of 4-char codes in the binary (stored little-endian, hence reversed in `strings`) decodes to: `glob` (kAudioObjectPropertyScopeGlobal), `dOut` (kAudioHardwarePropertyDefaultOutputDevice), `dev#` (kAudioHardwarePropertyDevices), `lnam` (kAudioObjectPropertyName), `uid ` (kAudioDevicePropertyDeviceUID), `slay` (kAudioDevicePropertyStreamConfiguration, input + output scopes), `volm`, `mute`. It also has `observeLatchResets()`, `lastOutputDevice`, `wasPausedByRouteLoss`, `wasBinauralPausedByRouteLoss`, `resolveDeviceUID`, `makeDeviceBackend`, `defaultBackend`.

So a connect/disconnect toast is fired from **"the default output device changed / the device list changed"**, which is what actually matters to the user and fires reliably for AirPods.

`CoreBluetooth` is also linked and the `CBCentralManagerDelegate` selectors are present (`centralManager:didConnectPeripheral:`, `didDisconnectPeripheral:error:`, `didDisconnectPeripheral:timestamp:isReconnecting:error:`, `connectionEventDidOccur:forPeripheral:`, `didFailToConnectPeripheral:error:`) — `BluetoothClient.swift` / `LiveBluetoothClient` / protocol `BluetoothProviding`. *(inference: CoreBluetooth is used mainly to justify the Bluetooth TCC prompt and to catch non-audio BT devices; the primary trigger for the AirPods toast is the CoreAudio route change, because the `ConnectivityManager` region of the binary contains no BT strings at all while `OutputRouteWatcher` sits next to the whole CoreAudio property table.)*

### Battery

Two sources, both in `BluetoothClient.swift`:

1. **`/usr/sbin/system_profiler SPBluetoothDataType`** (spawned as a subprocess), reading the keys **`BatteryPercentLeft`, `BatteryPercentRight`, `BatteryPercentCase`**. Results cached — `cachedBluetoothData`, `bluetoothDataCacheTime`.
2. **IOKit registry service `AppleDeviceManagementHIDEventService`** — internal fields `device_connected`, `device_batteryLevelMain`, `device_batteryLevelLeft`, `device_batteryLevelRight`, `device_batteryLevelCase`. (These are the `BatteryPercent*`/`Device*` properties published by that IOService for AirPods.)

Exposed model: `batteryPercentSingle`, `batteryPercentCombined`, `batteryPercentLeft`, `batteryPercentRight`, `batteryPercentCase`.

### Device identity → artwork

`DeviceIdentifier` maps model strings to SF Symbols and to bundled videos. SF Symbols used:
`airpods.gen3.{left,right,chargingcase.wireless}`, `airpods.gen4.*`, `airpods.pro.*`, `airpods.chargingcase.wireless`,
`beats.fitpro.*`, `beats.studiobuds.*`, `beats.studiobuds.plus.*`, `beats.powerbeats.pro.*`, `beats.powerbeats.pro.2.*`, `beats.powerbeats3`, `beats.headphones`.

Device enum: `airPods, airPodsPro, airPodsMax, beats, beatsFitPro, beatsFitPro2, beatsFlex, beatsSolo, beatsSoloBuds, beatsStudio, beatsStudioBuds, beatsStudioBudsPlus, beatsX, powerbeats, powerbeatsPro, powerbeatsPro2`.

**Connection animations** are `.mp4` files in `Contents/Resources` (played with AVKit, not Lottie/GIF) — 19 of them:
`seam-airpods-{1,2,3,4}.mp4`, `seam-airpods-pro{,-2,-3}.mp4`, `seam-airpods-max{,-lightning}.mp4`,
`seam-beats-{fit-pro,fit-pro-2,solo-4,solo-buds,solo-pro,solo3,studio-buds,studio-buds-plus,studio-pro,studio3}.mp4`,
`seam-powerbeats-pro{,-2}.mp4`.

Generic names for unknown devices: `Bluetooth Headphones`, `Bluetooth Speaker`, `Built-in Speaker`, `DisplayPort Audio`.

### Settings / labels

```
connectivityEnabled              Connection alerts / Show when headphones and audio devices connect
                                 Device Connections · Know instantly when your audio devices connect.
audioOutputHiddenDevices         Hidden devices are skipped in the Now Playing picker and when cycling outputs.
                                 Connect another output device to start hiding the ones you do not use.
                                 This device cannot be hidden · The device currently playing cannot be hidden
audioOutputCycleEnabled          Cycle outputs with keyboard / Switch to the next visible output device
                                 Required for the output shortcut  (→ Accessibility)
```
Feature id in the internal registry: `device_connect`. Presenter activity kinds: `device`, `audioOutput`.
Battery (Mac's own) is a separate feature: `batteryEnabled, batteryLowNotify, batteryPlaySound, batteryChargingNotify, batteryShowWhenIdle, batteryStackStyle (plain|colored)`, reading IOPowerSources (`Current Capacity`, `Power Source State`), sound `seam-low-battery.caf`.

### Open question

- Which of the two battery sources wins, and the cache TTL (`bluetoothDataCacheTime` value isn't in strings). Spawning `system_profiler` is expensive (~1 s), so *(inference)* it's probably a slow fallback refreshed on connect + on a long timer, with `AppleDeviceManagementHIDEventService` as the fast path.

---

## 6. Island surface, geometry & animation

### Window & surface model

`SurfaceWindow.swift` (`Seam.SurfaceWindow`, `SurfaceWindowDragDelegate`, `window:shouldDragDocumentWithEvent:from:withPasteboard:`, `WindowDragBlocker.swift`), `SurfaceController.swift` + `SurfaceController+Hover.swift` + `SurfaceController+Visibility.swift`, `SurfaceContainerView.swift`.

Three concrete surface classes: **`NotchSurface`, `IslandSurface`, `BarSurface`** (`SurfaceType` = `notch | island | bar`). Settings `builtInDisplayMode` (currently `notch`) and `externalDisplayMode` (currently `bar`) choose per-display; `builtInDisplayEnabled` / `externalDisplayEnabled` turn each off.

`Island Style` / `Choose Your Style`: *"Notch wraps around your camera cutout. Island floats as a pill just below the menu bar."*
`Island Visibility` ∈ **`onHover` | `alwaysVisible`** (localized `On Hover` / `Always Visible`).

`multiDisplayPlacement` ∈ `automatic | allDisplays | followPointer` —
`Built-in takes priority. External used when lid is closed.` / `Shown on your built-in display and every external display at the same time.` / `Shown on the display where your pointer is.`
Helpers: `DisplayManager.swift`, `DisplayCoordinator.swift`, `PointerScreenMonitor.swift` (with `dwell` / `dwellTask` / `settledDisplayID` to avoid thrashing on pointer moves), `ScreenParametersClient.swift`, `FullscreenManager.swift`, `BetterDisplayMonitor.swift` (integrates with BetterDisplay via `betterdisplay://set?osdShowCustom=` and observes `com.betterdisplay.BetterDisplay.osd`).

Notifications: `app.seam.notchDimensionsDidChange`, `app.seam.displayAvailabilityChanged`, `displayModeSettingChanged`, `app.seam.screenCaptureSettingChanged`.
`NotchDimensions.swift` + `GestureNotchDimensions` + `IslandDimensions` + `IslandMetrics.swift` + `SurfaceMetrics`; `hasNotch` / `internalHasNotch` / `_internalHasNotch` (reads `hw.model` via sysctl as a fallback).

### Geometry vocabulary (names only — the numeric constants are compiled-in and not in the string table)

```
peekWidth, peekHeight, peekRadius, peekFontSize, peekInset, peekRowHeight, radiusPeek
extraLargePeekWidth
hoverWidth, hoverHeight
compactHoverWidth, compactHoverHeight
mediumCompactHoverWidth, largeCompactHoverWidth
extraLargeCompactHoverWidth, extraLargeCompactHoverHeight
islandBump, surfaceHoverZone, HoverZone, HoverZoneModifier
topRadius, bottomRadius, cornerRadius, maxWidth, squishScale, maxBlur
```
*(inference)* There are at least four compact size tiers (compact / medium / large / extra-large) each with its own hover width, and the peek row is a separate, smaller geometry. `islandBump` is the little downward bulge under the notch; `squishScale` is the press/bounce scale; `topRadius`/`bottomRadius` differ so the notch corners hug the bezel while the bottom corners are rounder.

### Interaction & animation

- `HoverController`, `HoverModifiers.swift` (`HoverZoneModifier`, `TrailingHoverModifier`, `PeekTextHoverModifier`, `ControlButtonHoverModifier`), cached hit-testing (`_cachedHoverPath`, `_cachedHoverParams`, `_lastHoverEvalTime`, `_lastHoverLocation` — i.e. the hover path is recomputed only when geometry changes and evaluation is throttled), `_useLegacyHover` / `trailingIconLegacyHover`, `_contextMenuTrackingCount` (don't dismiss while a context menu is open).
- Settings: `hoverExpandEnabled` (`Open the expanded view without clicking`), `hoverExpandDelay` (`Hover time before expanding`), `hoverCollapseDelay` (`After the pointer leaves`), plus a one-time migration flag `hoverDelayScaleMigrated` / `HoverDelayMigration` / `HoverDelaySpeed` — *(inference: the delay was once stored as a raw seconds value and got remapped to a speed scale; the migration flag is already `1` in this user's defaults.)*
- `TransitionChoreographer.swift` — named transitions **`TwoPhaseTransition`, `DismissFromCompact`, `CollapseToCompact`**; signpost prefix `choreographer.animation.`. `TransitionModifiers.swift`, `SurfaceStrokeModifier.swift` (`surfaceStrokeEnabled`), `SurfaceContentBlurModifier`, `SurfaceContentRouter`, `StackNavigator.swift`.
- `DismissScheduler.swift` — signpost prefix `surface.idle.dismiss.`; key state `idleTimeoutCompactCollapseOverrides` *(inference: a per-activity-kind map overriding the default idle timeout — e.g. a music peek dismisses faster than a code-agent alert.)*
- `SurfaceController+Visibility` — signpost prefix `surface.visibility.`; the reasons it stays hidden are spelled out as strings: `focus mode settings`, `Gaming Focus (Seam hidden)`, `flow session settings`, `drag in progress`, `fullscreen (Show in Full Screen off)`, `Notch overlay active`.
- AppKit animation clock is paused when nothing is on screen: `Animation clock suspended (%{public}s)` / `Animation clock resumed (%{public}s)` — a good battery trick to copy.
- `SurfaceColors` / `SurfaceColorsKey` environment; `glass` style token *(inference: Liquid Glass material on macOS 26)*.

### Gestures (`GestureManager.swift`, `GestureSlideTypes.swift`, `GestureSurfaceInteractionLayer.swift`)

| Gesture | Label |
|---|---|
| `approachTop` | `Summon the island from the top` |
| `hoverIcon` | `Peek at the current activity` |
| `swipeDown` | `Expand the activity` |
| `swipeUp` | `Collapse, then switch activity` |
| `swipeHorizontal` | `Skip tracks while music is playing` / `Swipe horizontally` |

Gesture phases: `tracking, momentum, committed`; axes `horizontal, vertical`. Assets `SwipeUp`, `SwipeDown`, `SwipeHorizontal`, `SwipeUpDown`, `cursorarrow.click.2`, `cursorarrow.motionlines`.
Headline: `Interact with the floating island` / `Interact with Seam using your trackpad or mouse`.

### The activity stack

`ActivityManager.swift` + `ContentPresenter.swift` + `FeatureRuntime.swift` + `FeatureLifecycleCoordinator.swift`. Activity kinds, in the order they appear in the binary (*(inference: this is the priority order)*):

```
progressHUD, music, flowMusic, device, audioOutput, batteryStatus, lockUnlock,
claudeCodeEvent, codexEvent, claudeCodeUsage, cursorEvent, cursorUsage,
voiceLearned, status
```
Plus `TransientLifetime`, `LaunchPhase`, notification `app.seam.activityStackCycled`, `Debouncer` (`SwiftVibeUtils.Debouncer`, category `debounce.settings`), `InteractionState` / `TransitionContext` environment keys.

Feature registry ids (`Feature.swift`): `volume_hud, brightness_hud, device_connect, lock_unlock, dropzones, code_events` (+ the rest).

### Assets.car

58 named assets, all vector/colour — **no bitmap UI chrome**, confirming the island is drawn entirely in SwiftUI:
`AccentColor`, `SecondaryColor`, `MenuBarIcon`, `NowPlayingSymbol`, `AirDropIcon`, `CardWallpaper`,
`ClaudeCodeIcon`, `CodexIcon`, `CursorIcon`, `SwipeUp/Down/Horizontal/UpDown`,
`OnboardingMusicArtwork`, `OnboardingMusicArtwork2`, 37 `Flags/*`, `SeamAppIcon*` (Icon Composer group with `Color-1/2/3` + `surface-orange`).

Sounds (`.caf`, played by `SoundPlayer.swift`): `seam-intro, seam-lock, seam-unlock, seam-calendar, seam-low-battery, seam-code-complete, seam-flow-start, seam-flow-complete, seam-record-start, seam-record-stop, seam-volume-feedback, seam-license-activated, seam-trial-started`.

### Live observation — what failed

- `screencapture -x -R0,0,1800,220 …` → **`could not create image from rect`**: this session lacks Screen Recording permission, so no idle-island screenshot could be taken and no pixel measurements were possible.
- `osascript … System Events … every window of process "Seam"` → **`Not authorised to send Apple events to System Events. (-1743)`** — no Accessibility/Automation permission, so the surface window frame could not be read.
- `CGWindowListCopyWindowInfo` via PyObjC was unavailable (no Quartz module; the system Python is gated behind an unaccepted Xcode licence).
- `log show --predicate 'process == "Seam"'` works (use `/usr/bin/log`; `log` is shadowed by a shell function here) but shows **only system-framework logs** — Seam's own `Logger` output is not persisted at default level, so the state machine could not be observed live. Its categories are nonetheless known from the signpost prefixes above: `surface.visibility.`, `surface.idle.dismiss.`, `choreographer.animation.`, `voice.modelDownload`, `debounce.settings`, `audio.output-catalog`, `xpc.reconnect_exhausted`, `app.seam.helper.mediaremote`.

To get real numbers later: grant Screen Recording + Accessibility to the terminal, then re-run the `screencapture` and `osascript` commands above.

---

## 7. Settings model (complete)

This is the contiguous UserDefaults key table lifted from the binary (`settings-keys.txt`), grouped by feature. Only 27 of these are actually written to `~/Library/Preferences/app.seam.Seam.plist` today — everything else falls back to a compiled-in default.

**General / app**
`launchAtLogin, syncEnabled, showMenuBarIcon, showInFullScreen, showInScreenCapture`
Labels: `Start Seam when you log in`, `Sync settings across my Macs`, `Show icon in menu bar`, `Show in full screen` / `Display when apps go fullscreen`, `Display in screenshots`.

**Display / surface**
`displayMode, builtInDisplayMode, externalDisplayMode, builtInDisplayEnabled, externalDisplayEnabled, multiDisplayPlacement, islandStyle, islandVisibility, surfaceStrokeEnabled, trailingIconLegacyHover, hoverExpandEnabled, hoverExpandDelay, hoverCollapseDelay, hoverDelayScaleMigrated`

**HUDs / sound**
`soundAlertsEnabled, displayAlertsEnabled, volumeHUDStyle, brightnessHUDStyle, showVolumeLabel, showBrightnessLabel`
HUD styles: `clear, loudness, outside` · label positions `leading, center, trailing`.
`Hides native macOS alerts when enabled.` / `Native alerts may appear until Accessibility is enabled.`

**Battery** `batteryEnabled, batteryLowNotify, batteryPlaySound, batteryChargingNotify, batteryShowWhenIdle, batteryStackStyle`

**Connectivity / audio out** `connectivityEnabled, audioOutputHiddenDevices, audioOutputCycleEnabled`

**Now Playing** `nowPlayingEnabled, nowPlayingScrolling, nowPlayingSource, nowPlayingTrackChangeAnimation, nowPlayingBrowserTabFocus, nowPlayingShowOnMediaApp, nowPlayingSwipeEnabled, nowPlayingSwipeReversed, nowPlayingOutputDevicePicker, musicShowWhenIdle`

**Calendar** `calendarEnabled, calendarMinutesBefore, calendarPlaySound, calendarUseCalendarColors, calendarShowDuringMeeting, calendarShowLocation, calendarShowWhenIdle, calendarScrolling, calendarShowAllEvents, calendarVisibilityOverrides`

**Weather** `weatherEnabled, weatherLocationMode, weatherManualCity, weatherManualLatitude, weatherManualLongitude, weatherTemperatureUnit (celsius|fahrenheit), weatherShowWhenIdle, weatherExpandedStyle (realistic), weatherForecastMode (hourly|daily)` — WeatherKit + CoreLocation + MapKit city search.

**Focus** `focusEnabled, focusAllowActivities, focusAllowCodeEvents, focusHideDuringGaming`
`FocusModeResolver.swift` detects Focus changes by **tailing the unified log**: predicate `process == "donotdisturbd" AND eventMessage CONTAINS "modeIdentifier"`, plus `com.apple.focus.activity-manager` and `activeModeConfiguration`. Notification `app.seam.focusModeChanged`.

**Lock/unlock** `lockUnlockEnabled, lockPlaySound, unlockPlaySound` — notifications `app.seam.lockScreenDidLock/DidUnlock`.

**Flow (pomodoro) & Flow Music** `flowEnabled, flowAllowAlerts, flowAllowActivities, flowPlayStartSound, flowPlayCompleteSound, flowShowWhenIdle, flowNudgeEnabled, flowAllowCodeEvents, flowDraftTaskName, flowDraftSessionCount, flowMusicEnabled, flowMusicVolume, flowMusicLastProfile, flowMusicBreakBehavior, binauralEnabled, binauralPreset, binauralBlend`
Streams: SomaFM (dronezone, deepspaceone, synphaera, spacestation), Radio Paradise serenity-flac, lo-fi FM, nightride.fm chillsynth/datawave, a Linn classical FLAC. `BinauralBeatsGenerator` synthesises tones (`Works best with stereo headphones.`). Telemetry `/flow_music/listen/`, `/flow_music/skip/`.

**Shortcuts** `featureShortcutModifierKey, shortcutChord{Flow,FlowMusic,NowPlaying,Calendar,Weather,ClaudeUsage,CodexUsage,CursorUsage,AudioOutputCycle}`

**Voice** `voiceEnabled, voiceModifierKey, voiceActivationMode, voiceOutputMode, voiceRestoreClipboard, voiceSelectedModelID, voiceIndicatorStyle, voiceAudioDuckMode, voiceNormalizeSpokenNumbers, voiceNormalizePunctuation, voiceRemoveFillerWords, voiceRemoveRepeatedPhrases, voiceApplyIntentCorrections, voiceFitToSentence, voiceUseCustomDictionary, voiceCustomDictionary, voiceLearnCorrections, voiceLearnedDictionary, voiceModelInstalledVersion, voiceModelLastUpdateCheck, voiceModelDownloadInProgress, voiceTranslationMappings, voiceInputRanking, voiceTranslationSourceLanguage, voiceNormalizationLanguages`

**Drop zones** `dropzonesEnabled, dropzonesAirDropEnabled, dropzonesFileStashEnabled, dropzonesSecondStashZoneEnabled, dropzonesStashDropAction, stashedFilesData, stashTimestamp` (+ `dropzonesAddToStashEnabled`)

**Code events** — see §3.

**Insights** `insightsEnabled, insightsSelectedTab, insightsSelectedPeriod` — `InsightsStore.swift` tracks `voice`, `calendar` (`Hours in Meetings`), code, `flowMusicSeconds`; empty states `No meetings tracked yet / No coding activity yet / No flow sessions yet / No dictation yet`.

**Updates** `silenceUpdatePrompts, updateLastCheck, updateLastReminder, updateStagedVersion, updateSkippedVersion, updateLastAppliedVersion` (also written as `update.lastCheck` etc.).

**Non-key state blobs in defaults**: `app.seam.userState` (JSON: `isFirstLaunch, onboardedFeatures, skippedFeatures, lastOnboardedVersion`) and `app.seam.interactionHistory` (JSON: per-feature last-interaction timestamps, e.g. `{"music": 8108396…}`) — both mirrored to **iCloud KVS** by `iCloudSynchronizer.swift` when `syncEnabled`.

### Settings window structure

`SettingsSplitViewController.swift` + `SettingsWindow.swift`; panes in order:
`general, appearance, lockScreen, displaySound, audioDevices, battery, focus, nowPlaying, calendar, weather, voice, dropzones, insights, license, about`
Sidebar sections: `notifications, liveActivities, productivity`.
Reusable bits worth mirroring: `SettingsCard`, `SettingsRow`, `SettingsPaneHelpers`, `SegmentedPicker`, `SelectableOptionCard`, `CardSelector`, `PreviewSelectionCard`, `PermissionRequestCard` (permission enum `calendar, bluetooth, microphone, accessibility, location`), `ShortcutRecorder` + `ShortcutKeycaps`, `SidebarIcon`.

### Onboarding

`OnboardingController/ContainerView/WindowController`, slides `AppearanceSlideView`, `FeatureTogglesSlideView`, `GesturesSlideView`, `PreferencesSlideView`, `LicenseSlideView`, `IntroAnimationView`.
Copy: `A clean Dynamic Island for your Mac`, `We'll ask for a few permissions to work smoothly.`, `Your personal content stays on your Mac.`, `Don't worry, you can change all this later in Settings.`, `Seam is ready to use`.

### Licensing & updates (not needed for a personal clone, but noted)

Gumroad (`https://api.gumroad.com/v2/licenses/verify`) + `X-Seam-Signature`, Crockford-ish key alphabet `23456789ABCDEFGHJKMNPQRSTUVWXYZ`, 48-hour trial, device fingerprint from serial+UUID+keychain salt, `LicenseHeartbeat`.
Self-updater (`SwiftVibeUpdate`): feed `https://releases.getseam.app`, **certificate pinning** (3 base64 SPKI hashes embedded), **Ed25519** signature over the release, sha256 digest check, `hdiutil` mount, `codesign -R=anchor apple generic and certificate leaf[subject.OU] = R8Q6V6H2KC` verification of the downloaded bundle, then staged swap via `Contents/Resources/SwiftVibeKit_SwiftVibeUpdate.bundle/Contents/Resources/update-helper.sh` (`QuietUpdateSwap.swift`, `Installs next time Seam starts`). Refuses to update unless running from `/Applications` (`Updates install only from the Applications folder`).

---

## 8. Shortest path for the clone

*(inference — my recommendation, not something Seam states)*

1. **Surface first.** One borderless, non-activating `NSWindow` per screen at `.statusBar`-ish level, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, `sharingType` toggled by a "Display in screenshots" setting, hosting a SwiftUI view. Read the notch from `NSScreen.safeAreaInsets` / `auxiliaryTopLeftArea`, re-read on `NSApplication.didChangeScreenParametersNotification`. Model the states as `hidden → peek → compact → expanded` with a `TransitionChoreographer`-style two-phase animation and a `DismissScheduler` with per-activity idle timeouts.
2. **Activity stack.** A single priority-ordered queue of transient activities, each with a lifetime and a "show when idle" flag. Every feature is just a producer into it.
3. **Music.** Copy the XPC-helper pattern exactly (separate `.xpc` with a `com.apple.*` bundle id, `dlopen`/weak-link MediaRemote, debounce + dedup + artwork-id policies on the helper side). This is the only part that needs a trick.
4. **Device connections.** CoreAudio `AudioObjectAddPropertyListenerBlock` on `kAudioHardwarePropertyDefaultOutputDevice` + `kAudioHardwarePropertyDevices`; battery from the `AppleDeviceManagementHIDEventService` IOService, with `system_profiler SPBluetoothDataType` as the slow fallback.
5. **Drop zones.** Global `NSEvent` drag monitor to reveal a borderless `NSDraggingDestination` catcher window; `NSSharingService` for AirDrop; `QLThumbnailGenerator` for previews; `NSFilePromiseProvider` for dragging back out. Store plain URLs (don't sandbox) in a small JSON in Application Support rather than UserDefaults.
6. **Coding agents.** Reuse the hook-script + `NSDistributedNotificationCenter` design verbatim in spirit — it is simple, robust and never blocks the agent. The stage mapping table in §3 is the whole design.
7. **Voice.** Add FluidAudio as a SwiftPM dependency and let it fetch Parakeet v3 itself (it already uses `~/Library/Application Support/FluidAudio/Models/`); you only need the capture session, the cleanup pipeline, the insertion strategy with clipboard restore, and `Translation.framework` for translation.

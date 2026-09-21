# Whispering Flow — Architecture

Local-first, system-wide push-to-talk dictation for macOS. Original work; inspired by the
*workflow* of Wispr Flow, sharing none of its code, assets, branding, or APIs.

Status: **design only.** No application code has been written.

---

## 1. Design principles

1. **The pipeline is a sequence of replaceable stages.** Every stage is behind a protocol.
   No stage knows the concrete type of any other stage.
2. **Speech recognition is a plug-in, not a foundation.** `SpeechEngine` is the single
   swap point. Swapping Apple ⇄ Parakeet ⇄ WhisperKit must touch exactly one file plus
   a registry entry.
3. **Pure core, thin shell.** Text processing and gesture interpretation are pure Swift
   with no AppKit, no I/O, no clocks. They are unit-testable without a running app.
4. **One orchestrator, many services.** `DictationCoordinator` is the only type that knows
   the whole graph. Services never call each other directly.
5. **Audio never leaves the process.** No network I/O in the audio or transcript path.
   The only permitted network call is a one-time model asset download (and only for
   engines that need one).
6. **Failure is a first-class state.** Every phase can fail visibly. Silence is a bug.

---

## 2. Architecture diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                                APP SHELL                                      │
│  WhisperingFlowApp (@main, NSApplicationDelegate, .accessory activation)      │
│  · owns lifecycle · builds the graph · no business logic                      │
└───────────────────────────────────┬──────────────────────────────────────────┘
                                    │ constructs & injects
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                         DictationCoordinator  (@MainActor)                    │
│  The state machine. The ONLY type aware of the full graph.                    │
│                                                                               │
│   idle ──press──▶ arming ──▶ recording ──release──▶ transcribing              │
│     ▲                                                    │                    │
│     │                                                    ▼                    │
│     └──── inserted ◀── inserting ◀── processing ◀────────┘                    │
│     └──── failed(reason) ◀─────────────── (any state)                         │
└──┬────┬────┬─────────┬──────────┬──────────┬──────────┬──────────┬───────────┘
   │    │    │         │          │          │          │          │
   │    │    │         │          │          │          │          │
   ▼    │    ▼         ▼          ▼          ▼          ▼          ▼
┌──────┐│┌────────┐┌────────┐┌─────────┐┌─────────┐┌────────┐┌──────────┐
│Menu  │││Hotkey  ││Audio   ││ Speech  ││  Text   ││ Text   ││Permission│
│Bar   │││Monitor ││Capture ││ Engine  ││Pipeline ││Inserter││ Center   │
│Ctrl  │││        ││Service ││(plugin) ││ (pure)  ││ (chain)││          │
└──────┘│└───┬────┘└───┬────┘└────┬────┘└────┬────┘└───┬────┘└────┬─────┘
        │    │         │          │          │         │          │
        ▼    ▼         ▼          ▼          ▼         ▼          ▼
   ┌─────────────┐ ┌────────┐ ┌────────────┐ ┌──────┐ ┌────────┐ ┌────────┐
   │ Listening   │ │AVAudio │ │ Apple      │ │Stage │ │  AX    │ │ TCC    │
   │ Indicator   │ │Engine  │ │ Speech-    │ │ list │ │ Insert │ │ probes │
   │ (floating   │ │ +      │ │ Transcriber│ │      │ │  ↓     │ │ +      │
   │  panel)     │ │Convert │ ├────────────┤ │ ...  │ │Clipbrd │ │ Secure │
   └─────────────┘ └────────┘ │ Parakeet / │ │      │ │ Paste  │ │ Input  │
                              │ FluidAudio │ └──────┘ │  ↓     │ │ watch  │
                              ├────────────┤          │Unicode │ └────────┘
                              │ WhisperKit │          │ Type   │
                              │  (future)  │          └────────┘
                              └────────────┘
                                    │
        ┌───────────────────────────┴───────────────────────────┐
        │            SettingsStore  ·  VocabularyStore          │
        │      (UserDefaults + JSON in Application Support)     │
        └───────────────────────────────────────────────────────┘
```

**Data flow for one dictation cycle**

```
key down ──▶ PressGesture(pure) ──▶ .beginCapture
                                      │
                          AudioCaptureService.start()
                                      │
                          [Float] @ 16 kHz mono ── accumulating ──┐
                                      │                            │
key up ────▶ PressGesture(pure) ──▶ .endCapture                    │
                                      │                            │
                          AudioCaptureService.finish() ◀───────────┘
                                      │
                                 AudioClip
                                      │
                          SpeechEngine: begin → stream → finish (ADR-020)
                                      │
                                 RawTranscript
                                      │
                          TextPipeline.process(_:context:)
                                      │
                                 FinalText
                                      │
                          InsertionChain.insert(_:)
                                      │
                              focused application
```

---

## 3. Module responsibilities

Each bullet is a *boundary*. Anything not listed is explicitly out of scope for that module.

### 3.1 App lifecycle — `App/`

| File | Responsibility |
|---|---|
| `WhisperingFlowApp.swift` | `@main`. Sets `NSApp.setActivationPolicy(.accessory)` so no Dock icon. Constructs the object graph. Nothing else. |
| `AppEnvironment.swift` | Composition root. Reads settings, picks the concrete `SpeechEngine`, wires services. The only place `init()` of a concrete service is called. |
| `DictationCoordinator.swift` | The state machine (see diagram). Owns `SessionState`. Enforces the single-flight invariant. |
| `DictationSession.swift` | Value type describing one press→insert cycle: id, start time, locale, target app, timings, outcome. Used for logging and diagnostics. |

**Why a coordinator rather than letting services call each other:** the invariant that
matters most — *never run two transcriptions concurrently against the same Core ML graph* —
can only be enforced at a place that sees all transitions. Presspeech learned this the hard
way and documents it explicitly: a Swift `actor` is **not** sufficient, because actors are
reentrant at suspension points, so a second call can enter while `await transcribe(...)` is
suspended. The coordinator holds the flight lock; the engine keeps a defensive backstop.

### 3.2 Menu bar UI — `MenuBar/`

- `MenuBarController` — owns the `NSStatusItem`, renders `MenuBarState` (idle / listening /
  transcribing / inserting / blocked / error) as icon + tooltip, builds the menu.
- `MenuBarMenuBuilder` — pure function `(AppState) -> NSMenu` so menu contents are testable.
- **Does not** own app state, does not talk to audio or speech.

### 3.3 Global shortcut — `Hotkey/`

- `HotkeyMonitor` (protocol) — `start()`, `stop()`, `setBinding(_:)`, callbacks
  `onPress` / `onRelease` / `onCancel`.
- `CGEventTapHotkeyMonitor` — the only implementation. Session-level `CGEventTap` at
  `.headInsertEventTap`, mask = `keyDown | keyUp | flagsChanged`.
- `PressGesture` — **pure state machine.** Input: a stream of `HotkeyEvent` value types
  (keycode, flags, isAutoRepeat, type). Output: `.begin`, `.end`, `.cancel`, `.ignore`.
  Handles hold vs toggle, debounce, auto-repeat suppression, and the "modifier released
  while another modifier still held" case. Fully unit-testable with zero system calls.
- `HotkeyBinding` — the persisted user choice (modifier-only keys like Right Option, or
  F-keys, or modifier+key).
- `TapHealthMonitor` — re-enables the tap on `.tapDisabledByTimeout` /
  `.tapDisabledByUserInput`, and detects the "tap installed but no events ever arrive"
  condition that indicates a stale Input Monitoring grant.

**Why `CGEventTap` and not `NSEvent.addGlobalMonitorForEvents` or Carbon `RegisterEventHotKey`:**
push-to-talk needs **key-up**, and modifier-only triggers (Right Option) are the ergonomic
choice. Carbon hotkeys fire on press only and cannot bind a bare modifier. `NSEvent` global
monitors do not reliably distinguish left/right modifiers or `fn`. A session event tap is the
only API that delivers all three. This forces the Input Monitoring permission — that is a
consequence of the requirement, not an optional extra.

### 3.4 Audio capture — `Audio/`

- `AudioCaptureService` (protocol) — `prepare()`, `beginRecording()`,
  `finishRecording() -> AudioClip`, `cancel()`, `levelStream`.
- `AVAudioEngineCapture` — `AVAudioEngine` input node tap → `AVAudioConverter` →
  **16 kHz, mono, Float32, non-interleaved** (the format both candidate engines require).
  Handles multi-channel → mono mixdown, sample-rate conversion, and
  `AVAudioEngineConfigurationChange` (device unplugged mid-sentence).
- `AudioDeviceRegistry` — enumerates input devices for the picker; maps a persisted device
  UID back to an `AudioDeviceID`, falling back to system default when the device is gone.
- `AudioClip` — `[Float]` + sample rate + duration + capture metadata.

**Engine stays warm.** `AVAudioEngine` is started once at app readiness and left running;
`beginRecording()` only flips an accumulation flag. Starting the engine on key-down costs
100–300 ms and clips the first syllable.

### 3.5 Speech recognition — `Speech/` ← **the swap point**

```swift
protocol SpeechEngine: Sendable {
    static var identifier: SpeechEngineID { get }
    var supportedLocales: [Locale] { get async }
    var readiness: EngineReadiness { get async }          // .notInstalled / .installing(Progress) / .ready / .failed
    func prepare(locale: Locale, progress: ProgressSink?) async throws
    func transcribe(_ clip: AudioClip, locale: Locale) async throws -> RawTranscript
    func teardown() async
}

struct RawTranscript: Sendable {
    let text: String
    let detectedLocale: Locale?        // nil when the engine cannot report one
    let confidence: Double?
    let segments: [TranscriptSegment]  // may be empty
}
```

Three implementations, selected at runtime from settings:

| Implementation | Backing | Notes |
|---|---|---|
| `AppleSpeechEngine` | `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26) | **Recommended default.** Explicit per-locale model. Assets via `AssetInventory`, stored in system storage, outside the app's memory. |
| `ParakeetSpeechEngine` | FluidAudio → Parakeet TDT 0.6B v3 Core ML | Alternative. Runs on macOS 14+. See TECH_DECISIONS ADR-002 for its EN/ES limitation. |
| `WhisperKitSpeechEngine` | argmax-oss-swift | Not built in V1. Slot reserved to prove the protocol is honest. |

`SpeechEngineRegistry` maps `SpeechEngineID` → factory. Adding an engine = one new file +
one registry line. No other file changes.

`ModelAssetCoordinator` sits *beside* the engines and owns download/verify/progress/disk-space
reporting, so an engine that needs no download (Apple) simply reports `.ready`.

### 3.6 Text processing — `TextProcessing/` (pure, no AppKit)

```swift
protocol TextStage: Sendable {
    var id: StageID { get }
    func apply(_ input: String, context: ProcessingContext) -> String
}

struct TextPipeline {
    let stages: [any TextStage]
    func process(_ raw: String, context: ProcessingContext) -> String
}
```

V1 stage order — deterministic, no LLM:

```
RawTranscript
  1. UnicodeNormalizer        NFC, strip control chars
  2. WhitespaceNormalizer     collapse runs, trim, fix space-before-punctuation
  3. FillerWordRemover        locale-aware: EN "um, uh, like", ES "eh, este, o sea"
  4. SpokenPunctuationStage   "comma"/"coma", "new line"/"nueva línea", "period"/"punto"
  5. VocabularyCorrector      personal dictionary, longest-match-first, case-preserving
  6. CapitalizationStage      sentence-initial, post-terminal, preserve dictionary casing
  7. TrailingPolishStage      final trim + configured suffix (space / newline / none)
FinalText
```

`ProcessingContext` carries locale, target-app bundle id, vocabulary snapshot, and user
options — so a future **context-aware** stage (ADR-009) and a future **local LLM cleanup**
stage (ADR-010) plug in as stages 8 and 9 with no change to the protocol or to any other
module. That is the entire reason this is a stage list rather than one `clean()` function.

**Ordering rationale:** filler removal runs *before* vocabulary correction so a filler
adjacent to a dictionary term does not block the match; capitalization runs *after*
vocabulary so `openai → OpenAI` is not re-cased to `Openai`.

### 3.7 Text insertion — `Insertion/`

```swift
protocol TextInserter: Sendable {
    var id: InserterID { get }
    func canAttempt(target: FocusedTarget) -> Bool
    func insert(_ text: String, target: FocusedTarget) async -> InsertionOutcome
}
```

`InsertionChain` runs candidates in order and returns on first success:

1. **`AccessibilityInserter`** — `AXUIElementCreateSystemWide` → `kAXFocusedUIElementAttribute`
   → set `kAXSelectedTextAttribute`. Cleanest when it works (no clipboard side effects, no
   synthetic keystrokes). Fails on many Electron and web-view targets.
2. **`ClipboardPasteInserter`** — write to `NSPasteboard`, synthesize ⌘V via `CGEvent`,
   restore prior contents **only if `changeCount` still matches** what we wrote (otherwise
   another app or the user has since changed the clipboard and restoring would clobber it).
   Highest compatibility; this is the pragmatic default for the target app matrix.
3. **`UnicodeKeystrokeInserter`** — `CGEvent.keyboardSetUnicodeString` in chunks. Slow and
   visibly types, but works in a few places the other two do not.

`FocusedTarget` (from `FocusedAppProbe`) carries the frontmost app's bundle id and, when
available, the focused `AXUIElement` role. It lets the chain be re-ordered per app — the
hook for per-app strategy overrides in settings without touching inserter code.

**All AX calls run off the main thread with a timeout.** A hung `AXUIElementCopyAttributeValue`
against an unresponsive app will otherwise freeze the whole menu-bar app.

### 3.8 Permissions — `Permissions/`

- `PermissionCenter` — current status of the three required grants, a `prompt(_:)` that
  opens the correct System Settings pane, and a change stream so the menu bar reflects
  reality without a relaunch.
- `SecureInputMonitor` — polls `IsSecureEventInputEnabled()`. While secure input is held by
  *any* process, our event tap receives nothing and synthetic paste is refused. This is the
  single most confusing failure mode in this class of app, so it gets a dedicated,
  user-visible state rather than being reported as "hotkey not working."

| Permission | TCC service | Needed for | Consequence if denied |
|---|---|---|---|
| Microphone | `kTCCServiceMicrophone` | `AVAudioEngine` input | No audio at all |
| Input Monitoring | `kTCCServiceListenEvent` | Observing the hotkey via `CGEventTap` | Tap installs but never fires |
| Accessibility | `kTCCServiceAccessibility` | AX insertion + `CGEventPost` of ⌘V | Text is transcribed but never delivered |

### 3.9 Settings & persistence — `Settings/`

- `SettingsStore` — typed wrapper over `UserDefaults`, one property per preference,
  publishes changes. No other module reads `UserDefaults` directly.
- `VocabularyStore` — personal dictionary as JSON in
  `~/Library/Application Support/WhisperingFlow/vocabulary.json`. Human-editable on purpose,
  with atomic writes and a schema version field.
- `LaunchAtLoginController` — `SMAppService.mainApp`.
- Nothing here imports anything from `Speech/`, `Audio/`, or `Insertion/`.

### 3.10 Floating listening indicator — `UI/`

`ListeningIndicatorWindow` — a borderless `NSPanel`, `.nonactivatingPanel`,
`level = .statusBar`, `ignoresMouseEvents = true`, `collectionBehavior` including
`.canJoinAllSpaces` and `.fullScreenAuxiliary`.

**The non-activating and ignore-mouse flags are load-bearing:** if the panel ever takes key
focus, the user's caret moves and the transcript lands in the wrong place. This is a
correctness requirement, not a cosmetic one.

---

## 4. Concurrency model

- `DictationCoordinator`, `MenuBarController`, `HotkeyMonitor`, and all UI are `@MainActor`.
- `SpeechEngine` implementations are `actor`s, guarded additionally by the coordinator's
  single-flight lock (see §3.1).
- `AudioCaptureService` is `Sendable` with an internal lock: the render-thread tap callback
  is real-time and must never `await` or allocate unboundedly.
- The CGEventTap callback is a C function pointer. It builds an immutable
  `HotkeyEvent` snapshot and hops to the main actor. **No allocation, no locks, no logging
  of raw keycodes** inside the callback — it sees every keystroke the user types, including
  passwords, so it must be minimal and must never persist what it sees.
- Swift 6 strict concurrency is on from commit one. Retrofitting it later is materially
  harder than starting with it.

---

## 5. What deliberately is *not* in V1

Streaming/partial transcription, meeting recording, file transcription, diarization,
cloud anything, accounts, auto-update, sandboxing for App Store distribution. Each would
force structural changes; each is cheap to add later given the boundaries above.


---

## Addendum, 21 Sept 2026

- **`HotkeyGestureCore.PressGesture`** now also models hands-free (ADR-025): `awaitingSecondTap`,
  `handsFree(triggerDown:)`, chord detection, and a limit expressed as an intent, still pure and
  clock-free. `CGEventTapHotkeyMonitor` owns the hold timer and the hands-free limit timer.
- **`Sources/WhisperingFlow/HUD/`** (ADR-026): `ListeningHUDController` observes the coordinator,
  `WaveformHistory` (pure dB mapping), `HUDPlacement` (pure geometry, AX↔AppKit coordinates),
  `CaretLocator` (bounded Accessibility lookup on a worker). The panel never becomes key or main.
- **`TextProcessingCore`**: `QuestionMarkStage` (ADR-027), `StarterVocabulary` (generated, ADR-028),
  `PersonalSeed` (omitted from the public copy), `VocabularyStage.warmUp`.
- **Tooling:** `Scripts/install.sh`, `doctor.sh`, `export-public.sh`, `Scripts/vocab/`.

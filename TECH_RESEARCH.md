# Whispering Flow — Technical Research

Research date: **2026-08-22**.

**Evidence key**

- **[V]** Verified by me in this session — I read the source, ran the command, or fetched
  primary documentation. Reproduction noted.
- **[S]** Secondary source — reputable but not independently confirmed by me.
- **[A]** Assumption or inference. Not established. Flagged for a spike.

---

## 0. Local environment

**[V]** Measured on this machine (`sw_vers`, `uname -m`, `xcodebuild -version`, `swift --version`):

| | |
|---|---|
| macOS | **26.5.2** (build 25F84) |
| Architecture | **arm64** (Apple Silicon) |
| Xcode | **26.6** (17F113) |
| Swift | **6.3.3**, target `arm64-apple-macosx26.0` |

This matters more than it looks: **macOS 26 is the first release with `SpeechAnalyzer` /
`SpeechTranscriber`.** The machine that will run this app already has them. That reshapes
the engine decision (ADR-002).

---

## 1. FluidAudio

Repo: <https://github.com/FluidInference/FluidAudio> · Models: <https://huggingface.co/FluidInference>

**[V]** Cloned the repo and read `Package.swift` and ASR sources directly:

- **License:** Apache-2.0.
- **Platforms:** `.macOS(.v14)`, `.iOS(.v17)`. `swift-tools-version: 6.0`.
- **Latest tag:** `v0.15.6` (via `git ls-remote --tags --sort=-v:refname`).
- Zero external Swift package dependencies, but ships **binary targets**:
  `FastClusterWrapper`, `MachTaskSelfWrapper`, and `NemoTextProcessing` — the last is a
  prebuilt `.xcframework` from `FluidInference/text-processing-rs` v0.3.0 (a Rust FST engine
  for NeMo text normalization). *Binary dependencies you cannot inspect or rebuild are a
  supply-chain consideration for a "no telemetry, fully local" app.*
- **ASR API (verified signature** in `Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrManager.swift`**):**

```swift
public func transcribe(
    _ audioBuffer: AVAudioPCMBuffer,
    decoderState: inout TdtDecoderState,
    language: Language? = nil
) async throws -> ASRResult
```

- **Audio format required:** 16 kHz, mono, Float32. The docs are explicit that you should
  convert via the library's `AudioConverter` rather than parsing PCM by hand.
- Models auto-download from Hugging Face on first use into a local cache directory.

### 1.1 ⚠️ The `language:` parameter does **not** do what its name suggests

**[V] — this is the most consequential finding in this document.**

I read `Sources/FluidAudio/Shared/TokenLanguageFilter.swift`. The doc comment on `transcribe`
reads:

> "Optional language hint for **script-aware token filtering** (v3 only). When set, top-K
> tokens that don't match the language's **script** are skipped in favor of matching
> candidates."

And the `Language.script` mapping is:

```swift
case .english, .spanish, .french, .german, .italian, .portuguese, .romanian,
     .dutch, .danish, .swedish, .finnish, .hungarian, .estonian, .latvian,
     .lithuanian, .maltese,
     .polish, .czech, .slovak, .slovenian, .croatian, .bosnian:
    return .latin
case .russian, .ukrainian, .belarusian, .bulgarian, .serbian:
    return .cyrillic
case .greek:
    return .greek
```

**English and Spanish both map to `.latin`,** and the `.latin` matcher accepts ASCII,
Latin-1, Latin Extended-A/B, Latin Extended Additional, and combining diacritics.

**Therefore `language: .spanish` and `language: .english` are behaviourally identical for
the English/Spanish pair.** The filter exists to stop Cyrillic tokens leaking into Polish
(the linked issue is #512) — it is not a language-selection mechanism.

**Consequence:** Parakeet TDT v3 via FluidAudio offers **no controllable English/Spanish
selection whatsoever.** You get whatever the model's implicit detection produces, and there
is no `detectedLanguage` returned to even tell you what it decided. Feature request
[#303](https://github.com/FluidInference/FluidAudio/issues/303) asked for a real language
parameter and a `detectedLanguage` field; **[V]** it is now **closed**, and what shipped is
the script filter described above — not forced decoding. **[S]** The issue reports that
"auto-detection often defaults to English even when the user speaks French."

This directly threatens the bilingual EN/ES requirement, which is a core product goal.

### 1.2 Performance

**[S]** Vendor-reported: ~110–190× real-time factor on M4 Pro for batch ASR (figures vary
between the README and the benchmarks doc — treat as order-of-magnitude, not spec).
At even 100× RTF a 10-second utterance transcribes in ~0.1 s, so **model inference is not
the latency bottleneck for dictation.** Model load and ANE warm-up are (see §1.3).

**[A]** First-inference / ANE warm-up cost after load is **not documented**. This must be
measured — it determines whether the engine needs a keep-warm strategy.

### 1.3 Operational burden

**[V]** From reading presspeech's integration: a production Parakeet deployment needs
model download with progress, **model integrity verification with a forced re-download on
failure**, disk-space preflight, and cache-location management. That is real, ongoing
maintenance code that an OS-provided engine does not require.

---

## 2. Parakeet TDT 0.6B v3

Model card: <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml>

- **[S]** NVIDIA NeMo Parakeet TDT, 0.6 B parameters, converted to Core ML, runs on the ANE.
- **[S]** Covers 25 European languages (+ Japanese via a separate variant). English and
  Spanish are both in scope.
- **[S]** Model download is ~500–600 MB on first launch (presspeech's README figure).
- **[S]** Apple Silicon only in practice — the ANE is the point.
- **[S]** WER on LibriSpeech, from MacParakeet's own published benchmark table: Parakeet v3
  ≈ **3.22 %**, Parakeet v2 (English-only) ≈ **2.57 %**, Whisper large-v3-turbo ≈ **3.00 %**.
  Note the multilingual v3 is *worse* on English than the English-only v2 — the usual
  multilingual tax.

---

## 3. Apple `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26)

Primary: [WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/) ·
[SpeechTranscriber docs](https://developer.apple.com/documentation/speech/speechtranscriber)

- **[S]** Available on iOS 26 / macOS 26 / iPadOS 26 / visionOS 26 / tvOS 26. Not watchOS.
- **[S]** Modular design: `SpeechAnalyzer` hosts modules; `SpeechTranscriber` (new
  long-form/low-latency model), `DictationTranscriber` (legacy `SFSpeechRecognizer` model,
  fallback for unsupported locales), `SpeechDetector` (VAD).

```swift
let transcriber = SpeechTranscriber(locale: locale, preset: .offlineTranscription)
let analyzer = SpeechAnalyzer(modules: [transcriber])
```

- **[S] Supported locales include `en_US`, `en_GB`, `en_AU`, `en_CA`, `en_IE`, `en_IN`,
  `en_NZ`, `en_SG`, `en_ZA`, and `es_ES`, `es_MX`, `es_CL`, `es_US`** — plus ~25 more.
  **This gives explicit, per-locale English and Spanish selection**, which is exactly what
  Parakeet cannot do (§1.1).
- **[S]** Models are **not bundled**. `AssetInventory.assetInstallationRequest(supporting:)`
  downloads them into **system storage** — does not increase app size, does not count against
  app memory, updates as Apple improves the model. This removes the entire §1.3 burden.
- **[S]** Delivers **volatile** results (fast, low-accuracy, revisable) and **finalized**
  results (`isFinal == true`). For push-to-talk, volatile results can drive a live preview
  in the HUD, and finalization on key-up should be near-immediate because the audio was
  already streamed in during the hold — rather than transcription starting from scratch at
  release.
- **[S]** Locale allocation is limited; `AssetInventory.allocatedLocales` /
  `deallocate(locale:)` manage the budget. **[A]** Whether `en_US` and `es_ES` can be
  allocated **simultaneously**, and whether one `SpeechAnalyzer` can host two
  `SpeechTranscriber` modules for concurrent bilingual recognition, is **unconfirmed** and
  is a required spike (Phase 5). This is the crux of the "automatic language selection"
  feature.
- **[S]** Known gap vs. the old `SFSpeechRecognizer`: **no custom-vocabulary API.**
  Not blocking here — our personal dictionary is a post-processing stage by design (ADR-007),
  which is more controllable anyway.
- **[S]** Independent benchmark (MacStories, 5,559 LibriSpeech clips): **2.12 % WER clean /
  4.56 % noisy**, ~3× faster than Whisper Small (3.74 % / 7.95 %). **[A]** Comparing this
  against MacParakeet's 3.22 % for Parakeet v3 (§2) is *suggestive but not rigorous* — the
  test subsets and audio conditions are not identical. Do not treat "Apple is more accurate"
  as established. **We must measure both on our own Spanish and English speech (Phase 5).**

---

## 4. WhisperKit / argmax-oss-swift

<https://github.com/argmaxinc/argmax-oss-swift>

- **[S]** As of **v1.0.0 (2026-05-01)** the repo was renamed from `argmaxinc/WhisperKit` to
  `argmaxinc/argmax-oss-swift`, now bundling WhisperKit + SpeakerKit + TTSKit, **MIT** licensed,
  with full Swift 6 concurrency support. **Any tutorial referencing the old repo path is stale.**
- **[S]** Core ML encoder/decoder, automatic ANE/GPU/CPU placement.
- Relevant here mainly as the **third engine** that proves `SpeechEngine` is a real abstraction.
  Whisper's higher latency and hallucination-on-silence behaviour make it a poor default for
  short push-to-talk utterances.

---

## 5. Reference implementations studied

### 5.1 presspeech — <https://github.com/rcourtman/presspeech>

**The closest existing analogue to this project.** **[V]** Cloned and read the source.

- **License: MIT.** Permissive — techniques may be learned from and adapted with attribution.
- **[V] Architecture: a single `swift/Sources/Presspeech/main.swift` of 14,092 lines.**
  SwiftPM executable target, AppKit menu bar, `.macOS("14.0")`, one dependency: FluidAudio
  pinned to revision `4dbf4f9f…` — **[V]** which is exactly tag `v0.15.6`.
- **[V] Hotkey:** `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
  options: .defaultTap, eventsOfInterest: keyDown|keyUp|flagsChanged)`. The callback builds an
  immutable snapshot struct and hops to `MainActor.assumeIsolated`. Returning `nil` suppresses
  the event.
- **[V] Two excellent diagnostic ideas worth stealing outright:** it logs the *first event that
  ever arrives* at the tap, because "tap created successfully" does **not** prove events are
  flowing — with a stale Input Monitoring grant the tap goes live and stays silent forever,
  which is indistinguishable in a log from "the user never pressed anything." It separately logs
  the first *unmatched* modifier, and deliberately logs **only modifier names**, never arbitrary
  keycodes, since that could leak typed text.
- **[V] Text insertion:** `clipboardPaste` primary with `directUnicode` fallback, expressed as an
  ordered strategy chain. Notably it has **no** Accessibility-API inserter at all.
- **[V] Clipboard restore guard:** restores the previous clipboard **only if `NSPasteboard.changeCount`
  still equals what we wrote** — otherwise another app or the user changed it and restoring
  would clobber their data. Adopt verbatim as a rule.
- **[V] Concurrency warning documented in-source:** the ANE "doesn't tolerate concurrent
  inference calls against the same compiled CoreML graph," and **an `actor` alone does not
  prevent this** because actors are reentrant across `await`. Their real guard is an
  app-level `isBusy` flag, with an `inFlight` assertion as backstop. → ARCHITECTURE §3.1/§4.
- **[V] Entitlements:** ships **both** `com.apple.security.device.audio-input` (Hardened
  Runtime key — the source comment states **macOS 26 checks this one** for Developer-ID apps,
  and without it the app never gets a TCC entry and the mic prompt *silently never fires*) and
  `com.apple.security.device.microphone` (sandbox key, kept for older systems).
  **This is a landmine we would otherwise have hit.**
- **[V] Permissions modelled:** Microphone, Accessibility, Input Monitoring — all three.
- **[V] Language handling:** exposes an 19-entry `DictationLanguage` enum mapping to FluidAudio's
  `Language`, with `.auto` passing `nil`. Per §1.1, for the EN/ES pair **this menu cannot
  actually change transcription behaviour** — it is effectively cosmetic for our language pair.
- **[V] It also handles** SwiftPM resource-bundle vs `codesign --deep` incompatibility (they copy
  PNGs into `Contents/Resources` from a build script instead of using SwiftPM `resources:`),
  audio-route-change restart logic, and post-sleep runtime recovery. All real problems we will hit.

**Verdict:** superb source of hard-won *techniques*; its *structure* is precisely the monolith
to avoid. Study, don't fork.

### 5.2 MacParakeet — <https://github.com/moona3k/macparakeet>

- **[S] License: GPL-3.0** (open-sourced 2026-03-25). **Copyleft — forking would compel
  Whispering Flow to be GPL-3.0.** Reading it for architectural ideas is fine; copying code is
  a licensing commitment.
- **[S]** Swift 6 + SwiftUI, macOS 14.2+, Apple Silicon only. GRDB/SQLite persistence, Sparkle 2
  auto-update, yt-dlp for media. Far larger scope than we need (meetings, file/YouTube
  transcription, CLI).
- **[S]** Multi-engine already: Parakeet v2/v3/Unified via FluidAudio, Nemotron, WhisperKit,
  Cohere. **Validates that a pluggable `SpeechEngine` boundary is the right call** — someone
  built this app and needed exactly that seam.
- **[S]** Explicit scheduler with a **reserved dictation slot** separate from the shared
  meeting/file slot — i.e. interactive dictation must never queue behind batch work.
- **[S]** Their vocabulary/cleanup pass is deterministic and reported at **<1 ms** (filler
  removal, word replacement, snippet expansion, whitespace). Confirms the "no LLM in V1"
  instinct: the deterministic pipeline is effectively free.
- **[S]** Confirms Parakeet v3 "fails on CJK/Korean by design" — a real scope limit of the model.

### 5.3 Others noted

- **`FrigadeHQ/yap`** — free/OSS macOS dictation built on Apple's Speech framework, no cloud.
  Useful as a second reference for the Apple-engine path specifically.
- **`FluidInference/swift-scribe`** — reference app for `SpeechAnalyzer` + Foundation Models on
  macOS 26. Closest thing to sample code for the recommended engine.
- **`sindresorhus/KeyboardShortcuts`** — polished user-configurable global hotkeys, sandbox-safe.
  **[A]** Built around Carbon `RegisterEventHotKey` semantics; **[A]** I did **not** confirm it
  exposes key-**up** or bare-modifier bindings, and those are exactly what push-to-talk needs.
  Likely usable for the *recorder UI* but not for the press/release detection. Spike before adopting.

---

## 6. Global keyboard shortcuts on macOS

**[S]/[A]** The three options and why only one qualifies:

| Approach | Key-up? | Bare modifier (Right ⌥)? | Permission | Verdict |
|---|---|---|---|---|
| Carbon `RegisterEventHotKey` | ✗ press only | ✗ | none | Unusable for push-to-talk |
| `NSEvent.addGlobalMonitorForEvents` | ✓ | unreliable L/R and `fn` discrimination | Accessibility | Insufficient |
| **`CGEvent.tapCreate` (session tap)** | ✓ | ✓ via `.flagsChanged` | **Input Monitoring** | **Required** |

**[V]** presspeech uses the session tap with `keyDown | keyUp | flagsChanged`, confirming this
in a shipping app.

**Operational gotchas [S]:**
- The system **disables** a tap that runs too long in its callback
  (`.tapDisabledByTimeout`). You must observe that event type and call `CGEvent.tapEnable` again.
  A tap that dies silently is the classic "my hotkey randomly stops working" bug.
- Callback runs on a run loop you must add the mach port source to, and it sees **every**
  keystroke system-wide. Keep it minimal and never persist its contents.

---

## 7. Microphone capture

- **[S]/[A]** `AVAudioEngine` `inputNode` → `installTap(onBus:)` → `AVAudioConverter` to
  16 kHz mono Float32. Standard, well-trodden.
- **[V]** presspeech's implementation confirms the real-world complications: multi-channel
  inputs need an explicit mono mixdown (not just a format conversion), and
  `AVAudioEngineConfigurationChange` must be observed to survive a device being unplugged.
- **[A]** Device selection on macOS is set via the input node's underlying audio unit
  (`kAudioOutputUnitProperty_CurrentDevice`), not an `AVAudioSession` (that's iOS). Needs a spike.
- **[A]** Keeping the engine running continuously vs. starting per-press: I *assume* continuous
  is required to avoid clipping the first syllable, and that idle CPU cost is negligible.
  **Must be measured** (Phase 4) — it is also a battery consideration.

---

## 8. Accessibility APIs & system-wide text insertion

**[S]** Two mechanisms, neither sufficient alone — one source is blunt that
"neither approach works well by itself, so combining the two makes it a little better."

**(a) AX direct set**

`AXUIElementCreateSystemWide()` → `kAXFocusedUIElementAttribute` →
`AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute, text)`.

- Pros: no clipboard mutation, no synthetic keystrokes, atomic.
- Cons **[S]**: unsupported by many Electron/web-view/custom text stacks (VS Code, Slack,
  most Chrome content areas). **[S]** AX calls made on the main thread against an unresponsive
  app **will freeze the caller** — hence ARCHITECTURE §3.7's off-main-thread + timeout rule.

**(b) Clipboard + synthetic ⌘V**

`NSPasteboard.general` → `CGEvent` ⌘V down/up → restore.

- Pros: works essentially everywhere a human can paste — which is the actual target matrix.
- Cons: destroys clipboard contents unless carefully restored; **[S]** reported to fail
  under App Sandbox; racy if the app is slow to process the paste before restore;
  blocked entirely by Secure Input (§10).

**Design conclusion:** an ordered chain — AX → clipboard-paste → Unicode-typing — with a
per-app override, is the only honest design. **[A]** The precise ordering that maximises
success across Chrome / Safari / VS Code / Terminal / WhatsApp / Claude Code **is not
predictable from documentation and must be measured empirically** (ACCEPTANCE_TESTS §3).

**(c) Unicode keystroke injection**

`CGEvent(keyboardEventSource:virtualKey:keyDown:)` + `keyboardSetUnicodeString`.
**[V]** presspeech chunks the string by UTF-16 unit budget per event, splitting on character
boundaries so surrogate pairs and combining marks are never torn — worth replicating.

---

## 9. Permissions required

| Permission | TCC service | Trigger | Prompts? |
|---|---|---|---|
| Microphone | `kTCCServiceMicrophone` | First `AVAudioEngine` input use | Yes, once |
| Input Monitoring | `kTCCServiceListenEvent` | `CGEvent.tapCreate` | **[S]** Often not a real prompt — user must add the app manually |
| Accessibility | `kTCCServiceAccessibility` | AX writes / `CGEventPost` | Manual toggle in System Settings |

- **[V]** `NSMicrophoneUsageDescription` in `Info.plist` **and** the
  `com.apple.security.device.audio-input` entitlement are both required on macOS 26 for a
  Developer-ID app; missing the entitlement means **no TCC entry and no prompt at all** (§5.1).
- **[S]** Accessibility + Input Monitoring together = read *and* inject all input. This is
  correctly regarded as a high-privilege combination; expect friction and design the
  onboarding to explain each grant honestly.
- **[A] — important and often missed:** TCC grants are keyed to the **code signature**.
  An ad-hoc-signed binary that gets rebuilt will likely have its grants invalidated
  repeatedly during development. Establishing a **stable signing identity before Phase 3**
  is probably necessary to stay sane. Needs confirmation (Phase 1).

---

## 10. Secure Input — the silent killer

Primary: [Apple TN2150 — Using Secure Event Input Fairly](https://developer.apple.com/library/archive/technotes/tn2150/_index.html)

- **[S]** Any process may call `EnableSecureEventInput()`. While it is held, **no other app can
  receive events through a CGEventTap.** Our hotkey stops working entirely — no error, no
  callback, nothing.
- **[S]** This is not hypothetical: 1Password has held it while not frontmost, breaking global
  hotkeys system-wide, and apps that fail to call `DisableSecureEventInput()` leave it stuck.
  Terminal's "Secure Keyboard Entry" menu item does the same — **and Terminal is on our target
  app list.**
- **[S]** `IsSecureEventInputEnabled()` lets us detect the condition.

**Design consequence:** `SecureInputMonitor` (ARCHITECTURE §3.8) is not defensive
over-engineering — it converts the single most baffling failure mode in this app class into a
legible message. There is no workaround; the only correct behaviour is to *say so clearly*.

---

## 11. Clipboard fallback specifics

Rules derived from **[V]** presspeech + **[S]** general practice:

1. Snapshot `NSPasteboard.general.changeCount` immediately after writing our text.
2. Post ⌘V; wait a short, bounded interval for the target to consume it.
3. Restore the previous contents **only if `changeCount` is unchanged.**
4. Never restore blindly — clobbering a user's clipboard is worse than leaving ours in it.
5. **[A]** The correct wait before restore is app-dependent and must be measured; too short
   truncates the paste, too long lets the user notice. Candidate for a per-app override.

---

## 12. Open questions requiring a spike

| # | Question | Blocks | Phase |
|---|---|---|---|
| Q1 | Can `en_US` **and** `es_ES` be allocated in `AssetInventory` simultaneously? Can one `SpeechAnalyzer` host two `SpeechTranscriber` modules? | Automatic language selection | 5 |
| Q2 | End-to-end latency key-up → text visible, for Apple vs Parakeet, at 3 s / 15 s / 60 s utterances | Engine choice | 5 |
| Q3 | ANE cold-start / warm-up cost for Parakeet after model load | Keep-warm strategy | 5 |
| Q4 | Measured insertion success matrix across all 9 target apps × 3 strategies | Insertion chain order | 6 |
| Q5 | Do TCC grants survive rebuilds under a stable self-signed identity? | Dev workflow sanity | 1 |
| Q6 | Real WER for **our** voice, English and Spanish, both engines | Engine choice | 5 |
| Q7 | Does `KeyboardShortcuts` expose key-up + bare-modifier binding? | Hotkey recorder UI | 3 |
| Q8 | Continuous-`AVAudioEngine` idle CPU/battery cost | Warm-engine strategy | 4 |

---

## 13. Sources

- FluidAudio — <https://github.com/FluidInference/FluidAudio> · issue [#303](https://github.com/FluidInference/FluidAudio/issues/303) · [API docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md) · [Benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)
- Parakeet TDT 0.6B v3 Core ML — <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml>
- WWDC25 session 277, *Bring advanced speech-to-text to your app with SpeechAnalyzer* — <https://developer.apple.com/videos/play/wwdc2025/277/>
- `SpeechTranscriber` — <https://developer.apple.com/documentation/speech/speechtranscriber>
- Apple TN2150, *Using Secure Event Input Fairly* — <https://developer.apple.com/library/archive/technotes/tn2150/_index.html>
- presspeech (MIT) — <https://github.com/rcourtman/presspeech>
- MacParakeet (GPL-3.0) — <https://github.com/moona3k/macparakeet> · <https://macparakeet.com/>
- argmax-oss-swift / WhisperKit (MIT) — <https://github.com/argmaxinc/argmax-oss-swift>
- swift-scribe (`SpeechAnalyzer` reference app) — <https://github.com/FluidInference/swift-scribe>
- yap (Apple Speech dictation, OSS) — <https://github.com/FrigadeHQ/yap>
- KeyboardShortcuts — <https://github.com/sindresorhus/KeyboardShortcuts>
- MacStories, *How Apple's New Speech APIs Outpace Whisper* — <https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/>

---

## 14. Local code signing without a paid Apple Developer account — **experiment results**

Run: **2026-08-22**, Phase 1. Constraint: no paid Apple Developer Program membership,
no Developer ID, no notarization, no recurring cost, personal use on this Mac only.

### 14.1 What TCC actually keys permissions to — **[V]**

TCC does not identify an app by path or by name. It stores a **designated requirement (DR)**
and re-evaluates it on every launch. Whether permissions survive a rebuild is therefore
entirely a question of whether the DR is stable. `codesign -d -r-` prints it.

Three signing approaches were tested against the same app bundle:

| # | Approach | Designated requirement produced | Stable across rebuilds? |
|---|---|---|---|
| A | **Ad-hoc** (`codesign -s -`) — this is what Xcode's *"Sign to Run Locally"* does | `cdhash H"<certificate-hash>"` | ❌ **No** |
| B | **Apple Development** (free personal team, already in the keychain) | `identifier "com.whisperingflow.dictation" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: …" and certificate 1[field.1.2.840.113635.100.6.2.1]` | ✅ Yes |
| C | **Persistent self-signed** (created locally, 20-year validity) | `identifier "com.whisperingflow.dictation" and certificate leaf = H"<certificate-hash>"` | ✅ Yes |

**[V] Approach A is disqualified.** Its DR is built from the **cdhash** — the hash of the
compiled code itself. Any code change produces a new cdhash, so *every rebuild that changes
anything revokes every granted permission.* This confirms the concern raised in ADR-011 and
settles it experimentally rather than by assumption.

**[V] Approach B works** and is genuinely free (a personal team from an ordinary Apple ID; no
$99 membership). Its one drawback is measured: the certificate on this machine is valid
`notBefore=2026-07-04` → `notAfter=2027-07-04`. It expires annually. When Xcode regenerates
it, the leaf CN stays the same but the certificate changes, and grants reset once per year.

**[V] Approach C is the most stable of the three** and is what we adopted.

### 14.2 The chosen configuration — **[V] verified working**

- **Identity:** a self-signed root named `Whispering Flow Local Signing`, created locally,
  RSA-2048/SHA-256, `extendedKeyUsage = codeSigning`, **7300 days (20 years)** validity.
- **Created by:** `Scripts/create-signing-cert.sh`, fully non-interactive.
- **Keychain:** login keychain, imported with `-T /usr/bin/codesign` and **deliberately not
  `-A`** — only `codesign` may use the private key, so no other process can mint code that
  would inherit this app's TCC grants.
- **Signing command:** `codesign --force --options runtime --entitlements … --sign "Whispering
  Flow Local Signing" --timestamp=none`
- **Hardened Runtime: on.** **App Sandbox: off.** **Notarization: none** (not needed —
  Gatekeeper only evaluates quarantined downloads, and this app is built locally).

**Two practical gotchas found and worked around — [V]:**

1. **PKCS#12 import fails with OpenSSL 3 defaults.** `security import` rejects the modern
   AES-256-CBC + SHA-256-MAC bundle with *"MAC verification failed during PKCS12 import
   (wrong password?)"* — a misleading error that is not about the password. The bundle must be
   written with `-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1`.
2. **A self-signed root reports `CSSMERR_TP_NOT_TRUSTED`** and is therefore absent from
   `security find-identity -v -p codesigning` (the *valid* list). This is cosmetic:
   `codesign` signs with it without complaint, `codesign --verify --strict` reports
   *"satisfies its Designated Requirement"*, and the app runs. Scripts must query
   `find-identity` **without `-v`**. No trust settings were added, so no admin
   authorisation was ever required.

### 14.3 Stability experiment — **[V] PASS**

Three consecutive builds, each with a genuinely different compiled output:

```
build 1 (v0.1.1): cdhash=42999d9331285f51…  binary=498c36494938
build 2 (v0.1.2): cdhash=44d2f31c21341b9c…  binary=dea4fc41ef04
build 3 (v0.1.3): cdhash=98f4a2d39fb59a90…  binary=59c9a9c65305

DR, identical throughout:
  designated => identifier "com.whisperingflow.dictation"
                and certificate leaf = H"<certificate-hash>"
```

The cdhash and the binary's SHA-256 changed on every build; the DR did not; the Microphone
grant survived all three. Reproduce with `./Scripts/verify-signing-stability.sh`.

> **Method note.** An earlier run of this experiment was **invalid** and the mistake is worth
> recording. Running the app's binary directly from a shell
> (`./WhisperingFlow.app/Contents/MacOS/WhisperingFlow --check-permissions`) reports the
> **terminal's** TCC grants, not the app's, because TCC attributes a shell-spawned process to
> its *responsible process*. The same probe reported `Microphone=granted` from the shell and
> `Microphone=notDetermined` when launched with `open` — same binary, same signature, same
> moment. **Any permission experiment must launch the app with `open` and read the result from
> OSLog**, which is why `DiagnosticsCommand.logSnapshot(tag:)` exists.

### 14.4 Entitlements — **[V]**

`com.apple.security.device.audio-input` plus `NSMicrophoneUsageDescription` were sufficient
for the microphone grant to be offered and recorded under Hardened Runtime with a self-signed
certificate. The presspeech warning in §5.1 — that a hardened app without the Hardened Runtime
audio-input key never receives the prompt at all — did not bite us, because the key was present
from the first build.

### 14.5 Answers to open questions

- **Q5 — do TCC grants survive rebuilds under a stable local identity? → YES, verified.**
  Requires a real certificate. Ad-hoc / "Sign to Run Locally" **fails**, and would have
  reset permissions on every single build.

---

## 15. Phase 2 walking-skeleton spike — results

Run: **2026-08-22**. macOS 26.5.2, M-series, Xcode 26.6, Swift 6.3.3.
Reproduce: `--spike-locales`, `--spike-asr`, `--spike-insert`, `--spike-dictate`.

### 15.1 Q1 — bilingual EN/ES with Apple's engine: **YES** — **[V]**

```
SpeechTranscriber.isAvailable : true
supportedLocales              : 30
  en: en_AU en_CA en_GB en_IE en_IN en_NZ en_SG en_US en_ZA
  es: es_CL es_ES es_MX es_US
maximumReservedLocales        : 5
reservedLocales (after)       : en_US, es_ES
Q1a  en + es reserved simultaneously        : YES
Q1b  one SpeechAnalyzer with two transcribers: constructed, modules=2
Q1b  bestAvailableAudioFormat for the pair  : 16000.0 Hz, 1 ch
```

**This unblocks automatic language selection.** Up to five locales can be reserved at once,
English and Spanish coexist, a single analyzer accepts both transcribers, and — importantly —
both agree on one audio format, so a single capture path can feed both without resampling.

`es_ES` was not preinstalled and downloaded in **11.4 s**; the `en_*` assets were already
present. Note `AssetInventory.reserve(locale:)` returned `false` for both while
`reservedLocales` nonetheless listed both afterwards, so the return value should not be
treated as success/failure — check `reservedLocales`.

### 15.2 The shipped Speech API differs from the WWDC-era documentation — **[V]**

Names taken from the session video and blog posts **do not compile**. Corrected against
`Speech.framework/…/arm64e-apple-macos.swiftinterface`:

| Used in §3 (wrong) | Actually shipped |
|---|---|
| `SpeechTranscriber.Preset.offlineTranscription` | `.transcription`, `.progressiveTranscription`, `.transcriptionWithAlternatives`, … |
| `AssetInventory.allocatedLocales` | `AssetInventory.reservedLocales` |
| `AssetInventory.deallocate(locale:)` | `AssetInventory.release(reservedLocale:)` |
| — | `AssetInventory.reserve(locale:)`, `.status(forModules:)`, `.maximumReservedLocales` |
| — | `SpeechAnalyzer.init(inputAudioFile:modules:finishAfterFile:)`, `analyzeSequence(from:)` |
| — | `isFinal` lives on `SpeechModuleResult`, not on `SpeechTranscriber.Result` |

**Lesson: read the `.swiftinterface`, not the blog posts.**

**[S] correction to §3:** custom vocabulary is *not* wholly absent from the new API —
`DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration:)` exists. It is on
`DictationTranscriber`, not `SpeechTranscriber`, so ADR-008 (dictionary as a post-processing
stage) still stands, but the claim "the new API has no custom vocabulary" was too broad.

### 15.3 Both engines run — **[V]**

Fixtures synthesised with `say`. **These are not accuracy results** (see 15.4).

| Fixture | Apple | Parakeet |
|---|---|---|
| en-short (2.4 s) | 247–316 ms, **exact** | 69–92 ms, **exact** |
| en-medium (8.6 s) | ~195 ms | ~77 ms |
| es-short (3.9 s) | ~170 ms | ~59 ms |
| es-medium (5.2 s) | ~75 ms | ~62 ms |

- **Parakeet is consistently faster per utterance** (RTF 26–113× vs 9–70×).
- **Setup cost is wildly different.** Parakeet's first run downloaded models for **291.8 s
  (~5 minutes)**; subsequent loads take **0.2 s**. Apple needed no download for English and
  11.4 s for Spanish, managed by the OS. For a personal app that one-time five minutes is
  survivable, but it is a real first-run experience difference, and it is ours to build UI for.
- Both mangled the personal-vocabulary terms (`Supabase`→"Superbase", `Vercel`→"Versal",
  `Seedance`→"Sedance"/"Seedans"). Parakeet got `Anthropic`, `Claude`, `OpenAI`, `Cloudflare`
  right where Apple did not. **Directly validates ADR-008** — these need a post-processing
  dictionary regardless of engine.

### 15.4 ⚠️ Synthetic speech is not a valid ASR benchmark — **[V], learned the hard way**

The first run produced Spanish output so bad that both engines emitted English words
("publicar" → "public", "producción" → "production"). The cause was **not** the engines:

**`say` exits 0 and silently substitutes the default English voice when the requested voice
name is not matched.** The fixture labelled Spanish was an English voice reading Spanish text.
Caught by comparing audio durations (5.20 s stored vs 3.93 s for a genuine Mónica render),
then fixed by validating against `say -v '?'` before generating and refusing to fall back.

Even with the correct voice, both engines degrade on the longer Spanish fixture. Compact TTS
voices are not representative of microphone speech, so **no accuracy conclusion should be drawn
from any of this.** Q6 still requires real recordings, in Phase 6, as planned.

The wider lesson is worth keeping: **a tool that "succeeds" is not the same as a tool that did
what you asked.** The same class of error nearly invalidated the Phase 1 signing experiment
(§14.3).

### 15.5 §1.1 confirmed by execution — **[V]**

The source-reading conclusion in §1.1 now has a runtime proof:

```
fixture: es-short (genuine Spanish audio)
  language: .spanish -> Hola, esto es una prueba de dictado local on español.
  language: .english -> Hola, esto es una prueba de dictado local on español.
  language: nil      -> Hola, esto es una prueba de dictado local on español.
  .spanish == .english : IDENTICAL (parameter is a no-op)
```

**Parakeet offers no English/Spanish control.** Combined with 15.1, this settles ADR-002's
central question in Apple's favour for the bilingual requirement — subject to the Phase 6
accuracy measurement on real speech.

### 15.6 Text insertion — **[V] where readback was possible**

Clipboard paste with the `changeCount` restore guard.

| App | Frontmost confirmed | Paste posted | Text verified in target |
|---|---|---|---|
| **TextEdit** | ✅ | ✅ 38 ms | ✅ **exact**, read back via AppleScript |
| **Terminal** | ✅ | ✅ 38 ms | ✅ **exact**, read back via `contents of front window` |
| **Chrome** | ✅ | ✅ 30 ms | ✅ **exact**, confirmed visually by the user (`<textarea>`) |
| **Safari** | ✅ | ✅ 33 ms | ❌ **landed in the address bar, not the textarea** |
| VS Code, Claude Code, WhatsApp | — | not run | pending |

Insertion latency is **30–38 ms** — negligible against transcription.

#### 15.6.1 ⚠️ Clipboard paste cannot tell you where the text went — **[V]**

The Safari run is the most useful result of the whole spike. The spike reported
`insert -> OK in 33 ms`, and the text landed in **Safari's address bar** — because Safari
focuses the address bar on a new window and the page's `autofocus` did not win. Nothing in the
insertion path noticed.

`insert -> OK` means only *"a ⌘V event was posted"*. It does not mean the text arrived, and it
does not mean it arrived **in the field the user was looking at**. Synthetic paste is
fire-and-forget: there is no return channel.

The consequences for the design are concrete:

1. **`FocusedTarget` must carry the focused element's AX role, not just the bundle id**, and
   the chain should decline to deliver when the focused element is not a text-entry role
   (`AXTextField`, `AXTextArea`, `AXComboBox`, or a web area with an editable descendant).
   Silently typing a user's dictated sentence into an address bar — or a search field, or a
   spreadsheet cell — is worse than refusing.
2. **This is an argument for attempting AX insertion first**, contrary to the lean towards
   clipboard-first suggested by presspeech in §5.1. AX is the only strategy that *knows*
   whether it succeeded, and getting the focused element for the AX attempt is exactly the
   probe needed to make the clipboard fallback safe. ADR-006 updated.
3. A post-insertion verification step (re-read the focused element's value and confirm it
   grew by the inserted text) is feasible for AX-visible targets and should be evaluated in
   Phase 7. It cannot work everywhere, but "verified where possible" beats "never verified".

**A safety lesson, from an actual mistake.** The first insertion test pasted into **VS Code**
instead of TextEdit: `osascript … activate` had not taken effect before the paste fired, and
the code pasted into whatever was frontmost. The spike now takes `--spike-expect <bundle-id>`
and **aborts rather than pasting into an unexpected app.** The production `InsertionChain`
must carry the same guard: capture the intended target at key-down and refuse to deliver if
focus moved. This is a correctness requirement, not a nicety — the failure silently writes the
user's words into the wrong document.

### 15.6.2 ⚠️ Closures inherit actor isolation from their enclosing scope — **[V], cost a crash**

The first live-microphone run printed `READY` and then died ~3 s later with `EXC_BREAKPOINT`
/ SIGTRAP on `RealtimeMessenger.mServiceQueue`:

```
_dispatch_assert_queue_fail
dispatch_assert_queue
_swift_task_checkIsolatedSwift
swift_task_isCurrentExecutorWithFlagsImpl
closure #1 in SpikeDictation.startAudioEngine()      <-- the audio tap callback
AVAudioNodeTap::TapMessage::RealtimeMessenger_Perform()
```

`AVAudioEngine.installTap` invokes its callback on a real-time audio thread. The callback was
written inline inside a method of a `@MainActor` class, so **Swift 6 inferred the closure as
MainActor-isolated**, inserted an executor assertion, and trapped on the first audio buffer.

The important part: **the first fix did not work.** Moving the state into an
`@unchecked Sendable` bridge so the closure captured nothing actor-isolated produced the
*identical* crash. Isolation is inherited from the **enclosing lexical scope**, not inferred
from what the closure captures. The closure has to be created somewhere with no isolation to
inherit:

```swift
nonisolated private static func installTap(on input: AVAudioInputNode,
                                           format: AVAudioFormat,
                                           bridge: AudioBridge) {
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        bridge.feed(buffer)   // no actor hop, no await, no logging
    }
}
```

**Consequences for Phase 5.** ARCHITECTURE §4 already required that the tap callback never
await and never touch actor state; this is what violating it actually looks like, and it is
not caught by the compiler — the build was clean with zero warnings both times.
`AVAudioEngineCapture` must therefore:

1. install its tap from a `nonisolated` context, never inline in a `@MainActor` method;
2. hand off through a `Sendable` box with an explicit lock (or a lock-free ring buffer);
3. be covered by a test that actually runs the engine for several seconds — a crash on the
   real-time thread is invisible to any test that never starts audio.

Also worth noting: `AudioBridge.feed` allocates an `AVAudioPCMBuffer` per callback. Acceptable
in a spike; a real-time-correct implementation should use a preallocated pool (Phase 5 / 11).

### 15.7 TCC attribution gotcha — **[V], affects all future testing**

`PermissionProbe` reports **different results for the same signed binary** depending on launch:

| Launch method | Microphone | Accessibility | Input Monitoring |
|---|---|---|---|
| `./WhisperingFlow.app/Contents/MacOS/WhisperingFlow` from a shell | granted | **denied** | **denied** |
| `open WhisperingFlow.app` | granted | granted | granted |

TCC attributes a shell-spawned process to its *responsible process* (the terminal). **Every
permission-dependent test must be launched with `open`**, which also means stdout is discarded
— hence `SpikeLog`, which mirrors everything to
`~/Library/Logs/whispering-flow-spike.log`.

### 15.8 Secure input

`IsSecureEventInputEnabled()` is wired into the spike and reports "not active" in the current
session. Deliberately **not** self-tested by calling `EnableSecureEventInput()`: if the process
died between enable and disable, secure input would remain stuck for the whole login session.
Left as a manual test (ACCEPTANCE_TESTS T-23).

### 15.10 ✅ End-to-end voice loop VERIFIED — **[V]**

Hold Right Option → speak → release → transcribe → insert at the cursor, in TextEdit,
macOS 26.5.2. Two consecutive runs, English, Apple `SpeechTranscriber`:

| | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| Held | 2590 ms | 2120 ms | 4411 ms |
| Audio buffers captured | 25 | 21 | 44 |
| Finalize (key-up → text ready) | 101 ms | 150 ms | 74 ms |
| Insert | 3 ms | 0 ms | 0 ms |
| **Key-up → text visible** | **105 ms** | **151 ms** | **76 ms** |

Spoken: *"this is my first local test"*. Inserted: `This is my 1st local test.` — exact,
at the cursor, target app never lost focus.

**Verified in TextEdit, VS Code, and Claude Code.**

**Q2 answered.** 76–151 ms end-to-end, an order of magnitude inside the Phase 11 target of
p95 < 1.5 s. Note that the **longest** utterance (4.4 s) produced the **fastest** finalize
(74 ms) — latency tracks how much audio remains unfinalized at key-up, not utterance length.
A batch engine would show the opposite curve.

**This validates the central claim of ADR-002.** Because audio streams into the analyzer
during the hold, key-up only has to *finalize* (101–150 ms) rather than start transcribing a
recording from scratch. A batch engine would have to process the whole utterance at release.
The streaming architecture is worth keeping as the default shape regardless of which engine
wins on accuracy.

### 15.11 ⚠️ Both engines already apply their own text formatting — **[V], affects Phase 8**

The user spoke *"first"*; the transcript reads **`1st`**. Nothing in our code did that — there
is no text pipeline yet. Apple's `SpeechTranscriber` supplied the capitalisation, the trailing
period, **and** the ordinal normalisation. Parakeet does something similar via its bundled
`NemoTextProcessing` FST.

So the assumption behind ADR-007 — that the pipeline receives a raw transcript and adds all
formatting — is **wrong**. The pipeline receives text that has already been formatted by an
engine, differently per engine, and not under our control.

A second run makes the case sharper. Spoken: *"...just give me your opinion, I don't want you
to do anything yet"*. Transcribed:

```
Just give me your opinion. don't want you to do anything yet.
```

The engine capitalised `Just`, inserted a sentence-ending period — and then left `don't`
**lowercase after that period**. It also dropped the `I`. So engine formatting is not merely
"already done"; it is **internally inconsistent**. Our capitalisation stage is therefore not
redundant after all: it has real work to do, but it must be written to fix under-application
without double-applying where the engine already got it right.

Implications to settle in Phase 8:

1. **Capitalisation and terminal punctuation stages are still needed, but must be idempotent.**
   The engine applies them inconsistently (see above), so the stage has to repair gaps without
   double-applying. Test against real engine output, never hand-written raw strings.
2. **Number/ordinal normalisation is a product decision we have not made.** `1st` vs `first`,
   `20` vs `twenty`. It is engine behaviour today, and inconsistent across engines. If we want
   a consistent result we need a stage that *normalises the normalisation*.
3. **`RawTranscript` is a misleading name** for what `SpeechEngine` returns. Rename, or
   document clearly that it is engine-formatted text, not raw tokens.
4. Golden-file tests (Phase 8 criterion 10) must be captured **per engine**, since switching
   engines changes pipeline input.

### 15.9 Answers and remaining gaps

| Question | Status |
|---|---|
| Q1 simultaneous en/es | **Answered: YES** (15.1) |
| Q2 end-to-end latency | **Answered: 105–151 ms** key-up → text visible, real speech (15.10). |
| Q4 insertion matrix | **Partial.** TextEdit, Terminal, Chrome verified; Safari posted but unconfirmed; VS Code / Claude Code untested. |
| Q5 TCC across rebuilds | **Answered: YES** (§14) |
| Q6 real WER | **Not started** — needs real speech, Phase 6 |
| **Voice loop end-to-end** | **✅ VERIFIED** in TextEdit (15.10). |

---

## 16. Long-form real-speech test — and what it says about the text pipeline

Run: **2026-08-22**, real dictation by the user, Apple `SpeechTranscriber`, en-US.

### 16.1 Capture is not the problem — **[V]**

```
held:      40907 ms   (40.9 s)
buffers:   409
finalize:  89 ms
insert:    1 ms
KEY-UP -> TEXT VISIBLE: 90 ms
```

**No truncation, no drop-out, no slowdown.** A 41-second utterance finalized in 89 ms — faster
than the 2.5-second ones, because almost all of it was already finalized during the hold.
**T-04 (long dictation) passes.** Whatever is wrong, it is not capture, latency, or duration.

### 16.2 The errors, and which layer can actually fix each — **[V]**

Verbatim engine output, with the user's corrections:

| Error | Should be | Class | Fixable by |
|---|---|---|---|
| `ductation` | dictation | phonetic, common word | dictionary |
| `glock code` | Claude Code | phonetic, proper noun | dictionary |
| `Whisper Flow` | Wispr Flow | proper noun | dictionary |
| `how effect this is could be` | how effective this could be | garbled grammar | **LLM only** |
| `native for` | natively for | garbled grammar | **LLM only** |
| `no, actually, or yeah` | (abandoned false start) | self-correction | **LLM only** |
| `like` ×3, `basically`, `actually` | — | filler | deterministic |

### 16.3 Deterministic vs LLM, measured — **[V]**

Four variants over the same transcript (`--spike-cleanup`). Apple Foundation Models,
on-device, `temperature: 0.1`.

| | Proper nouns | Fillers | Garbled grammar | Content preserved |
|---|---|---|---|---|
| **A** deterministic only | ✅ all three | ✅ | ❌ | ✅ |
| **B** LLM only | ❌ `ductation` kept; `glock code` → **`Glock Code`** | ❌ kept | ✅ | ❌ **dropped "And so on."** |
| **C** deterministic → LLM | ✅ | ✅ | ✅ | ✅ |
| **D** deterministic → LLM, longer prompt | ✅ | ✅ | ❌ regressed | ✅ |

**Four findings, none of them obvious in advance:**

1. **The two layers fix disjoint error classes.** Neither is a substitute for the other.
   The deterministic pass cannot repair grammar; the LLM **did not fix a single proper noun** —
   it left `ductation` untouched and turned `glock code` into `Glock Code`, i.e. confidently
   wrong. The personal dictionary is not a stopgap until the LLM arrives; it is the only thing
   that handles its class of error.
2. **Order matters, and deterministic must come first.** Running the LLM on raw input (B)
   silently **dropped a sentence**. Giving it pre-cleaned input (C) preserved everything —
   less work for the model means less drift. This is the opposite of the intuition that the
   LLM should see the rawest possible input.
3. **A longer, more explicit prompt made things worse** (D regressed on the grammar fix that C
   got right). Prompt quality is not monotonic in prompt length; it needs measurement, not
   reasoning.
4. **Output is stable.** Variant C produced byte-identical output across three consecutive
   runs at `temperature: 0.1` — which removes the main objection to putting a model in this
   path.

Also worth noting: deterministic filler removal **broke capitalisation** (`Like, for example`
→ `for example`), and the LLM repaired it. Stages interact; the pipeline cannot be validated
stage-by-stage alone.

### 16.4 What nothing fixed

`no, or yeah` — the abandoned false start — survived every variant, as did `native for`.
Self-corrections mid-sentence remain the hardest class. Apple's on-device model is roughly
3B-class; a larger cloud model would likely handle them, but that is off the table by design.

### 16.5 Guardrails — **[V]**

`SystemLanguageModel.default` **refuses this task outright**: every attempt returned
*"I'm sorry, but I cannot assist with this request."* The model reads a dictated transcript as
a request addressed to it. Two changes were needed:

1. `SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)`
2. Wrapping the transcript in explicit delimiters so it reads as data, not instruction.

Any future LLM stage must do both, and must treat a refusal as a normal outcome that falls
through to the deterministic result.

### 16.6 Cost

**+1.3 s** on-device (1297–1779 ms), against a current end-to-end of 76–151 ms. That consumes
essentially the whole p95 < 1.5 s budget from Phase 11.

Mitigation worth testing in Phase 9: **length-gate the LLM.** Short utterances are mostly
clean and are where latency is most noticeable; long-form is where the grammar errors cluster
and where a second of latency is proportionally invisible. Run the model only above a word
threshold.

### 16.7 Consequence: ADR-007 was wrong on one point

ADR-007 said "no LLM in V1", on the reasoning that deterministic processing would be
sufficient and an LLM would mask pipeline bugs. The first is now falsified for this user's
actual speaking style: **three of the seven observed error classes are unreachable by any
deterministic rule.** The second still holds, which is exactly why the LLM stays a *later*
stage operating on already-cleaned text rather than a replacement for the pipeline.

The staged architecture itself is vindicated — adding the model is appending a stage, and
required no change to `TextStage`, `TextPipeline`, or any other module.

---

## 17. Phase 3 — macOS behaviour discovered while building the shell

### 17.1 ⚠️ `AVCaptureDevice.authorizationStatus` caches per-process — **[V]**

Revoking Microphone with `tccutil reset Microphone com.whisperingflow.dictation` **while the
app was running** produced **no change** in the app's own reading for the following 6 seconds,
across three poll cycles. A process launched immediately afterwards reported
`Microphone=notDetermined` for the same bundle.

So the microphone grant is read once and cached for the lifetime of the process. **A running
app cannot detect its microphone permission being revoked.**

Consequences:

- The permission poller can detect a *grant* being added (the user acting on our prompt) but
  cannot be relied on to detect one being *removed*.
- The real signal that microphone access is gone is `AVAudioEngine` failing to start. Phase 5
  must treat an audio-start failure as a permission hypothesis, not only as a hardware error.
- The menu is therefore honest about Accessibility and Input Monitoring, and optimistic about
  Microphone, until capture is attempted.

**Not established:** whether `AXIsProcessTrusted()` and `IOHIDCheckAccess` cache the same way.
The test that would have settled it did not run, and re-testing costs the user their granted
permissions, so it is left open rather than guessed at. Phase 4 and Phase 7 exercise both APIs
continuously and will answer it as a side effect.

### 17.2 `SMAppService` works from an unbundled build location — **[V]**

`SMAppService.mainApp.register()` succeeded from `build/WhisperingFlow.app` (status
`Enabled`), and `unregister()` returned it to `Not registered`. Login-item registration does
not require the app to live in `/Applications`.

The stored preference and the system state can diverge — the user can remove a login item
while the app is not running — so `AppEnvironment.reconcileLaunchAtLogin()` adopts the system
value at launch. Verified: with the preference forced to `true` and the system unregistered,
the app logged `launch-at-login drift: stored true, system false — adopting system` and
corrected the stored value.

### 17.3 An `.accessory` app needs a policy flip to show a window — **[V]**

A `.accessory` app's windows cannot take keyboard focus and cannot be dismissed with ⌘W.
`SettingsWindowController` raises the app to `.regular` while settings are open and drops back
to `.accessory` on close, so the app leaves the Dock and app switcher again. The same applies
to modal alerts.

### 17.4 A SwiftPM executable target's symbols cannot be imported by tests — **[V]**

Test targets cannot `@testable import` an executable target. The app was therefore split into
`WhisperingFlowKit` (a library holding all logic) and a thin `WhisperingFlow` executable that
does nothing but start the app. The public surface of the kit is deliberately two symbols —
`AppDelegate` and `DiagnosticsCommand` — with everything else internal and reached by tests via
`@testable`.

---

## 18. Phase 4 — production global push-to-talk: measured behaviour

Everything here was measured against the signed app on the target machine
(macOS 26.5, Apple silicon), not inferred from documentation.

### 18.1 A threshold-delayed `begin` costs exactly the threshold

`begin` fires when the hold timer elapses, not on the physical key-down, so an
accidental modifier tap cannot open a session. The cost is bounded and small:

| Edge | n | min | p50 | p95 | max | mean |
|---|---|---|---|---|---|---|
| press → `begin` | 20 | 150.46 ms | 151.16 ms | 151.18 ms | 151.21 ms | 150.99 ms |
| release → `end` | 20 | 0.01 ms | 0.02 ms | 0.03 ms | 0.03 ms | 0.022 ms |

Configured threshold: **150 ms**. Timer overshoot is therefore **0.46–1.21 ms**,
p95 overshoot 1.18 ms. `Timer.tolerance = 0` is doing its job; the run loop is
not adding meaningful jitter even with a SwiftUI settings window in the process.

The release path is effectively free — 22 microseconds mean from the timestamp
captured inside the tap callback to `onRelease` firing. Whole-millisecond
logging floored all of these to `0 ms` in the first run and had to be widened to
two decimals before the number meant anything.

**Consequence for Phase 5:** the first ~151 ms of speech is not captured. Audio
capture must run a pre-roll ring buffer and splice it in, or the beginning of
every utterance is lost. This is the single most important carry-forward from
Phase 4.

### 18.2 150 ms is the right threshold, measured

Deliberate quick taps of Right Command — the motion of using it as an ordinary
modifier — measured **72, 80, 72, 80 and 71 ms** (n=5). Intentional holds were
all well over 400 ms. The gap between the two populations is wide, and 150 ms
sits in the middle of it with roughly 2× margin on the accidental side. All 5
taps were swallowed with no `begin` and no `end`; all 32 intentional holds
opened a session.

No evidence was found for changing the threshold. It stays at 150 ms, and the
measurement above is the reason rather than the fact that it was the initial
guess.

### 18.3 `CGEventSource.flagsState` **does** carry the device-dependent bits

Sampling `CGEventSource.flagsState(.combinedSessionState)` while Right Command
was physically held returned `0x00100110` — bit `0x10` is `NX_DEVICERCMDKEYMASK`.
With nothing held it returned `0x00000100` (`NX_NONCOALSESCEDMASK` only).

So the live hardware modifier state is pollable *with* left/right discrimination.
This was investigated as a way to repair a suspected missed key-up. The key-up
turned out never to have been missed (§18.4), so nothing was built on it — but it
is recorded here because it is the mechanism a hung-session watchdog would use
if one is ever needed, and it is not obvious that the API preserves those bits.

### 18.4 A stale preference impersonated a lost key-up for three minutes

Symptom: a session began, the user released the key, and the app stayed
`listening` for 2 m 41 s. It looked exactly like the event tap had dropped a
`flagsChanged` key-up, and the first hypotheses were all about the tap —
`.tapDisabledByTimeout`, WindowServer grabs during app switches, Secure Input.

All wrong. `hotkey.triggerMode` was persisted as `toggle` from Phase 3 settings
testing. In toggle mode releasing the key *is* a no-op; the session was waiting
for a second press, which is correct behaviour.

Two things made this expensive, and both are now fixed:

1. **The menu said "Hold Right Command to dictate" regardless of trigger mode.**
   A toggle-mode app that instructs the user to hold looks broken in precisely
   the way a dropped key-up looks broken. `MenuBarModel.triggerInstruction` now
   follows the mode, and a test asserts the toggle string never begins "Hold ".
2. **There was no way to see what the tap actually received.** Adding
   `--trace-hotkey`, which logs modifier *names* on every `flagsChanged`
   transition together with the gesture phase, identified the cause in one run.
   The trace deliberately records no key codes and no characters — the tap sees
   every keystroke on the system, including passwords — so it can show that a
   modifier changed but can never reconstruct what was typed.

Debugging lesson worth keeping: the trace line that settled it showed
`session end` firing on an event where Right Command was still **present** in the
modifier set. A state machine ending on a *press* is a mode bug, not a lost
event, and the raw event stream said so immediately.

### 18.5 A stored binding can point at a key that does not exist

The same preferences held `hotkey.keyCode = 105` (F13). This keyboard has
F1–F12 only. The result is an event tap that installs successfully, receives
every keystroke on the system, and can never fire — a completely silent failure
that `isTapInstalled` reports as healthy.

Two mitigations, both in place:

- `SettingsStore.migrate` drops a stored binding that is no longer in
  `HotkeyBinding.selectable` and falls back to the default, logging the change.
- `HotkeyBinding.selectable` was trimmed to keys that exist on this keyboard.
  F13–F19 and Right Control are gone.

`HotkeyDiagnostics.Health` already distinguishes the three ways a hotkey can
appear dead — `.notStarted`, `.installedButSilent` (stale Input Monitoring), and
`.receivingButUnmatched` (binding does not match what the user is pressing) —
and the third is what this case would now surface in the menu.

### 18.6 `.listenOnly` does not interfere with the modifier it observes

Across 134 observed modifier transitions with the tap live: `⌘A`, `⌘C`, `⌘V`,
`⌘Z`, `⌘Tab`, `⌘Space`, `⌘W` all behaved normally, Right Option still composed
`ó`, and ordinary typing showed no dropped or duplicated characters. The tap
never consumes an event, which is the only safe posture for a binding that is
itself a live system modifier.

Modifier changes *while the trigger stays held* are correctly ignored: at
02:20:33 the set went `[Right Command]` → `[Left Shift, Right Command]` →
`[Right Command]` → `[none]`, and only the last transition ended the session.

### 18.7 Tap stability

Zero `.tapDisabledByTimeout` and zero `.tapDisabledByUserInput` events across the
whole Phase 4 session — 52 sessions, 154 modifier transitions, roughly 25 minutes
of uptime. The recovery path therefore has **not** been exercised against a real
disable; it is covered by unit tests only, and that limitation is recorded in
ACCEPTANCE_TESTS rather than being written up as a pass.

---

## 19. Phase 5 — production audio capture: measured behaviour

### 19.1 The microphone, not the hold threshold, is the binding constraint

Phase 4 said `begin` arrives 151 ms after the physical press, so Phase 5 was
built to capture from the press and splice the pre-roll in. That works. But
measuring what is actually *in* the pre-roll produced a more important number.

Asking the user to hum continuously **before** pressing, so the whole capture
window contains a known signal, gives this shape every time (5 ms windows):

```
0–30 ms    small decaying transient (microphone turn-on)
30–160 ms  DIGITAL SILENCE — exact zeros, despite continuous humming
165 ms+    the hum
```

Measured across the whole session:

| Stage | n | min | p50 | max |
|---|---|---|---|---|
| physical press → `engine.start()` returned | 24 | 44.24 ms | 52.64 ms | 56.20 ms |
| physical press → first buffer delivered | 19 | 146.76 ms | 155.08 ms | 159.33 ms |
| pre-roll audio retained at promotion | 19 | 85.00 ms | 85.31 ms | 104.00 ms |
| release → clip finalised | 43 | 12.15 ms | 12.89 ms | 13.82 ms |

So on this hardware the built-in microphone produces **no usable audio for its
first ~165 ms**. The pre-roll faithfully captures 85–104 ms — and that 85–104 ms
is silence, because the ADC has not settled.

The consequence is worth stating plainly: on this machine the pre-roll currently
buys close to zero *usable* audio, because microphone warm-up (~165 ms) happens
to land just past the hold threshold (151 ms). The architecture is still correct
and costs nothing — a faster microphone, a shorter threshold, or a longer
warm-up on other hardware all change the arithmetic, and only the pre-roll makes
the app robust to that. But the honest statement is that "speak the instant you
press" is currently delivered by human reaction time exceeding microphone
warm-up, not by the pre-roll.

Verified against real speech: saying a hard "K" as fast as possible on key-down
put the onset at 220–430 ms into the clip. Nothing was ever clipped.

**The only way to remove the ~165 ms floor is to have the engine already
running**, which Phase 5's brief explicitly rules out. That trade is recorded in
ADR-019 rather than being quietly re-litigated.

### 19.2 `AVAudioConverter` leaks audio across sessions

The most serious defect found in Phase 5, and it was only visible because the
hum test put a known signal in the capture window.

Every clip opened with a short decaying transient — and its amplitude tracked
**the previous recording's** level, not the current one: 0.018 after a hum at
0.011, 0.003 after near-silence. A retained `AVAudioConverter` carries its
resampler's delay line across uses, so the tail of one utterance emerges at the
head of the next.

`converter.reset()` did **not** clear it. Only building a fresh
`AVAudioConverter` per capture did.

The decisive test: record a loud hum (body level 0.142), then immediately record
silence. The silent clip's leading transient was **0.0008** — the noise floor,
178× smaller than the previous clip's body. Before the fix it would have been
proportional to 0.142.

This matters beyond fidelity. After a **cancelled** session, the leaked tail is
audio the user explicitly asked to discard, reappearing at the front of their
next dictation. That is a privacy defect, not merely a glitch.

Cost of the fix: one `AVAudioConverter` allocation per key-press, which is
inside the noise of the 44–56 ms engine start.

### 19.3 Setting the input device fires a configuration-change notification

`AUAudioUnit.setDeviceID` reconfigures the engine and posts
`AVAudioEngineConfigurationChange`. The first implementation called `prepare()`
on every key-press and treated any configuration change during capture as a
device disconnect — so **the first press after every launch failed** with
"Audio capture did not start."

Three corrections, all of which also bought latency back:

1. Prepare once at launch, not per press. This alone removed 52 ms from the
   pre-roll budget.
2. Only call `setDeviceID` when the device actually differs from the current one.
3. In the change handler, do **not** clear the cached device ID — re-setting it
   is what posts the notification, so clearing it loops forever.

### 19.4 Real-time safety is asserted at runtime, not assumed

Phase 2 established that a closure written inside an `@MainActor` scope inherits
that isolation whatever it captures, and traps on the first audio buffer
(§15.4). Phase 5 builds the tap closure in a `nonisolated static` context, as
required — but "it compiles with zero concurrency warnings" is not evidence that
the callback is off the main thread.

So `CaptureBuffer` records `Thread.isMainThread` once per capture and the service
logs an error if it is ever true. Across 24 captures: **0 occurrences**. That is
evidence; the absence of warnings was not.

The tap callback allocates only the converter's output buffer, holds the lock
only around the append, and does no logging, file I/O or actor hops. Sample
accounting confirms it kept up: **0 overflow frames and 0 stray buffers across
every recording**, including 75.1 s.

### 19.5 Bounded memory, measured

`CaptureBuffer` reserves its 5-minute ceiling up front so the real-time thread
never reallocates. `malloc` is lazy, so resident memory tracks actual audio
rather than the reservation.

Over 600 samples at 0.5 s intervals spanning the whole test session:

- idle, microphone closed: **40.7 MB**, **0.0 % CPU**
- peak during a 75.1 s recording: **49.2 MB** (Δ 8.5 MB)
- CPU: max **1.5 %**, mean **0.05 %**

75.1 s × 16 kHz × 4 bytes = 4.8 MB of samples, so the measured 8.5 MB is the
clip plus the debug WAV export buffer. Memory returns to baseline after each
session.

Durations exercised, all with zero overflow: 1.19, 1.30, 1.30, 1.40, 2.19, 3.70,
3.89, 3.99, 4.49, 4.49, 4.68, 5.01, 5.10, 8.99, 25.99, 53.41, **75.10** s.

### 19.6 The splice cannot be proven from a waveform

The obvious verification — look for a discontinuity where the pre-roll joins the
session — does not work, because on this hardware that region is digital silence
(§19.1). Every splice-zone probe returned a step of exactly 0.00000, which
proves no artefact was *introduced* but says nothing about sample-exactness.

Sample-exactness is therefore proven where it can be: `CaptureBufferTests` drives
a monotonically increasing ramp through the buffer, so any dropped, duplicated or
reordered frame breaks the sequence. The boundary sweep covers 20 promotion
positions (0–4 chunks plus tails of 0, 1, 7 and 1023 frames), and a separate test
runs 50 rounds of a concurrent producer against a main-thread promotion,
asserting the result is a contiguous run.

This is recorded because the instinct to "verify it on real audio" was right, and
the reason it could not work is not obvious.

---

## 20. Phase 6 — production transcription: measured behaviour

### 20.1 The production architecture reproduces the spike exactly

All 20 Phase 2.5 recordings, replayed through the production `AppleSpeechEngine`:
**20 identical, 0 differing**, across both locales and 2.0–40.0 s clips.
Reproduced on two separate runs. `CORPUS_VALIDATION.md` holds the snapshot.

That is the result the corpus validation existed to get. Streaming delivery,
Float32→Int16 requantisation, per-session analyzer teardown and the actor
boundary are all new, and none of them changed a single character of output.

### 20.2 Streaming inverts the latency curve

Key-up → finalised `EngineTranscript`, live:

| Audio | Locale | key-up → transcript |
|---|---|---|
| 2.99 s | en-US | 15.6 ms |
| 4.89 s | en-US | 174.4 ms |
| 5.29 s | es-ES | 89.2 ms |
| 6.29 s | en-US | 116.9 ms |
| 8.40 s | en-US | 141.8 ms |
| 25.09 s | en-US | **49.9 ms** |
| 33.39 s | es-ES | 71.3 ms |
| 37.99 s | es-ES | 86.6 ms |

**Longer utterances finalise faster than short ones.** With more speech behind
it the analyzer has already consumed nearly everything, so release only drains a
short tail; a 3-second utterance can still have a proportionally larger tail
outstanding. This inversion is the signature of streaming working. A batch
implementation shows the opposite slope, and the corpus harness — which *is*
batch — demonstrates it: 32 s of audio took 531 ms there against 49.9 ms live.

Comparison with the Phase 2 spike baseline of 76–151 ms: production sits in the
same band, 15.6–174.4 ms. The spike measured key-up → *text visible* including
clipboard insertion; production measures key-up → finalised transcript, with
insertion still to come in Phase 7. Like for like, nothing was lost.

### 20.3 A synchronous pre-roll handler silently moved the hold threshold

`onTriggerPressed` starts `AVAudioEngine` synchronously, which Phase 5 measured
at ~53 ms. The hold timer was armed *after* that, for `deadline - eventTimestamp`
— its full 150 ms — so `begin` landed at **199–209 ms** instead of 151 ms.

The threshold ADR-016 locked on measured evidence had quietly changed, and
nothing failed: no test, no warning, no user-visible symptom beyond a hold that
felt slightly heavier. It was only visible because Phase 4's latency logging was
still running during Phase 6 live testing.

Fix: arm for `deadline - now`, so any delay in an earlier handler is absorbed
rather than added. Verified back to **p50 151.14 ms** (n=10) against Phase 4's
151.16 ms, and covered by two unit tests that inject a slow `onTriggerPressed`.

The general lesson is worth keeping: **a handler added to an existing sequence
inherits none of that sequence's timing guarantees.** Anything that measured a
threshold before a new synchronous call was inserted must be re-measured after.

### 20.4 Apple's analyzer wants Int16, and asks for it explicitly

`SpeechAnalyzer.bestAvailableAudioFormat` returns **16 kHz 1 ch i16** on this
machine, confirming the Phase 2.5 discovery. `AudioClip` is Float32 at the same
rate, so the conversion is a pure requantisation via `PCMConversion` — no
resample, and unit-tested for clipping, silence preservation, quiet-speech
resolution, monotonicity and statelessness.

Scaling uses **32767, not 32768**: `Float(1.0) * 32768` does not fit in `Int16`
and traps in Swift rather than wrapping, so a single loud sample would crash the
app. Out-of-range input clamps rather than wrapping, because a wrapped loud
syllable becomes full-scale noise of the opposite sign — far worse for a
recogniser than flat clipping.

Corpus conversion cost, including WAV parsing: **p50 0.40 ms** per clip.

### 20.5 Accuracy observations

**English** is clean on ordinary speech. A 25-second unscripted paragraph came
back with correct punctuation and sentence breaks; the only errors were on
proper nouns and one homophone ("stop" for "stub").

**Spanish** is likewise clean on ordinary speech, including accents, and handled
a 38-second unscripted monologue with correct punctuation. Two error classes
appeared: an accent that changes meaning (`Me llamó` for `Me llamo` — "he called
me" versus "my name is"), and the same technical term rendered three different
ways inside one utterance (`duchboards`, `duchashboard`, `Dashboard`).

**Technical vocabulary fails exactly as Phase 2.5 and 2.6 predicted.**
"Deploy the Supabase edge function with Claude Code and check Cloudflare" came
back as *"Deploy the superbase edge functions with cloud code, uncheck cloud
flare."* Every technical term missed.

This is not a Phase 6 defect. ADR-014 locked a deterministic dictionary
downstream for exactly these terms, and Phase 2.6 established that engine-level
biasing does not fix it (11/34 with SpeechTranscriber, and the one approach that
worked — Parakeet + CustomVocabulary at 31/34 — is English-only and therefore
invalid for a bilingual user). The engine's job is recognition; the dictionary's
job is these words. Phase 7 is where the sentence above becomes correct.

### 20.6 No network, measured

357 samples at 0.5 s intervals across the whole live session, including 12
transcriptions in two languages: **maximum 0 open TCP or UDP sockets**. Assets
were already installed; recognition made no network call at any point.

Memory 60.9 → 75.2 MB peak (Δ 14.3 MB, covering two loaded language models and
a 38-second dictation). CPU max 6.6 %, mean 0.27 %.

Asset preparation with models already installed: **en-US 6.1 ms, es-ES 2.4 ms**.
Both locales are reserved at launch, which is why EN → ES → EN needs no restart
and costs nothing at switch time.

---

## 21. V1 milestone — the first daily-usable build

### 21.1 End-to-end latency, measured live

Fast mode, English, across the application matrix:

| Payload | transcript | process | insert | **end-to-end** |
|---|---|---|---|---|
| 24 chars | 122.7 ms | 4.2 ms | 1.5 ms | **143.6 ms** |
| 82 chars | 119.8 ms | 4.2 ms | 10.0 ms | **146.5 ms** |
| 316 chars | 55.8 ms | 5.8 ms | 8.4 ms | **86.1 ms** |
| 733 chars | 86.1 ms | 4.7 ms | 17.4 ms | **119.1 ms** |
| 769 chars | 159.1 ms | 4.8 ms | 8.5 ms | **187.4 ms** |

**Fast mode is 86–187 ms key-up to text on screen**, and the length of the
dictation barely matters — recognition streams during speech (ADR-020) and the
deterministic pipeline is ~5 ms regardless.

Smart mode, same 46-second passage: **2207 ms** end-to-end, of which 2004 ms is
the model. That is above the ~1.5 s Phase 2.5 projection for long input.

Insertion by strategy: accessibility 1–26 ms where it works (native fields),
clipboard 122–133 ms everywhere else (Electron, web views).

### 21.2 The regex cache: 16 ms → 0.11 ms

The vocabulary stage originally compiled all 48 rules on every dictation, which
measured **13–24 ms** — a fifth of the entire Fast-mode budget, spent
re-deriving something that never changes. Caching compiled patterns by spoken
form brought it to **0.10–0.47 ms**, a ~100× reduction, and the cache is bounded
by the size of the dictionary.

Worth noting because it was invisible until the per-stage timings were logged
separately. A single "processing: 30 ms" number would never have located it.

### 21.3 Spanish re-spells English product names differently every run

The most important quality finding, and the main remaining gap.

Reading the *same* Spanish sentence containing "Supabase, Cloudflare y Claude
Code" produced a different mangling every time:

| Intended | Observed spellings across runs |
|---|---|
| Supabase | `su pae`, `su pabase`, `su papage`, `supage`, `supaves`, `super bes`, `superbase` |
| Claude Code | `Clo Code`, `Clocode`, `cloud co`, `cloud code`, `clock code` |
| Cloudflare | `cloud flare`, `cloud flair`, `Clauud`, `Claude Flair` |

English is far more stable: the same passage read twice produced `Whisper Flow`
both times, and the other errors were ordinary homophones (`feeler`/`filler`,
`corsar`/`cursor`).

The mechanism is plausible: a Spanish acoustic model has no representation for
these English words, so it assembles them from Spanish phonemes, and small
differences in delivery produce entirely different assemblies. English at least
lands in a consistent neighbourhood.

**Consequence for the product.** A deterministic dictionary can only catch what
it has already seen, so Spanish technical dictation is whack-a-mole in a way
English is not. 20 variants are now shipped and every one came from a real run,
but the next Spanish session will likely produce a spelling not in the list.

Phase 2.6 already established that engine-level biasing does not fix this: Apple
gave 11/34, and the one approach that worked — Parakeet + `CustomVocabulary` at
31/34 — is English-only and therefore invalid for a bilingual user. Fuzzy
matching was considered and **rejected for now**: matching "supaves" to
"Supabase" by edit distance would also match Spanish words that merely look
similar, and a wrong replacement is worse than a missed one.

### 21.4 Two insertion bugs that only live testing could find

Both are written up in ADR-023; the pattern is what belongs here.

Each was invisible to unit tests, produced no error, and looked like success in
the log. The first wrote a sentence into Safari's address bar; the second typed
placeholder text the user never said into VS Code and Codex, and duplicated the
utterance. In both cases the code reported `inserted`.

The lesson is specific: **for insertion, "the API returned success" is not
evidence.** The only trustworthy signals are structural — where the element sits
in the accessibility tree — and verification by reading back what actually
landed. Anything else is a guess dressed as a result.

### 21.5 A non-isolated `async` protocol requirement crashed the app

`TextProcessing.process` is a non-isolated `async` requirement, so it runs on
the cooperative pool. The composition root reached the vocabulary store through
`MainActor.assumeIsolated`, and the app took **SIGTRAP on the very first real
dictation** — dead before a single character was inserted.

This is the same executor-assertion failure as the Phase 2 audio tap (§15.4),
in a new place, three phases later, despite the earlier one being documented in
a comment two files away.

The general rule, now stated plainly: **`assumeIsolated` is only safe where the
isolation is guaranteed by the call site, and a protocol requirement's isolation
is part of its signature, not its caller's.** Declaring `@MainActor` on the
closure and awaiting it makes the hop explicit and the mistake impossible.

Every unit test passed throughout, because they all ran on the main actor. The
regression test now calls `process` from a detached task.

---

## 22. Field feedback — three weeks as the only dictation tool

Source: a defect log kept during daily use, 24 Aug – 15 Sept 2026.

### 22.1 Smart mode was timing out on ordinary messages, invisibly

A live-instrumented Smart run took **3988.88 ms for 1282 characters** against a
flat 4000 ms budget — 11 ms of headroom. Every longer message timed out and
inserted the Fast text, and nothing told the user. The experience was "Smart
does nothing sometimes."

Measured cost is 2.7–3.1 ms per character (740 → 2004 ms, 1282 → 3989 ms). The
budget is now `clamp(2 s + 6 ms × chars, 4 s, 15 s)`: twice the measured rate,
the old floor, and a ceiling past which the wait itself is the failure. 1282
characters now gets 9.7 s.

A fallback now changes the menu-bar icon (`text.badge.xmark`) until the menu is
opened, and the menu states the reason and that Fast text was inserted.

**Not fixed, recorded:** Smart still does not collapse repeated false starts
("I agree that we have to add, I agree that we have to add") despite instruction
rule 3. The prompt is a measured artifact (§16); changing it needs a benchmark
rerun, not a guess.

### 22.2 The vocabulary lever was invisible

After three weeks of daily failures on the same names — `Soneto`, `cortex`,
`Woodley`, `claw` — the dictionary held **zero** user-added rules. The fix
existed and was never found.

Two changes. The dictionary gained 13 shipped rules (spoken forms that are not
ordinary words) and 18 personal rules (spoken forms that *are* real words, such
as `soneto`, which is Spanish for a sonnet and so is invisible as an error).
And the menu gained **Add Correction to Vocabulary…**, which reads the selected
text in the frontmost app and opens the Vocabulary tab pre-filled — the lever
now sits where the failure is.

Automatic detection of a hand-correction after insertion was considered and not
built: it means observing text fields after every dictation, which is both a
privacy expansion and unreliable across Electron apps.

### 22.3 The character corruptions did not come from this app

Nine strings were logged as left in inserted text: `profitbale`, `macthes`,
`defintiely`, `pragraph`, `professionak`, `aquire`, `axctually`, `Anyyone`,
`ANyone`.

None can be produced by any code path here:

- **Recognition** emits whole lexicon words.
- **The deterministic pipeline** edits whole words or raises one letter at a
  sentence start. A test now runs every correct spelling through the complete
  production pipeline, in both locales and four sentence positions, and asserts
  each survives; another asserts no mid-word capital can be produced.
  `ANyone` requires one.
- **AX and clipboard insertion** deliver the whole string atomically.
- **Unicode typing** is only reached if clipboard paste fails to *create* a
  CGEvent, and even then it posts 20-unit UTF-16 chunks with no keyboard
  geometry. Its failure modes are 20-character blocks dropped or repeated.

`professionak` is the tell: `k` sits next to `l` on the keyboard. Adjacent-key
substitution and a held Shift (`ANyone`) are physical typing errors. The most
likely explanation is hand-typed text entering the log alongside dictated text.

That is a strong inference, not a proof, so the diagnostic capture shipped
anyway (§22.4). If a corruption ever appears in its `delivered` line, this
conclusion is wrong.

### 22.4 Diagnostics were unreachable

Production OSLog info messages are **not persisted to disk**. `log show --last
21d` returned nothing: every per-dictation timing and insertion-strategy record
from three weeks of use was gone. The only transcript capture needed a relaunch
flag.

Settings → Diagnostics now has a toggle, off by default with a plaintext-record
warning, writing each dictation's engine text, vocabulary hits, deterministic
text, Smart text or skip reason, final text, insertion strategy and target to a
0600 file. Show Log and Delete Log are beside it.


---

## 23. Measurements from 21 Sept 2026

### 23.1 Where the wait goes (57 logged dictations, Smart mode)

Engine finalize after key-up: median 115 ms, p90 198 ms, max 512 ms. Smart: median 1,299 ms, p90
4,626 ms, max 8,743 ms. The vocabulary stage is 0.3 ms at 100 rules, 1.5 ms at 500, 2.8 ms at
1,000, 5.3 ms at 2,000 (linear, cached patterns). Compiling a rule's pattern costs about
0.25 ms, so the cache must be warmed at launch. Conclusion: a bigger dictionary is free; the wait
a user feels is Smart.

### 23.2 Question marks

30 question marks produced by Apple's engine across 56 dictations; 29 survived our stages, 1 was
dropped when Smart merged two sentences. Misses were long questions and questions the engine
worded as statements ("it's that intended."). The engine punctuates from the words it hears.
`QuestionMarkStage` changed 2 of 57 real dictations, both correctly (ADR-027).

### 23.3 Synthetic-voice harvest

6,195 clips (177 terms × 9 English voices × 3 sentences + 4 Spanish voices × 2 sentences); the term
came back written exactly right 2,179 times and the carrier sentence was recognised in all but 391.
Distinct English `say` voices are fewer than the voice list suggests: the "Flo/Reed/Sandy/Shelley/
Eddy (English (US))" family produced byte-identical audio. 1,211 variants were heard once or by one
voice and dropped; 56 + 5 survivors were refused by hand as real phrases or names. Result: ADR-028.
Findings worth remembering: the recogniser often gets Spanish-with-English-names very wrong
("QuickBooks" → "Xbox"); casing errors ("anthropic", "github") are common in English; and rules
that start with a lone letter can match after an apostrophe ("let's lint" → "s lint").

### 23.4 Accessibility caret lookup

Chrome and Electron often report no caret; the pill then anchors to the focused element or the
screen bottom. Address bars and search boxes are text fields, and a new Chrome tab focuses the
address bar by default, which is why insertion there is refused (ADR-023).

## 24. Automatic English/Spanish (3 Oct 2026)

Tool: `WhisperingFlow --probe-languages <dir>` (each .wav through the production automatic
session; `PROBE_LOCALE=en-US` for one language, `PROBE_REALTIME=1` to feed at speaking pace).

- **Two transcribers in one analyzer work.** `SpeechAnalyzer(modules: [en, es])` with a shared
  format (16 kHz Int16) returns both result streams on one clock.
- **Per-word attributes are present** with `attributeOptions: [.audioTimeRange,
  .transcriptionConfidence]`: one run per word, leading space included.
- **Confidence is not comparable across models.** English speech: EN 0.71–0.97, ES 0.63–0.88
  (ES higher on #1). Spanish speech: EN 0.37–0.60, ES 0.91–1.00. Over Spanish speech the EN
  model often emits comma-only tokens at 0.003–0.07.
- **Segmentation differs between models.** The ES model often returns one result spanning both
  languages, so result-level choice cannot split a mixed dictation; word timing can.
- **The ES model re-spells English speech into English-looking text** ("Generate Animage of a
  Coffee Shop"), which is what makes text-language identification of its output a usable signal.
- Results: real 20/20; mixed WER 0.44 / 0.30 / 0.09 (EN-only / ES-only / merged); latency
  release→text at speaking pace, EN-only vs automatic: 175/107, 973/996, 740/906, 1442/1504,
  370/375, 647/696 ms.
- The recogniser is not deterministic run to run: the same clip gave slightly different words.

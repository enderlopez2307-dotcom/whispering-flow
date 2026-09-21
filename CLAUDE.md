# Whispering Flow — guide for agents changing the code

Local-first macOS menu-bar dictation. Hold **Right Command**, speak, release: corrected text is
inserted at the cursor. Everything runs on device. **Never propose a cloud service**; that
constraint is the reason the project exists.

Read before changing anything: `TECH_DECISIONS.md` (locked decisions and why),
`TECH_RESEARCH.md` (measured findings), `ARCHITECTURE.md` (module map).

## Pipeline (order is locked)

```
Right Command (150 ms hold, or double-tap for hands-free)
→ AVAudioEngine capture with pre-roll
→ Apple SpeechTranscriber, streaming during speech → EngineTranscript
→ vocabulary → deterministic cleanup (incl. question marks) → [Smart: Foundation Models]
→ FinalText → recorded for recovery → InsertionChain: AX → clipboard → Unicode typing
```

## Hard rules

- Do **not** reset macOS permissions (TCC) to investigate anything.
- Do not weaken a test to get a pass. Fix the code or explain why the test is wrong.
- Keep: Right Command default, hold-to-talk as the default gesture (double-tap is additive), the
  150 ms threshold, no microphone open while idle, local only.
- Fast mode never calls a model. Smart is "more polished", never "more accurate".
- Never auto-append Return. Never insert into secure fields, address bars, or another app.
- Transcript text never goes to OSLog. Diagnostics are an opt-in file.
- The shipped vocabulary stays conservative: no rule whose spoken form is an ordinary word.
- Stop at the end of a requested piece of work and report; do not start the next unasked.

## Build, test, run

```bash
swift build -c release --arch arm64      # zero warnings
swift test --arch arm64
(cd Packages/TextProcessingCore && swift test)   # also HotkeyGestureCore, AudioCaptureCore
./Scripts/install.sh                     # sign, build, install to ~/Applications
./Scripts/doctor.sh --relaunch           # what the running app reports
```

Useful headless flags on the binary: `--validate-corpus <dir>` (recogniser regression),
`--transcribe-dir <dir>` (used by `Scripts/vocab/harvest.py`), `--process-text "<text>" [--es]`
(run typed text through the dictionary and cleanup; read-only), `--probe-focus` (dump the
accessibility element under the cursor after 5 s — use it instead of guessing what an app
reports), `--debug-menu`.

Live logs: `log stream --info --predicate 'subsystem == "com.whisperingflow.dictation"'`. OSLog
info is not persisted.

## Mistakes this project has already paid for

- **`MainActor.assumeIsolated` and closures made inside `@MainActor` scopes** trapped twice
  (audio tap, text processor). A non-isolated `async` requirement runs on the cooperative pool.
  Declare `@MainActor` on the closure and `await` it. Unit tests on the main actor will not catch it.
- **Insertion "success" is not evidence.** AX subroles are unreliable (Safari's address bar has
  none on macOS 26). Refuse by structure: an `AXToolbar` ancestor means window chrome. Insert
  with `AXSelectedText`, never by rewriting `AXValue`: that typed placeholder text and duplicated
  utterances in Electron apps.
- **A retained `AVAudioConverter` leaks the previous utterance.** `reset()` does not clear it;
  build a fresh one per capture.
- **ICU `.caseInsensitive` makes `\p{Lu}` match lowercase**, which inverted the ordinal rule.
- **A synchronous handler added before a timer shifts the timer.** Arm for `deadline - now`.
- **A modifier held past the threshold with another key pressed is a shortcut, not a
  dictation** (⌘C/⌘V with Right Command). The gesture cancels it.
- **Every regex the vocabulary compiles is cached**; a large dictionary must be warmed at launch
  or the first dictation pays for it.
- Test anything timing- or UI-related live with a person before calling it done.
- `InsertionTests` read the real focused element on screen and depend on what has focus: rerun
  before assuming a regression.

## Signing

Builds are signed with a per-user, self-signed certificate created by
`Scripts/create-signing-cert.sh` so macOS privacy grants survive rebuilds. The designated
requirement must stay `identifier "…" and certificate leaf = H"…"`, never a `cdhash`. Do not
commit a certificate, key, hash or keychain reference.

# Whispering Flow — Technical Decisions (ADRs)

Format: Decision · Why · Alternatives considered · Trade-offs · What would cause us to reconsider.

Status values: **Proposed** (awaiting your sign-off) · **Accepted** · **Superseded**.
Every ADR below is **Proposed**. None is irreversible without your approval.

---

## ADR-001 — Native Swift 6 + AppKit-backed menu bar app, no Electron/Tauri layer

**Status:** Proposed

**Decision.** Build a native macOS app: Swift 6, SwiftUI for settings panes, AppKit
(`NSStatusItem`, `NSPanel`) for the menu bar and floating HUD. `NSApplicationDelegate` with
`.accessory` activation policy so there is no Dock icon.

**Why.** The three hard requirements — a session `CGEventTap`, `AVAudioEngine` capture, and
Accessibility/CGEvent text injection — are all C-level system APIs. Any cross-platform shell
adds a bridging layer over exactly the parts that are hardest to get right. SwiftUI alone
cannot express a status item or a non-activating always-on-top panel cleanly, so AppKit is
used where AppKit is better.

**Alternatives.** Electron/Tauri (rejected: bridging cost on the critical path, memory
footprint for an always-resident utility, and the clipboard/CGEvent issues documented in
TECH_RESEARCH §8 are worse there). Pure SwiftUI `MenuBarExtra` (rejected as the *only*
mechanism: less control over the status item and no good story for the non-activating panel;
we may still use it for the settings scene).

**Trade-offs.** macOS-only forever. AppKit interop means some `@MainActor` and
`NSObject` ceremony in an otherwise modern codebase.

**Reconsider if.** You ever want Windows/Linux parity — at which point the correct move is a
shared pure-Swift core (text pipeline, gesture machine) with separate platform shells, which
this architecture already permits.

---

## ADR-002 — Apple `SpeechTranscriber` is the **default** engine; Parakeet/FluidAudio is a first-class alternative

**Status:** Proposed — **this is the one I most want you to actively agree or disagree with.**

**Decision.** Ship `AppleSpeechEngine` (macOS 26 `SpeechAnalyzer` + `SpeechTranscriber`) as
the default, and `ParakeetSpeechEngine` (FluidAudio) as a fully-supported switchable engine.
Both are built in V1 and both are benchmarked in Phase 5 before the default is locked in.

**Why.** You asked me to challenge the stack, and the research produced one finding that
changes the answer:

1. **Parakeet cannot select between English and Spanish — at all.** TECH_RESEARCH §1.1
   documents this from FluidAudio's own source: the `language:` parameter performs *script*
   filtering, and English and Spanish are both `.latin`. Passing `.spanish` is a **no-op**
   relative to `.english` for your exact language pair. There is also no `detectedLanguage`
   in the result, so you cannot even observe what the model chose. Bilingual EN/ES is a core
   product goal, and the proposed engine has no mechanism for it.
2. **Apple's API has explicit `en_US` / `es_ES` / `es_MX` / `es_US` locales.** Precisely the
   control that is missing.
3. **No 600 MB download, no cache, no integrity verification, no disk preflight, no
   Hugging Face dependency.** Assets live in system storage, don't count against app memory,
   and Apple updates them. That deletes a meaningful fraction of the app.
4. **It's already on your Mac.** You are on macOS 26.5.2 with Xcode 26.6. For a personal
   app, the "macOS 14+ reach" advantage of Parakeet is worth nothing.
5. **Streaming suits push-to-talk better.** Audio streams during the hold, so key-up
   *finalizes* rather than *starts* transcription — structurally lower perceived latency.
   It also makes the live-preview HUD nearly free.
6. **One less binary dependency.** FluidAudio ships prebuilt `.xcframework` binary targets
   (including a Rust FST engine) that you cannot inspect or rebuild — a fair thing to weigh
   in an app whose premise is "nothing leaves this machine."

**Alternatives.**
- *Parakeet-only as originally proposed* — rejected as the **default** for reason 1, but kept
  as an engine because it is genuinely good, is proven in this exact use case by presspeech,
  and gives independence from Apple's asset pipeline.
- *WhisperKit as default* — rejected: higher latency and a known tendency to hallucinate on
  near-silent input, which is common with push-to-talk trailing audio.
- *Apple-only, drop Parakeet* — rejected: it would leave `SpeechEngine` with one
  implementation, and a protocol with one implementation is a guess, not an abstraction.
  Building the second one is what proves the seam is real, and it is your stated requirement.

**Trade-offs.**
- Raises the deployment target to **macOS 26** for the default path (ADR-003).
- Apple's model is a black box: no custom vocabulary API, no version pinning, and Apple can
  change behaviour in a point release. Parakeet is pinnable to `v0.15.6` and reproducible.
- Two engines is more code than one. Accepted deliberately — it is the requirement.
- The accuracy comparison in TECH_RESEARCH §3 is **suggestive, not proven.** Different
  benchmark subsets. Phase 5 measures both on your own voice before we commit.

**Phase 2.6 finding worth carrying to Phase 6 (2026-08-22).** Measuring technical-vocabulary
recognition across 34 opportunities produced an unexpected ranking:

| Path | Technical terms | General agreement vs SpeechTranscriber |
|---|---|---|
| **Parakeet + FluidAudio `CustomVocabulary`** | **31 / 34** | EN 86% · ES not validly measured |
| Parakeet baseline | 18 / 34 | EN 88% · ES not validly measured |
| `DictationTranscriber` + custom language model | 15 / 34 | 90% |
| **`SpeechTranscriber` (current default)** | **11 / 34** | reference |

**Parakeet is materially better at technical vocabulary than Apple's engine** — better even
than Apple's legacy engine carrying a purpose-built custom language model. That is a real
argument for Parakeet that Phase 2.5 did not have, and technical vocabulary is the dominant
remaining quality gap (QUALITY_BENCHMARK Q9).

This does **not** flip the decision: Parakeet still offers no English/Spanish control
(§1.1, confirmed at runtime), and bilingual use is a core requirement. But the Phase 6 engine
benchmark must weigh technical-vocabulary accuracy explicitly, not WER alone.

**Reconsider if.** (a) Phase 5 shows Apple is materially worse on your Spanish; (b) Q1 shows
simultaneous EN+ES locale allocation is impossible *and* Parakeet's implicit detection turns
out to handle your code-switching better in practice; (c) Apple regresses the model in an OS
update and you need a pinnable engine; (d) you decide you want this to run on pre-26 Macs.

---

## ADR-003 — Deployment target macOS 26

**Status:** Proposed

**Decision.** `.macOS(.v26)`. Apple Silicon only.

**Why.** It is the only way to use `SpeechAnalyzer` (ADR-002), and it is the OS on the only
machine that will run this. Supporting macOS 14 would force either an availability-fenced
dual-path default engine or dropping ADR-002 entirely — significant complexity bought for
zero benefit to you.

**Alternatives.** macOS 14 with `@available` fences (rejected: complexity with no user).
macOS 15 (rejected: no `SpeechAnalyzer`, so it buys nothing over 14).

**Trade-offs.** The app cannot run on any Mac older than macOS 26. `ParakeetSpeechEngine`
would technically work on 14+, so this is a self-imposed floor that could be lowered later
by fencing the Apple engine — cheap to do, expensive to have done prematurely.

**Reconsider if.** You want to run this on a second, older Mac, or ever distribute it.

---

## ADR-004 — `CGEventTap` for the global shortcut; accept the Input Monitoring permission

**Status:** Proposed

**Decision.** Session-level `CGEvent.tapCreate` observing `keyDown | keyUp | flagsChanged`.
Interpret events through a **pure `PressGesture` state machine** that is unit-tested
independently of the tap.

**Why.** Push-to-talk needs **key-up**, and the comfortable triggers are bare modifiers
(Right ⌥). TECH_RESEARCH §6 shows Carbon hotkeys give neither, and `NSEvent` global monitors
do not reliably distinguish left/right modifiers or `fn`. The session tap is the only API
that does. Verified in a shipping app (presspeech).

**Alternatives.** Carbon `RegisterEventHotKey` (no key-up — disqualifying).
`NSEvent.addGlobalMonitorForEvents` (insufficient modifier discrimination).
`KeyboardShortcuts` package (**[A]** likely Carbon-based; probably usable for the
*recorder UI* only — Q7).

**Trade-offs.** Requires Input Monitoring, a high-privilege grant. The callback sees every
keystroke on the system, including passwords — so it is deliberately minimal, allocation-free,
and logs modifier *names* only, never keycodes. Taps are also disabled by the system on
timeout and must be re-armed. And Secure Input can silence the tap completely with no error
(ADR-005).

**Reconsider if.** Apple ships a first-party push-to-talk / dictation-trigger API, or the
Input Monitoring grant proves unworkably unstable in practice.

---

## ADR-005 — Treat Secure Input as an explicit, user-visible application state

**Status:** Proposed

**Decision.** Poll `IsSecureEventInputEnabled()`. When it is held, enter a distinct
`blocked(.secureInput)` state: change the menu bar icon, and explain in the menu that another
app is holding secure input and dictation cannot work until it releases.

**Why.** TECH_RESEARCH §10: while any process holds secure input, our tap receives **nothing**
and synthetic paste is refused — with no error and no callback. Terminal's "Secure Keyboard
Entry" is on your target app list, and password managers are notorious for holding it while
backgrounded. Without this, the app appears to be simply broken, at random, forever.

**Alternatives.** Ignore it (rejected: guarantees an unfixable-looking bug). Try to work
around it (impossible by design — that is the entire point of the API, and trying to defeat
it would be wrong).

**Trade-offs.** A polling timer. Nothing is actually *fixed* — but a legible failure is
enormously better than a silent one.

**Reconsider if.** A notification-based API for secure-input state changes appears.

---

## ADR-006 — Ordered insertion chain: Accessibility → clipboard paste → Unicode typing

**Status:** Proposed — **amended after the Phase 2 spike; ordering still provisional pending Phase 7 measurement**

**Decision.** `InsertionChain` tries strategies in order, first success wins, with a
per-app override map. Clipboard restore happens **only if `NSPasteboard.changeCount` is
unchanged** since our write.

**Why.** TECH_RESEARCH §8: neither AX nor clipboard works everywhere. AX is cleanest when
supported (no clipboard mutation, atomic) but fails on Electron and many web views — which
covers VS Code, Slack, and much of Chrome. Clipboard paste works essentially anywhere a human
can paste, which is the actual target matrix, but has side effects and is blocked by Secure
Input. A chain is the only honest answer. Note presspeech ships **no** AX inserter at all,
which is evidence that clipboard-first may be the better default order — Phase 6 decides.

**Alternatives.** Clipboard-only (simpler; presspeech's choice; loses the clean path where it
works). AX-only (rejected: fails on too much of the target matrix). Unicode-typing-only
(rejected: slow and visible for long transcripts).

**Trade-offs.** Three implementations to maintain. Clipboard mutation is user-visible in
clipboard-manager apps regardless of restore. AX calls need off-main-thread execution with
timeouts or they can freeze the app against an unresponsive target.

**Amendment (Phase 2 spike, 2026-08-22).** The spike found something that changes the
weighting between the two strategies, and it is not about success rate.

Pasting into Safari reported success and put the text **in the address bar**. Clipboard paste
is fire-and-forget: a posted ⌘V tells you nothing about whether the text arrived, or where.
AX insertion, by contrast, targets a specific element and reports failure when that element
will not take a value.

So the chain gains a mandatory step that is not a strategy at all:

- **Probe the focused element before delivering anything.** `FocusedTarget` carries the
  element's AX role, and the chain **declines to insert** when the focus is not a text-entry
  role. Writing a dictated sentence into an address bar, a search box, or a spreadsheet cell
  is a worse outcome than inserting nothing and saying so.
- That probe is the same call the AX inserter needs anyway, which removes most of the argument
  for demoting AX below clipboard. **AX stays first.**
- Where AX can read the element back, **verify after inserting** and report a real result
  rather than an assumed one. Evaluate coverage in Phase 7.

**Reconsider if.** Phase 7 measurement shows AX-first never wins on your actual apps — then
demote it to a focus *probe* only, keep the probe mandatory, and paste as the sole delivery
mechanism.

---

## ADR-007 — Deterministic staged text pipeline; no LLM in V1

**Status:** Proposed

**Decision.** An ordered array of `TextStage` values, each a pure function
`(String, ProcessingContext) -> String`. No model, no network, no nondeterminism.

**Why.** You asked for this and the research supports it: MacParakeet reports its equivalent
deterministic pass at **<1 ms**. Deterministic output is debuggable, unit-testable against
fixed fixtures, and never surprises you by rewriting meaning. An LLM cleanup stage is a
*later* stage in the same array (ADR-010) — the boundary is designed so adding it changes no
existing code.

**Alternatives.** Small local LLM from day one (rejected: latency budget, nondeterminism, and
it would mask pipeline bugs). One monolithic `clean()` function (rejected: cannot A/B a single
stage, cannot reorder, cannot test in isolation).

**Trade-offs.** Deterministic rules cannot fix grammar, disfluent restarts, or
sentence-boundary ambiguity. Filler-word lists are locale-specific and need hand-tuning for
Spanish. Aggressive filler removal risks deleting meaningful words ("like" as a verb) —
so the rules are conservative and word-boundary-anchored by default.

**Amendment (real-speech test, 2026-08-22) — the "no LLM in V1" clause is withdrawn.**

A 41-second dictation in the user's natural speaking style produced seven error classes
(TECH_RESEARCH §16). **Three of them are unreachable by any deterministic rule**: garbled
grammar (`how effect this is could be`), a mangled function word (`native for`), and an
abandoned self-correction (`no, actually, or yeah`). Measured, not predicted.

So V1 ships **deterministic stages plus an optional LLM stage** — the LLM enabled by default
for long utterances, off the critical path, with a timeout fallback (ADR-010). What survives
unchanged is the *reason* the pipeline is staged: the LLM runs on already-cleaned text, and
the measurement showed that ordering is not cosmetic. Running the model on raw input dropped
a whole sentence; running it after the dictionary preserved everything.

The rest of ADR-007 is strengthened rather than weakened. The deterministic pass remains
mandatory and irreplaceable: **the LLM fixed zero proper nouns**, left `ductation` untouched,
and rendered `glock code` as `Glock Code` — confidently wrong. The dictionary is not a
placeholder for a model; it owns an error class the model cannot touch.

**Reconsider if.** Measurement shows the LLM stage degrades output more often than it helps on
your real transcripts, or its latency proves intolerable even when length-gated.

---

## ADR-008 — Personal vocabulary as a post-processing stage, not engine biasing

**Status:** Proposed

**Decision.** Corrections are applied by `VocabularyCorrector` **after** transcription,
longest-match-first, word-boundary-anchored, case-preserving. Stored as human-editable JSON
in `~/Library/Application Support/WhisperingFlow/vocabulary.json`.

**Why.** It is the only option that works across all engines: `SpeechTranscriber` has **no**
custom-vocabulary API (TECH_RESEARCH §3), and FluidAudio exposes no biasing hook either.
Post-processing is also strictly more controllable — you can see and edit exactly what
changed, and a bad rule is one line to fix rather than an opaque model behaviour.

**Alternatives.** Engine-level biasing (unavailable). Fuzzy/phonetic matching (rejected for
V1: risks corrupting correct text; revisit once we see the actual error patterns for
*Anthropic, Claude, OpenAI, ChatGPT, Supabase, Cloudflare, Vercel, Higgsfield, Seedance*).

**Trade-offs.** Cannot fix an error the model didn't make *phonetically* — if Parakeet emits
"super base" for "Supabase," an exact-match rule catches it, but a novel mangling won't be
covered until you add it. Ordering matters: this runs before capitalization so
`openai → OpenAI` survives.

**Confirmed three times over (2026-08-22).** Across the Phase 2.5 corpus, the 41-second test
and the 106-second test, **the LLM never once recovered a technical term the dictionary had not
already fixed.** In the one head-to-head where the arms diverged it produced `Superbase` where
the dictionary produced `Supabase`. Vocabulary-before-LLM is settled: the dictionary is not a
placeholder for a model, it owns an error class the model cannot touch.

**But the reactive limitation is now measured, not hypothetical.** The dictionary only fixes
errors already observed: it fired on just **3 of 20** utterances and missed `clock code`
(→ Claude Code), `Anthropic dogs` (→ docs), `brown palette` (→ brand palette) and `su pae`
(→ Supabase) until added by hand.

**The Spanish case is markedly worse and is the system's weakest point.** Spoken inside a
Spanish sentence, `Supabase` came back as **`su pae`** — disintegrated into two Spanish-sounding
words, because the `es_ES` acoustic model has no representation for English product names and
maps them onto Spanish phonotactics. The LLM then capitalised it to `su PAE`, inventing an
acronym. Both were recoverable by rules, but only *after* the error had been seen once. Every
new technical term must be mangled before it can be fixed. This is the largest remaining quality gap versus Wispr Flow (QUALITY_BENCHMARK Q9), and
it argues for investigating engine-level biasing —
`DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration:)` exists, though not
on `SpeechTranscriber`.

**Engine-level biasing was investigated properly in Phase 2.6 and rejected on measurement**
(VOCABULARY_SPIKE.md). Two mechanisms exist that this ADR previously assumed did not:

- **`AnalysisContext.contextualStrings`** on `SpeechTranscriber` — present in the SDK,
  accepted, and **measurably inert**: byte-identical output across 13 fixtures, verified via
  both the initialiser parameter and `setContext`, with read-back confirming retention.
- **`SFCustomLanguageModelData` + `DictationTranscriber.ContentHint.customizedLanguage`** — a
  genuine custom language model that **works**, recovering `Clock Code → Claude Code` on the
  real failing recording. But it attaches only to `DictationTranscriber`, the legacy engine,
  which was measured at **90% word agreement** with `SpeechTranscriber` over the real corpus.
  The trade is **+4 technical terms out of 34 against ~10% general word error** — clearly bad
  for a general dictation app.

**FluidAudio's `CustomVocabulary` subsystem was then fully tested** and is the strongest
mechanism found anywhere in this phase: **18/34 → 31/34** technical terms, with word error
against ground truth *improving* 38% → 32%, for +141 ms. Correctly classified it is
**acoustically-grounded second-pass replacement (shallow fusion), not decoder-time biasing**;
it is stronger than our blind string matching because it can decline a substitution the audio
does not support.

It is nonetheless **not adoptable for V1**, for reasons unrelated to its quality:

- Batch vocabulary boosting is only exposed by `UnifiedAsrManager`, which loads
  `parakeet-unified-**en**-0.6b` — an **English-only** model. The 31/34 figure therefore has
  **no valid Spanish measurement**, and taking it at face value would repeat the
  locale-mismatch error of TECH_RESEARCH §15.7.
- The multilingual TDT v3 route exposes it only through a streaming API, which **hung under
  test** and was abandoned per the phase's scope limit. Promising, unresolved.
- Unlike the dictionary, it **fabricates**: it wrote `CoreML` over the spoken words *"for my"*
  and `OpenAI` over *"open"*.

An important tuning caveat for any future attempt: adding `Claude` as a standalone term
*lowered* recovery from 31 to 27 and corrupted `VS Code` into `VS Claude`. A CTC rescorer needs
long, distinctive terms; short ones that rhyme with common words do active damage — the
opposite of the deterministic dictionary, where short exact rules are safe.

So the dictionary stands as the V1 answer, and its reactive limitation is accepted rather than
engineered around. Mitigation: **pre-seed the observed variants** rather than waiting to
encounter each one.

**Reconsider if.** Apple attaches a working biasing hook to `SpeechTranscriber`, or Phase 6
moves the default engine to Parakeet — in which case FluidAudio's CTC rescorer deserves one
more focused attempt.

---

## ADR-009 — Context-aware formatting deferred, but the seam is built now

**Status:** Proposed

**Decision.** `ProcessingContext` carries the target app's bundle identifier from day one,
and `FocusedAppProbe` populates it — but **no stage consumes it in V1.**

**Why.** Retrofitting context plumbing through a pipeline later means touching every stage
signature. Adding the parameter now costs almost nothing and makes Phase 11 (e.g. no trailing
period in Terminal; preserve code formatting in VS Code; sentence case in Gmail) a purely
additive change.

**Alternatives.** Add it later (rejected: cheap now, invasive later). Implement it now
(rejected: you explicitly deferred it, and we have no data yet on what rules you'd want).

**Trade-offs.** A parameter carried but unused for several phases. Trivial.

**Reconsider if.** Nothing. This is a low-cost hedge.

---

## ADR-010 — Local LLM cleanup as an optional Fast/Smart mode

**Status:** Proposed — **amended twice on measured evidence.** Promoted from Phase 13 to a V1
requirement after a single 41-second sample, then **partially walked back** after the
20-utterance Phase 2.5 benchmark. Now: **built in V1, off by default, user-selectable.**

**Correction (QUALITY_BENCHMARK.md, 2026-08-22, final 20-utterance corpus).** The promotion
was over-confident. On one long sample the LLM looked essential; across 20 varied real
utterances it changed only **6 (30%)** — helping 3, harming 2, one partial — for a net of about
one improved utterance. Meanwhile the
biggest quality defects (`brown palette`, `Anthropic dogs`, `clock code`, `half for`) were
fixed by **neither** layer, because they are engine recognition errors. **Recognition accuracy
and the dictionary dominate perceived quality; the LLM is secondary polish.** Generalising
from one sample was the mistake; the benchmark is what corrected it.

**Automatic gating is rejected on evidence.** Length was the obvious gating signal. Across the
final corpus the LLM changed utterances at 2 s, 7 s, 7 s, 8 s, 9 s and 39 s; harms fell at 2 s
and 7 s, benefits at 8 s, 9 s and 39 s. A threshold between 7 s and 8 s would separate them —
**on a sample of six changes**, which is fitting a rule to noise, not finding a signal. Per the
standing instruction, gating is not adopted. **Fast (deterministic) is the default; Smart
(+LLM) is an explicit toggle.**

**Decision.** If added, it becomes `LLMPolishStage` — the last stage — behind an off-by-default
setting, with a hard timeout that falls through to the deterministic output on any failure or
overrun. Likely backed by Apple's on-device Foundation Models framework (already on macOS 26).

**Verified in the Phase 2 spike (TECH_RESEARCH §16).** Apple Foundation Models is present on
this machine, runs fully on-device, repaired exactly the error classes the deterministic pass
cannot, and produced **byte-identical output across three consecutive runs** at
`temperature: 0.1` — so a model in this path does not make the product feel random.

Two non-obvious requirements the spike surfaced, both mandatory:

- **`SystemLanguageModel.default` refuses the task**, returning *"I'm sorry, but I cannot
  assist with this request"* every time — it reads a dictated transcript as a request aimed at
  it. The stage must use `guardrails: .permissiveContentTransformations` **and** wrap the
  transcript in explicit delimiters so it reads as data. A refusal must be handled as a normal
  outcome that falls through to the deterministic result.
- **A longer, more detailed prompt measured *worse*** than a shorter one. The prompt is a
  tuned artifact with golden-file tests, not something to reason about and freeze.

**Cost, measured properly.** The +1.3 s figure came from one long sample and was misleading.
Steady-state, warm: **304 ms mean for utterances under 10 s**, 1339 ms for 10 s and over,
against a 98 ms engine finalize. So Smart mode costs ~400 ms end-to-end on everyday short
dictation — cheap enough that the decision turns on *quality risk*, not latency.

**Three failure modes the benchmark found, all now mandatory to handle:**

- **Translation.** With English instructions the model translated Spanish transcripts into
  English despite an explicit `NEVER TRANSLATE` rule. Writing the instruction block *in
  Spanish* fixed it (hard failures 3/18 → 1/18). **Instruction language must match content
  language**; stating the rule in the wrong language does not work.
- **Conversational packaging.** Intermittently it replied `Sure, here is the cleaned-up
  transcript:` plus a fenced code block, which would have been pasted verbatim into the user's
  document. Output must be unwrapped, and discarded if still structurally wrong.
- **Invention — the dominant residual harm.** Every genuine LLM harm in the corpus is of this
  kind: given a recognition error, the model makes it *fluent* rather than correct.
  `Abré`→`Abrí` (meaning inverted), `su pae`→`su PAE` (acronym invented), `half for`→`half
  past for` (broken phrase made to scan). **The information-loss invariant cannot detect any of
  them, because inventing a word is not losing one.** There is no automatic guard; this is the
  strongest argument for Fast being the default.

**Stability, measured over 60 calls.** 19–20 of 20 utterances byte-identical across repeated
runs; the only variance was on the 39-second Spanish ramble and did not reproduce every pass.
Sanitizer activity 3–6% of calls, 0 discarded. The packaging bug is **input-dependent, not
random** — the utterance phrased as a question (`Can you refactor these functions…?`) triggered
it on every run, because the transcript itself reads as a request addressed to the model.
Delimiters reduce this but do not eliminate it.

Critically, the packaging bug appeared **only under repeated-run stability testing**, not in
any single-shot run. Any LLM stage needs repeat-testing in CI, not one golden sample.

**Why.** Keeps the guarantee that dictation always produces text: the LLM can only ever
*improve* the result, never block it. Foundation Models avoids shipping and managing another
multi-GB weight file, and stays consistent with "nothing leaves the device."

**Alternatives.** LLM inline in the critical path (rejected: a hung model must never eat your
sentence). A bundled llama.cpp/MLX model (rejected for V1: large download, more lifecycle code
— exactly what ADR-002 was trying to avoid).

**Trade-offs.** Nondeterminism, latency, and the risk of an LLM "correcting" your meaning.
Off by default for those reasons.

**Reconsider if.** Phase 5 shows a large latency budget and ADR-007's ceiling is limiting you.

---

## ADR-011 — Persistent self-signed certificate; Hardened Runtime, no App Sandbox, no Apple Developer Program

**Status:** **Accepted** — verified experimentally in Phase 1 on 2026-08-22.
**Supersedes** the original Proposed version, which assumed Developer ID.

**Decision.** Sign every local build with a **persistent self-signed code-signing certificate**
(`Whispering Flow Local Signing`, RSA-2048, 20-year validity) created locally by
`Scripts/create-signing-cert.sh` and stored in the login keychain. Hardened Runtime **on**,
App Sandbox **off**, notarization **none**, Apple Developer Program membership **none**.
Entitlements: `com.apple.security.device.audio-input` and
`com.apple.security.device.microphone`, plus `NSMicrophoneUsageDescription` in `Info.plist`.

**Why.** The original ADR asserted, without evidence, that TCC grants are keyed to the code
signature and that ad-hoc signing would reset them. Phase 1 tested this (TECH_RESEARCH §14)
and the assertion held — sharply:

- **Ad-hoc signing, which is exactly what Xcode's "Sign to Run Locally" produces, yields a
  designated requirement of `cdhash H"…"`.** The cdhash is a hash of the compiled code, so
  it changes on every build that changes anything. Microphone, Accessibility and Input
  Monitoring would have to be re-granted **after every single build**. This is disqualifying
  for a project whose entire inner loop is rebuild-and-test.
- **A real certificate yields an identity-based requirement instead**, which is invariant
  across rebuilds. Verified over three builds with genuinely different binaries: cdhash and
  binary SHA-256 changed each time, the designated requirement did not, and the grant held.
- The certificate is self-issued, valid for 20 years, costs nothing, involves no Apple
  account, and never needs renewing — so unlike the alternatives it introduces no recurring
  cost and no annual permission-reset event.

App Sandbox stays off because a system-wide `CGEventTap` and Accessibility-based text
injection are fundamentally incompatible with it. This app is therefore not distributable via
the Mac App Store, which is explicitly out of scope.

**Alternatives considered.**
- *Ad-hoc / "Sign to Run Locally"* — **rejected on measured evidence**, see above. It is the
  simplest option and it does not work.
- *Apple Development certificate from a free personal team* — **works**, and was verified to
  produce a stable designated requirement. Rejected as the default only because the
  certificate on this machine expires 2027-07-04 and is regenerated annually, resetting all
  grants once a year, and because it couples the build to an Apple ID and to Xcode's
  certificate management. **Recorded as a viable fallback** if the self-signed certificate is
  ever lost.
- *Developer ID* — **out of scope**: requires the $99/year Apple Developer Program.
- *Notarization* — unnecessary. Gatekeeper evaluates quarantined downloads; a locally built
  app is not quarantined.

**Trade-offs.**
- The certificate reports `CSSMERR_TP_NOT_TRUSTED` and is absent from
  `security find-identity -v`. Harmless — `codesign` uses it and `--verify --strict` passes —
  but every script must query `find-identity` **without `-v`**.
- The private key lives in the login keychain, ACL-restricted to `/usr/bin/codesign`. It was
  deliberately **not** imported with `-A`: a key any process could use would let malware sign
  code carrying our bundle identifier and inherit our Accessibility grant.
- Losing the login keychain means losing the certificate, and re-creating it resets all
  grants. Recovery is one script run plus three toggles, so no key escrow is warranted.
- The app cannot be given to anyone else without being re-signed. Intended.

**What would cause us to reconsider.** You decide to distribute the app (then: Developer ID
and notarization, and this ADR is superseded); or macOS changes how self-signed certificates
are treated for TCC (then: fall back to the Apple Development certificate, already verified
to work).

## ADR-012 — SwiftPM package plus a build script, not an Xcode project

**Status:** **Accepted** — **supersedes** the original Proposed version, which chose an Xcode project.

**Decision.** The app is a SwiftPM executable target. `Scripts/build.sh` assembles and signs
`WhisperingFlow.app`. Pure logic lives in local packages (`Packages/TextProcessingCore`,
`Packages/HotkeyGestureCore`) that build and test on their own.

**Why the reversal.** The original ADR chose Xcode for first-class `Info.plist`, entitlements
and signing handling. Phase 1 found that reasoning did not survive contact with this machine:

- **Neither XcodeGen nor Tuist is installed**, so an `.xcodeproj` would have to be hand-written
  as `project.pbxproj` — a format where adding one source file means editing three separate
  sections. That is strictly worse to maintain than a SwiftPM manifest that needs no edit at all.
- The three things Xcode was supposed to make first-class are each **one line of shell**:
  copy an `Info.plist`, pass `--entitlements`, pass `--sign`. Written out, they are *more*
  transparent — which mattered directly, because the signing experiment in TECH_RESEARCH §14
  depended on inspecting and varying exactly those steps.
- The whole build and verification loop is now runnable headlessly, which is what allowed the
  rebuild-stability experiment to be automated rather than clicked through.

The original ADR's one concrete objection to SwiftPM — that its resource bundles are
incompatible with `codesign --deep` — is avoided rather than solved: the target declares **no
resources at all**, because all iconography is SF Symbols.

**Alternatives considered.** Hand-written `.xcodeproj` (rejected: high-friction format, no
generator available). Installing XcodeGen (rejected: another dependency to serve a build that
is already four shell commands). Xcode project created through the GUI (rejected: not
reproducible, and not scriptable for the Phase 1 experiment).

**Trade-offs.** No Xcode scheme, so debugging is via `lldb` or by opening `Package.swift` in
Xcode (which works, but builds the raw binary rather than the signed `.app`). The `.app`
assembly logic is ours to maintain — currently about 20 lines.

**What would cause us to reconsider.** Needing an Xcode-only capability: a debugger-attached
UI test, Instruments templates that require a scheme, or an App Store build.

## ADR-013 — Build fresh; study presspeech, do not fork; do not fork MacParakeet

**Status:** Proposed

**Decision.** Write this codebase from scratch against the module boundaries in
ARCHITECTURE.md. Treat presspeech as a **technique reference** (MIT — adaptation permitted
with attribution). Do **not** fork MacParakeet.

**Why.**
- **[V]** presspeech is a **14,092-line single `main.swift`.** It is proof the concept works
  and a rich source of specific hard-won fixes, but refactoring a 14k-line monolith into the
  modular design you asked for is more work than writing the modules cleanly — and you would
  inherit its Parakeet-only engine coupling, which ADR-002 rejects.
- **[S]** MacParakeet is **GPL-3.0**. Forking it would make Whispering Flow GPL-3.0. For a
  personal app that may be acceptable, but it is a real commitment, and its scope (SQLite/GRDB,
  Sparkle, yt-dlp, meeting recording, CLI) vastly exceeds V1. Read it for ideas; don't copy code.
- Specific things worth *adapting* from presspeech, with attribution: the first-event-arrival
  tap diagnostic, the `changeCount` clipboard-restore guard, the UTF-16 chunking rule for
  Unicode injection, the dual microphone entitlement, the ANE reentrancy warning, and the
  audio-route-change and post-sleep recovery logic.

**Alternatives.** Fork presspeech (rejected: monolith + wrong engine coupling). Fork
MacParakeet (rejected: GPL + scope). Contribute upstream instead of building (rejected: you
want your own app with your own EN/ES and vocabulary behaviour).

**Trade-offs.** Slower to first working build than a fork. Offset by the walking-skeleton
spike in Phase 2, which reaches end-to-end dictation quickly without committing to structure.

**Reconsider if.** The spike reveals a problem so gnarly that presspeech's exact solution is
the only viable path — in which case adapt that piece specifically, with attribution, not the
whole app.

---

## Decisions explicitly deferred

| Topic | Deferred until |
|---|---|
| Default hotkey binding | Phase 3, after you try candidates for comfort and conflicts |
| Final insertion chain order + per-app overrides | Phase 6 measurement (Q4) |
| Whether automatic EN/ES detection ships at all | Phase 5 spike (Q1) |
| Filler-word list contents for Spanish | Phase 7, from your real transcripts |
| Whether to keep Parakeet after benchmarking | Phase 5 (Q2/Q6) — but the engine stays in-tree regardless |
| Notarization / distribution | Only if you ever share the app |

---

## ADR-014 — V1 scope locked after the research phase

**Status:** **Accepted** — locked by the user 2026-08-22 at the close of Phase 2.6. These are
not proposals; they are the contract Phase 3 onward builds against.

**Decision.**

| Area | Locked choice |
|---|---|
| Primary engine | **Apple `SpeechTranscriber`.** `SpeechEngine` abstraction retained so Parakeet can be evaluated later, but **V1 is not blocked on Parakeet**. |
| Pipeline | Audio → `SpeechTranscriber` → `EngineTranscript` → vocabulary → deterministic cleanup → *optional* Smart cleanup → safe insertion |
| Vocabulary | **Deterministic dictionary is the V1 answer** for technical terminology. Seeded only from variants **actually observed**, plus additions that are extremely high-confidence. User-editable (add/edit/disable/delete) eventually. Deterministic and testable. |
| Fast / Smart | **Fast is the default.** Smart adds Foundation Models cleanup. **No automatic length gating.** Smart must never block recovery of the deterministic transcript. |
| Hotkey | **Right Command** provisional default. Architecture must keep it configurable. **Not** Right Option — it conflicts with bilingual typing (`ó`, `ñ`). |
| Ordinals | **Preserve spoken lexical form.** "first" stays "first". No automatic ordinal conversion in the deterministic pipeline. |
| Engine-level biasing | **Not shipped in V1.** No Apple custom language models, no FluidAudio `CustomVocabulary`. Findings recorded in VOCABULARY_SPIKE.md for future evaluation. |

**Why.** Each line is the conclusion of a measured phase rather than a preference:
Phase 2.5 (QUALITY_BENCHMARK.md) established that deterministic processing carries most of the
value and that the LLM helps 3 utterances and harms 2 out of 20; Phase 2.6
(VOCABULARY_SPIKE.md) established that every engine-level biasing path either degrades the
recogniser or has no valid bilingual measurement.

**Trade-offs accepted.**
- The dictionary is **reactive** — each mishearing must be seen once before it can be fixed.
  Accepted as an onboarding cost, not a correctness risk (VOCABULARY_SPIKE §10).
- Fast mode will not repair garbled grammar or abandoned self-corrections. Accepted;
  Smart mode exists for when that matters.
- Parakeet's superior technical-vocabulary recognition (VOCABULARY_SPIKE §4) is left on the
  table for V1.

**What would cause us to reconsider.** Phase 6's engine benchmark showing Parakeet materially
better on real bilingual speech; or Apple attaching a working biasing hook to
`SpeechTranscriber`.

---

## ADR-015 — Dictated text must never be silently lost

**Status:** **Accepted** — product invariant, mandated by the user 2026-08-22.

**Decision.** Once speech has been transcribed, that text **must remain recoverable** even if
every later stage fails. The last recoverable transcript lives in application state, is written
**before** insertion is attempted, and is reachable from the menu bar. This is part of the
state architecture from Phase 3 onward, before any of the failing stages exist.

**Why.** The measured failure modes are all *downstream of transcription*:

- insertion silently targeting the wrong element — Safari accepted a paste into its address
  bar while reporting success (TECH_RESEARCH §15.6.1);
- Secure Input refusing synthetic paste entirely, with no error (ADR-005);
- an accessibility-hostile app taking no text at all;
- Smart mode refusing, timing out, or returning malformed output (ADR-010).

In every one of those the transcription itself succeeded. Losing the user's words after
correctly hearing them is the worst outcome the app can produce — worse than any recognition
error, because the words are unrecoverable and the user has already moved on.

**Consequences for the architecture.**
1. `AppState` owns a `TranscriptRecovery` store, written at the moment a transcript is
   finalised — not after insertion.
2. The menu bar always offers **Copy Last Transcript** when one exists.
3. Any failure state must name what failed while leaving the transcript reachable.
4. Smart-mode failure falls back to the deterministic text, never to nothing.

**Trade-offs.** Transcripts persist in memory after use, which is a small privacy surface —
bounded by keeping only a short history and never writing it to disk in V1.

**What would cause us to reconsider.** Nothing. This is a floor, not a preference.

---

## ADR-016 — Right Command stays the default trigger; 150 ms stays the hold threshold

**Status:** Accepted (Phase 4, measured)

### Context

Right Command was chosen provisionally in ADR-014 without having been used. The
Phase 4 brief asked for a recommendation based on actual testing, and for the
hold threshold to be measured rather than assumed.

The keyboard in question has one Control (left), both Options, both Commands, and
F1–F12. Right Option is how `ó` and `ñ` are typed and is unusable as a default
for a bilingual writer. Right Control and F13–F19 do not physically exist.

### Decision

**Keep Right Command.** No conflict was observed in testing.

**Keep the 150 ms hold threshold.**

### Evidence

Across 52 sessions and 154 modifier transitions with the tap live:

- 32/32 intentional holds opened a session; 5/5 quick taps were swallowed.
- 20/20 clean begin/end pairs in the final production-config run; zero missed
  key-ups, zero unmatched events, zero tap disables.
- `⌘A ⌘C ⌘V ⌘Z ⌘Tab ⌘Space ⌘W` all behaved normally throughout. Every Left
  Command transition was observed at `phase=idle` and never matched.
- Right Option held for 2.0 s produced no session; `ó` still composes.
- Deliberate quick taps of Right Command measured **71–80 ms** (n=5).
  Intentional holds all exceeded 400 ms. 150 ms sits between the two populations
  with about 2× margin against the accidental side.
- press→`begin` p50 151.16 ms, p95 151.18 ms — overshoot over the threshold is
  at most 1.21 ms. release→`end` p50 0.02 ms.

The one apparent failure during testing — a session that stayed open for
2 m 41 s — was a stale `triggerMode = toggle` preference, not a Right Command
conflict and not a lost event (TECH_RESEARCH §18.4).

### Consequences

- The threshold is now backed by a measurement, and §18.2 records the tap/hold
  distributions so a future change has a baseline to argue against.
- **Phase 5 must implement a pre-roll audio buffer.** `begin` is 151 ms after the
  physical press, so capture that starts at `begin` loses the first syllable of
  every utterance. This is a hard requirement, not an optimisation.
- Right Command remains selectable-away-from: `HotkeyBinding.selectable` offers
  Right Command, Right Option, Left Control, Fn and F6–F9. Keys that do not exist
  on this keyboard were removed.

---

## ADR-017 — The trigger instruction must follow the trigger mode

**Status:** Accepted (Phase 4)

### Context

The menu displayed "Hold ⟨key⟩ to dictate" unconditionally. With
`triggerMode = toggle` persisted, releasing the key correctly did nothing — and
the app, following its own instruction, looked like it was dropping key-up
events. Roughly three minutes of Phase 4 testing went into chasing a
non-existent event-tap bug (TECH_RESEARCH §18.4).

### Decision

`MenuBarModel.triggerInstruction` derives from `triggerMode`:

- `.hold` → "Hold ⟨key⟩ to dictate"
- `.toggle` → "Press ⟨key⟩ to start, press again to stop"

A test asserts the toggle string never begins with "Hold ".

More generally: **any user-facing instruction that describes an interaction must
be derived from the setting that governs that interaction, never hardcoded.**
A wrong instruction does not merely confuse — it makes correct behaviour
indistinguishable from a defect, for the developer as much as the user.

### Consequences

- Adding a third trigger mode requires updating one computed property, and the
  test will fail if it is missed.
- The same reasoning applies to the settings window and to any future onboarding
  copy.

---

## ADR-018 — `triggerPressed`: a semantic physical-press event for pre-roll

**Status:** Accepted (Phase 5)

### Context

Phase 4 deliberately narrowed the hotkey service's output to `begin` / `end` /
`cancel`, so nothing above it knows CoreGraphics exists. Phase 5 then needed the
*physical* press — 151 ms earlier than `begin` — to start capturing before the
hold threshold, or the first syllable of every utterance is lost.

The obvious options were both bad: leak `CGEvent` upward, or let the audio layer
install its own event tap and own the left/right modifier decoding a second time.

### Decision

Add one intent to the pure gesture machine, `PressGesture.Intent.triggerPressed`,
surfaced as `HotkeyMonitoring.onTriggerPressed`. It carries no payload.

The lifecycle the coordinator orchestrates:

```
triggerPressed → audio.beginPreRoll()     provisional, bounded, discardable
begin          → audio.promoteToSession() splice pre-roll onto the session
end            → audio.finishRecording()  complete clip, pre-roll first
cancel         → audio.cancel()           discard everything
```

`triggerPressed` is **provisional** and is always resolved by exactly one of
`begin` or `cancel`. Sub-threshold release and Escape-before-threshold now both
emit `cancel`, which they did not in Phase 4 — before `triggerPressed` there was
nothing to cancel, and now there is. A unit test asserts every path out of
`triggerPressed` reaches one or the other, because a path that reaches neither
leaves the microphone open with no session.

Nothing user-visible happens at `triggerPressed`: the coordinator stays `idle`,
so a stray ⌘ press never flickers the menu-bar icon.

### Consequences

- The semantic boundary survives. No CoreGraphics type crosses it.
- `AudioCapturing` gained `beginPreRoll()` / `promoteToSession()` in place of
  `beginRecording()`; the pre-roll is the audio layer's concern, and the
  coordinator only sequences it.
- The coordinator tracks `isPreRolling` separately from `isSessionInFlight`,
  because an accidental tap opens a microphone without opening a session.
- A pre-roll that fails to start is reported at `begin`, not on the press, so a
  stray tap never shows the user an error.

---

## ADR-019 — Capture on demand; accept the ~165 ms microphone warm-up

**Status:** Accepted (Phase 5, measured)

### Context

The point of the pre-roll was to let the user speak the instant they press.
Measurement showed the pre-roll faithfully retains 85–104 ms of audio — and that
this audio is **digital silence**, because the built-in microphone produces
nothing for its first ~165 ms (TECH_RESEARCH §19.1). Physical press → first real
audio is ~165 ms; the hold threshold is 150 ms.

So on this hardware the pre-roll currently recovers approximately zero usable
audio. Removing the ~165 ms floor requires the engine to be already running,
which means holding the microphone open while idle.

### Decision

**Keep capture on demand.** The engine is prepared at launch and started on the
physical press; it is stopped whenever no dictation is in flight.

**Keep the pre-roll** despite it recovering little today.

### Rationale

Holding the microphone open all day is a battery cost and, more importantly, a
claim about the user's privacy that this app should not make — a menu-bar
dictation tool with a permanently live microphone is exactly the thing users are
right to be suspicious of. The Phase 5 brief rules it out explicitly, and that
judgement stands on its own merits.

Keeping the pre-roll costs nothing measurable and is what makes the app robust to
the arithmetic changing: an external USB microphone that settles in 40 ms, or a
shorter hold threshold, immediately turns the pre-roll into real recovered audio.
Deleting it because today's hardware happens to hide the problem would be
optimising for one machine.

What actually delivers "speak immediately" today is that human reaction time
(~250 ms+ to voice onset, measured at 220–430 ms with a deliberate hard
consonant) exceeds microphone warm-up. That is a real property, but it is luck
rather than design, and it is written down here so nobody later mistakes it for a
guarantee.

### Consequences

- Press → capture start is 44–56 ms; press → first real audio is ~165 ms.
- If a user ever reports a clipped first syllable, the fix is *not* a longer
  pre-roll ring — it is the warm-up floor, and the options are a warm engine or a
  longer hold threshold.
- Idle cost is measured and near zero: 40.7 MB, 0.0 % CPU, engine stopped.
- Revisit if Phase 10's HUD needs a live level meter while idle, which would
  force the same trade-off into the open.

---

## ADR-020 — Streaming recognition: the engine consumes audio while the user speaks

**Status:** Accepted (Phase 6, measured)

### Context

The Phase 3 boundary was `transcribe(_ clip: AudioClip) async throws -> EngineTranscript`
— a batch call made after key-up. Apple's `SpeechAnalyzer` is a streaming API,
and the Phase 2 spike measured 76–151 ms key-up → visible text precisely because
analysis happened *during* speech. Keeping the batch shape would have thrown
that away: transcription would start from zero at release, and its cost would
scale with utterance length.

Measured directly. Feeding a whole clip at finalise time (the batch path, used
by the corpus harness) takes **531 ms for 32 s of audio**. Streaming the same
kind of utterance live takes **49.9 ms for 25 s**.

### Decision

Replace the batch method with a streaming lifecycle on `SpeechEngine`:

```swift
prepare(locale:)                          once, at launch
beginSession(locale:audio: AsyncStream)   at semantic `begin`
finishSession() -> EngineTranscript       at `end`
cancelSession()                           at `cancel`
```

`AudioCapturing.promoteToSession()` now returns `AsyncStream<[Float]>`, whose
first element is the spliced pre-roll, followed by each converted buffer as it
arrives. The coordinator opens the recognition session at `begin` and awaits it
at `end`.

`transcribe(_:locale:)` survives as a **protocol extension implemented in terms
of the streaming API**, chunked at 100 ms. The corpus harness and the live
pipeline therefore exercise the same code — there is one transcription
architecture, not two.

### Deviation from the brief

The brief suggested `consumeAudio` as a separate call. An `AsyncStream` parameter
was used instead: it is the same channel expressed in the idiom
`SpeechAnalyzer.start(inputSequence:)` already uses, it gives cancellation and
completion for free, and it avoids one actor hop per 10 ms audio buffer.

The stream is **unbounded**. Bounding it would mean dropping audio to protect a
queue, which silently truncates a transcript — the one failure this app must
never have. At 16 kHz mono Float32 the feed is 64 KB/s and the analyzer keeps up.

### Results

| Audio | key-up → transcript |
|---|---|
| 4.89 s (EN) | 174.4 ms |
| 6.29 s (EN) | 116.9 ms |
| 25.09 s (EN) | **49.9 ms** |
| 5.29 s (ES) | 89.2 ms |
| 33.39 s (ES) | 71.3 ms |
| 37.99 s (ES) | 86.6 ms |

All far below the 500 ms target, and **longer utterances finalise faster than
short ones** — with more speech behind it the analyzer has less tail left to
drain at release. That inversion is the signature of the design working; a batch
implementation shows the opposite slope.

### Consequences

- Cancellation must tear down the analyzer as well as the audio. A surviving
  session would finalise a transcript the user explicitly refused, and could
  leak it into the next dictation. `cancelSession()` is called from Escape,
  from a capture interruption, and never followed by `finishSession()`.
- Single-flight cannot rest on actor isolation. `beginSession` re-checks its
  guard *after* the `prepare` suspension point, because actors are reentrant
  across `await` — the guard would otherwise be decorative. Unit-tested.
- The corpus harness measures the batch path, so its numbers are not comparable
  to live latency. `CORPUS_VALIDATION.md` says so where the numbers appear.

---

## ADR-021 — Locked processing order: vocabulary → deterministic → optional Smart

**Status:** Accepted (V1 milestone)

### Context

Four transformations sit between the recogniser and the cursor: personal
vocabulary, deterministic cleanup, optional model polish, and insertion. Their
order is not arbitrary.

### Decision

```
EngineTranscript → vocabulary → deterministic cleanup → [Smart] → FinalText → insertion
```

**Vocabulary first, always.** Phase 2.5 measured that vocabulary-before-LLM beat
LLM-on-raw-transcript in every divergence, and that the model cannot recover
technical terms on its own — it left `ductation` untouched and rendered
`glock code` as `Glock Code`. Running vocabulary first also means capitalisation
sees the corrected product name rather than sentence-casing the recogniser's
guess.

Changing this order requires new measurements, not an opinion. A unit test
asserts vocabulary precedes both cleanup and capitalisation.

### Consequences

- `SpeechEngine` performs no text work at all; `EngineTranscript` is exactly what
  the recogniser returned.
- Smart mode receives the *deterministic* output, never the raw transcript, so
  its input already has the right product names in it.
- The deterministic result exists before Smart runs, which is what makes the
  Smart fallback free (ADR-022).

---

## ADR-022 — Smart mode is optional polish, not accuracy

**Status:** Accepted (V1 milestone, measured)

### Context

Phase 2.5 measured the on-device model changing 6 of 20 utterances: it helped 3,
harmed 2, and partially helped 1. It also invents plausible-but-wrong language,
and it translated Spanish transcripts into English until the instructions were
rewritten *in Spanish*.

### Decision

Fast is the default and stays the safer mode. Smart is opt-in and is described
to the user as **more polished**, never as more accurate.

Every Smart failure path returns the deterministic text unchanged: refusal,
timeout (4 s), model unavailable, empty output, a surviving code fence, or a
length ratio outside 0.4–1.6×. There is no route through `SmartCleanup` that can
lose the transcript.

### Measured on a 46-second English passage

Smart made three real corrections the deterministic pipeline cannot:

| Engine output | Smart output |
|---|---|
| "speech engine, engine corrects" | "speech engine, **the** engine corrects" |
| "cleans up the **feeler** words" | "cleans up the **filler** words" |
| "rather than **use** a demonstration" | "rather than a demonstration" |

It did **not** resolve the false start "whether whatever my cursor", nor the
spurious sentence break "when I'm writing code. Answering email".

Cost: **2004 ms** for 740 characters, against 5 ms for the deterministic path —
above the ~1.5 s Phase 2.5 projection. End-to-end 2207 ms versus 119 ms in Fast.

### Consequences

- The Smart cost is not hidden: it is logged per dictation and reported here.
- Fast remains default. Smart is for prose that will be read by others, not for
  the fast back-and-forth of writing code or chatting.
- The sanitizer is not optional. Under repeated runs the model intermittently
  replies conversationally — `Sure, here is the cleaned-up transcript:` plus a
  code fence — and pasting that into the user's document is far worse than
  leaving a recognition error in.

---

## ADR-023 — Insertion refuses by structure, not by label

**Status:** Accepted (V1 milestone, measured)

### Context

The Phase 2 spike pasted a dictated sentence into Safari's **address bar** and
reported success. A posted ⌘V proves a keystroke was delivered, never that text
reached the intended destination.

Two subsequent attempts to fix this by *labels* both failed in live testing:

1. **Refuse known-bad subroles** (`AXURIField`, `AXSearchField`). On macOS 26
   Safari's address bar reports **no subrole at all**, so a dictated sentence
   went straight into it again.
2. **Require an `AXWebArea` ancestor in browsers.** This caught Safari, but
   Chrome does not expose one without `AXManualAccessibility`, so it refused
   *every* Chrome insertion — Gmail, WhatsApp Web and ChatGPT all failed with a
   warning and no text.

### Decision

Refuse based on **where the element sits in the accessibility tree**, not on
what it calls itself. Walking up to 10 ancestors, an `AXToolbar`, `AXSheet` or
`AXPopover` means window chrome, and dictated prose never belongs there.

Verified by probing both browsers directly:

```
Safari address bar:  ancestors: AXGroup < AXToolbar < …   allows: false
Chrome address bar:  ancestors: AXGroup < AXToolbar < …   allows: false
Chrome page field:   ancestors: AXGroup < AXGroup  < …    allows: true
```

Secure fields are refused by subrole, which *is* reliable, and a mid-dictation
app switch is refused by comparing the bundle identifier captured at dictation
start against the one present at insertion.

### The AX inserter must not rewrite the whole value

A related failure, found in the same testing round. `AccessibilityInserter`
originally read `AXValue`, spliced the new text in at the caret, and wrote the
result back. In Electron and web views `AXValue` is **not** the field's editable
content — it returns the whole visible buffer including placeholder and hint
text. Writing it back materialised those hints as real text and duplicated the
utterance:

- VS Code produced "Testing dictation in VS Code. ⌘ Esc to focus or unfocus Claude"
- Codex typed the sentence **twice**, plus "Do anything"

Neither string was ever spoken. `AXSelectedText` is the correct API: it replaces
the selection, or inserts at the caret when the selection is empty, and touches
nothing else. Where it is not settable the strategy declines and the chain falls
through to pasting. A test asserts the value-splicing code never returns.

### Consequences

- Declining to insert is a **good outcome**, and the refusal message names the
  destination and points at Copy Last Transcript.
- In practice AX succeeds on native fields and declines on Electron and web
  views, where clipboard paste carries the load at ~125 ms.
- Clipboard contents are restored only when `changeCount` proves the user has not
  copied something during processing. Theirs wins.


## ADR-024 — GitHub distribution: agent-installable, no per-user identity in the repo

**Status:** **Proposed** — tracked requirement, not started. Target: after the app is judged
good from field use, no earlier than 21 Sept 2026.

**Decision.** When this app is published to a public GitHub repo, the goal is that any Mac
user can have their own AI agent clone the repo and get a working local install, entirely on
their machine, with nothing in the repo or the resulting build that identifies or points back
to the original author.

This **supersedes ADR-011 for the distribution build path**. ADR-011's self-signed certificate
mechanism (a script-generated identity-based cert, so TCC grants survive rebuilds) is still
correct — but it must run **per installing user**, not ship as one certificate baked into the
repo. `Scripts/create-signing-cert.sh` already generates the cert locally rather than importing
one, so the mechanism itself likely carries over; what has to be checked before publishing:

- No certificate, cdhash, designated requirement, or keychain reference anywhere in the repo
  or docs that is specific to the author's machine (CLAUDE.md currently quotes one leaf hash —
  that line must not ship as-is, or must be rewritten as a generated example).
- No hardcoded local file paths, usernames, or other identifying strings in source, scripts, or
  committed config.
- An install flow an agent can execute unattended from the README alone: clone → run signing
  script → build → grant TCC permissions → launch, with no step that assumes the author's
  environment.

**Before publishing, two reviews are required** (the user's explicit condition, to avoid
exposing themselves to compromise by shipping something that acts against them):

1. A **code review** of the full repo.
2. A **security review** of the full repo — the app runs a system-wide `CGEventTap`, reads
   Accessibility, and inserts text into arbitrary apps, so this is not optional polish.

**Alternatives considered.** Developer ID + notarization (ADR-011's "what would cause us to
reconsider" clause) — still out of scope; would cost $99/year and couples releases to an Apple
account, and per-user self-signing already solves the TCC problem without it. Not revisited
unless a self-signed cert stops satisfying Gatekeeper for downloaded (quarantined) clones.

**What would cause us to reconsider.** Evidence that a freshly cloned, quarantined repo hits
Gatekeeper friction a locally-built app doesn't (ADR-011 assumed a non-quarantined local build,
which no longer holds once the app is downloaded from GitHub) — then notarization gets
reconsidered.

### ADR-022 amendment — field feedback, 15 Sept 2026

The flat 4 s Smart budget failed real use: 1282 characters took 3989 ms, and
longer messages silently fell back. The budget now scales with input,
`clamp(2 s + 6 ms × chars, 4 s, 15 s)`, and a fallback is surfaced in the menu
bar icon and menu. The "every failure returns the deterministic text" guarantee
is unchanged; what changed is that the user can now see when it happened.

---

## ADR-025 — Hands-free by double-tap, additive to hold-to-talk

**Status:** Accepted (21 Sept 2026). Requested by the author: holding a key for a long
dictation is tiring.

**Decision.** In hold mode, a clean tap of the trigger followed by a second press within
**350 ms** locks a session open. `begin` fires on the second press; releasing it does nothing;
the next press ends the session; Escape cancels; a hard limit of **285 s** ends it (and still
transcribes) so an abandoned session cannot leave the microphone open. Hold-to-talk is unchanged
and remains the default (ADR-016). It is on by default and a Settings toggle turns it off; toggle
mode is untouched.

**Design points that matter.**
- The logic lives in `PressGesture` (pure, deterministic, clock-free); the monitor owns only the
  two timers. 14 gesture tests cover it.
- **A tap used as a shortcut is not a tap.** Any other key going down while the trigger is held
  marks the press as a chord: it never arms a double-tap, and (see below) never starts a
  dictation. This is what keeps ⌘C then ⌘V on Right Command from locking the microphone open.
- The first tap still discards its pre-roll as before; the microphone opens on the second press,
  so the first ~0.16 s after a double-tap can be clipped (ADR-019's warm-up).
- The limit (285 s) sits below the capture buffer's 300 s so the tail is not clipped.
- Known edge: a double-tap while the previous dictation is still processing is ignored, like a
  hold in the same state.

**Bug found and fixed while building it.** Holding the trigger past 150 ms began a dictation
*even if another key had been pressed*, so a slightly slow ⌘V with Right Command flashed the HUD
and ran an empty dictation. A chorded press now cancels at the threshold. A chord key pressed
*after* the threshold (a very slow ⌘V) still starts a session; cancelling then could destroy real
dictation, so it was deliberately left.

## ADR-026 — The listening HUD: a caret-anchored waveform pill

**Status:** Accepted (21 Sept 2026). Closes Phase 10.

**Decision.** A floating pill shows a live waveform while listening, "Transcribing…/Cleaning
up…/Inserting…" afterwards, and, in hands-free mode, "Tap Right Command to finish · Esc cancels".
It is placed **under the text cursor**, found through Accessibility, with a fallback chain: the
caret, the glyph beside it, the focused element (below a small one, inside the bottom of a large
one), then the bottom of the screen. The position is looked up once per session (bounded to
200 ms, on a worker) and never moves while you speak.

**It must never take focus.** Text is inserted wherever focus is, so the panel is non-activating,
cannot become key or main, ignores the mouse and is ordered front without activating. It is the
only visible sign the microphone is open in hands-free mode, so it defaults on.

Levels come from `consumePeakLevel()` (which the capture buffer already exposed) at 30 Hz, mapped
on a decibel scale with a −50 dB floor and −6 dB ceiling because speech peaks sit far below full
scale. Reduce Motion is honoured. Chrome, Electron and web views often will not report a caret,
which is why the fallback chain exists.

## ADR-027 — Question marks: a narrow deterministic stage

**Status:** Accepted (21 Sept 2026).

**Context.** In a 56-dictation field log Apple's engine wrote 30 question marks and missed real
questions (long ones, or ones it heard as statements: "it's that intended."). Smart also dropped
one when it merged two sentences. Nothing downstream added a mark, so the author typed each by
hand. The engine decides from the words; pitch does not appear to count.

**Decision.** `QuestionMarkStage` turns a closing "." into "?" only when the sentence opens like a
question **and** the next word is what a question puts there: auxiliaries (is/are/does/can…) before
a pronoun, determiner, number or proper noun; wh-words only before an inverted auxiliary or a
"be" plus determiner/pronoun; negative contractions only before a pronoun. Statements that
borrow an opener stay statements ("When I was…", "What is important is…", "Would love to…",
"Can't wait", "Do it now", "Will Smith is…"). It only ever swaps one character, is idempotent,
English-only, skips decimals/file names/abbreviations, and never overrides an existing mark. It runs
in the deterministic pipeline and again on Smart's output. It can be switched off
(`ProcessingOptions.fixQuestionMarks`).

**Evidence.** 73 unit tests in the package; run over all 57 real logged dictations it changed 2
(both real questions) and produced no false positive, including the "When I was…" statement.
Limit: it cannot help a question the engine words as a statement, and it does nothing in Spanish.

## ADR-028 — A generated starter dictionary, harvested from the real recogniser

**Status:** Accepted (21 Sept 2026). Makes "works without weeks of training" true on day one.

**Context.** The personal dictionary (ADR-008) is reactive: each name must be misheard once.
Engine-level biasing was measured and rejected (VOCABULARY_SPIKE); it is also what other
developers report for `SpeechTranscriber` (its `contextualStrings` is accepted and ignored).

**Decision.** Ship a bigger dictionary of *mishearings of known terms*, produced not by guessing
but by measurement: `Scripts/vocab/harvest.py` speaks 177 terms with 9 English and 4 Spanish
system voices (6,195 clips), runs the app's own recogniser headlessly (`--transcribe-dir`), and
keeps only mistakes heard by at least two clips and two voices, close in sound to the term, never
a single ordinary English or Spanish word (system word list + macOS spell checker), with no comma,
apostrophe or lone leading letter. **A human then reads the survivors** and refuses real phrases
(`Scripts/vocab/review.json`: "get up → GitHub", "my journey → Midjourney", "sales force →
Salesforce", "Xavier → Zapier", "test flight → TestFlight"…). Casing-only rules are kept only
where the engine was seen writing the wrong case and the lower-case form is not ordinary prose
("veo" is Spanish for "I see", "haiku" and "grok" are words).

**Result.** 115 generated rules (92 mishearings + 23 casing) join the 75 hand-observed ones: 181 in
the author's dictionary, 173 shareable. Real-phrase mappings the author wants (`higgs field`,
`open eye`) live in `PersonalSeed`, which the public copy omits (ADR-029).

**Guarantees, held by tests.** A list of 22 ordinary sentences, including every trap the harvest
found, must pass through the dictionary unchanged; no mishearing rule may be a single valid word;
no fragile forms; the dictionary has no duplicates and hand-written rules win over generated ones.
Run against all 57 real logged dictations the new rules fired 5 times, all correct.

**Cost.** 1,000 rules ≈ 2.8 ms per dictation (measured; linear), against a Fast-mode budget of
about 115 ms and Smart's 1.3 s median. Pattern compilation is ~0.25 ms per rule, so the cache is
**warmed at launch**, off the main thread, or the first dictation would pay for it.

**Delivery.** `currentSeedVersion` is bumped (5 → 6). The existing merge adds the new built-ins
to an existing dictionary without touching the person's own rules or resurrecting deleted ones.

**Limits.** Synthetic voices are indicative (§15.4). About 1,200 variants were heard once or by
one voice and dropped. Spanish product names still converge slowly.

## ADR-029 — Public distribution: a generated clean copy, one-command install, per-user tuning

**Status:** Accepted (21 Sept 2026). Implements ADR-024's requirements; publishing itself still
waits for the author's explicit go-ahead.

**Decision.**
- **Never rename in place.** macOS pins privacy grants to the app identifier, so changing
  the author's app identifier in the working copy would reset the author's Microphone,
  Accessibility and Input Monitoring. Instead `Scripts/export-public.sh` writes a *separate*
  folder with a generic identifier, no benchmark recordings, no personal seed, no field notes, a
  public README/AGENTS/CLAUDE/AGENT_INSTALL/AGENT_TUNING/SECURITY, and an MIT licence. It **fails
  if any identifying string survives** (name, email, certificate hash, absolute paths, product
  names) or if audio or key files are present. It never runs git and never pushes.
- **One command for an agent:** `Scripts/install.sh` checks the Mac, creates the local
  certificate, builds, installs to `~/Applications`, verifies the signature is stable, registers
  permissions and starts the app, then prints the human-only steps. `Scripts/doctor.sh` reports
  what the running app itself sees. Neither uses sudo or touches TCC.
- **Tuning is text rules, not training.** `AGENT_TUNING.md`, `add-rule.py` (refuses ordinary
  words, backs up, quits and restarts the app) and `suggest.py` (unknown words in the opt-in log).
- The public copy's history starts fresh, so the author's commit identity and the certificate hash
  in the old `CLAUDE.md` never ship.

## ADR-030 — Review-driven fixes (21 Sept 2026)

Full findings are in `docs/public/SECURITY.md`. Changes: dictated text is written to the
clipboard with transient/concealed markers; Accessibility insertion calls are time-bounded; the
secure-input holder lookup runs off the main actor; the transcript log rolls at ~4 MB; the
hands-free limit sits below the capture ceiling; the developer WAV reader rejects an empty data
chunk.

## ADR-031 — Automatic English/Spanish: both recognisers listen, each stretch from the one that understood it

**Status:** Accepted (3 Oct 2026). Opt-in setting "Automatic (English + Spanish)"; English stays
the default. Supersedes the deferral in IMPLEMENTATION_PLAN Phase 7 criterion 9.

**Why now.** The field log (161 dictations, 15 Sept–3 Oct) has **zero** dictations in Spanish
mode: the author never switches, so Spanish always goes through the English model and comes out
unreadable, worst when a message mixes the two. The manual switch exists and is not used.

**Decision.** In automatic mode one `SpeechAnalyzer` hosts an `en-US` and an `es-ES`
`SpeechTranscriber`, both asked for per-word `audioTimeRange` and `transcriptionConfidence`.
`BilingualMerge` (TextProcessingCore, pure) cuts the timeline at sentence ends, result ends and
pauses ≥ 0.35 s from either model, and gives each stretch to Spanish only when the Spanish
model's text is ≥ 0.9 Spanish by `NLLanguageRecognizer` **and** the English model visibly failed
there (its text ≥ 0.5 Spanish, it heard no letters, or it is ≥ 0.25 less confident). Stretches
too short to judge follow their neighbours. If the whole dictation lands in one language, that
model's text is returned untouched; only a mixed dictation is reassembled, each part cleaned with
its own language's rules. Smart is skipped for a mixed dictation (its prompts must match the
content language).

**Why both signals.** Confidence alone fails: on benchmark #1 the Spanish model was *more*
confident on English speech (0.88 vs 0.71, "Open Determinal"). Text language alone fails the
other way on short English. Apple's API has no language identification of its own.

**Measured** (`--probe-languages <dir>`, TECH_RESEARCH §24): the author's 20 benchmark
recordings 20/20 correct language, English-only path still 20/20 identical in
`--validate-corpus`; 27 synthetic mixed clips (3 voices × EN→ES, ES→EN, EN→ES→EN × 3 pause
lengths) word error 0.44 English-only → 0.30 Spanish-only → **0.09 merged**. Release-to-text
latency at speaking pace within 0–160 ms of English-only.

**Risks.** No real mixed recordings of the author exist yet: the synthetic set uses clean TTS
voices. Both models run for every dictation (more energy). A Spanish word inside an English
sentence ("Hola") stays English by design.

**Amended after three live tests (3–4 Oct).** (1) At a switch, a word mostly overlapping the last
word already kept is dropped: both models wrote the seam word, a little apart in time. (2) Up to
3 English words the Spanish model heard nothing of follow their neighbours: a breath before
Spanish speech had become an English phrase. (3) A word that alone reads ≥ 0.95 Spanish in the
English model's text tips a Spanish stretch (a half-English Spanish sentence stayed English), and
stretches of ≤ 2 words on both sides follow their neighbours (a sentence's last word was split
off with a full stop before it). After each: real 20/20, mixed WER 0.08–0.09. A part that follows
a comma keeps its lowercase start.

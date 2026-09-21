# Phase 2.6 — Engine-Level Vocabulary Biasing

**Question:** can we materially reduce technical-vocabulary recognition errors **before** the
transcript reaches our deterministic correction layer?

**Answer: partly — and not in a way worth shipping in V1.** One real mechanism exists and
measurably works, but only on a materially worse recogniser. The recommendation is to keep
deterministic personal vocabulary as the V1 solution. Details below.

Date: 2026-08-22 · macOS 26.5.2 · Xcode 26.6 · all local, no cloud, no paid services.

---

## 1. What Apple supports

Three mechanisms exist in the shipped SDK. I inspected
`Speech.framework/…/arm64e-apple-macos.swiftinterface` and the ObjC headers directly rather
than relying on documentation.

| Mechanism | Attaches to | Status |
|---|---|---|
| `AnalysisContext.contextualStrings` | **`SpeechTranscriber`** (our default engine) | **Present, measured, no effect** |
| `SFCustomLanguageModelData` + `ContentHint.customizedLanguage` | **`DictationTranscriber`** only | **Genuine biasing, works** |
| `SFSpeechRecognitionRequest.contextualStrings` | legacy `SFSpeechRecognizer` | superseded, not tested |

**This corrects TECH_RESEARCH §15.2**, which stated the new API had no custom-vocabulary
facility. It has two. I had only looked at `SpeechTranscriber`'s own surface and missed both
`AnalysisContext` and the `SFSpeechLanguageModel` family.

### 1a. `AnalysisContext.contextualStrings` — exists, does nothing

```swift
let context = AnalysisContext()
context.contextualStrings = [.general: ["Claude Code", "Supabase", …]]
let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber],
                                        options: nil, analysisContext: context,
                                        finishAfterFile: true)
```

Measured across **13 fixtures** (3 real recordings + 10 TTS), English and Spanish:
**output was byte-identical with and without contextual strings, in every single case.**

Ruled out as harness error:
- the property was **read back** after setting to confirm the strings were retained;
- both delivery paths were exercised — the `analysisContext:` initialiser parameter **and**
  `analyzer.setContext(_:)` after construction;
- the same code path demonstrably works, since it produces correct transcripts.

Conclusion: on macOS 26.5.2 `contextualStrings` is **accepted and ignored** by
`SpeechTranscriber`. It may be reserved for other modules or for future use.

### 1b. `SFCustomLanguageModelData` — a real custom language model, and it works

This is genuine decoder-side biasing: training phrases are compiled into a language-model
binary that the recogniser loads.

```swift
let data = SFCustomLanguageModelData(locale: locale, identifier: "…", version: "1")
data.insert(phraseCount: .init(phrase: "configurar Supabase con Claude Code", count: 30))
try await data.export(to: trainingURL)
try await SFSpeechLanguageModel.prepareCustomLanguageModel(
    for: trainingURL, clientIdentifier: "…\(locale)", configuration: config, ignoresCache: true)

let transcriber = DictationTranscriber(
    locale: locale,
    contentHints: [.customizedLanguage(modelConfiguration: config)], …)
```

It also supports **custom pronunciations** (`CustomPronunciation(grapheme:phonemes:)`), a
template phrase generator, and — new in macOS 26 — a **`weight`** parameter (0.0–1.0) on
`SFSpeechLanguageModelConfiguration`.

**The catch: it only attaches to `DictationTranscriber`, the legacy engine.** There is no
equivalent hook on `SpeechTranscriber`.

**Two practical gotchas found:**
- **The `clientIdentifier` caches the compiled model.** Reusing one identifier for `en-US` and
  then `es-ES` in the same process makes the second build fail with a bare
  `SFSpeechErrorDomain Code=1`. Bisecting proved the content was fine — the identifier must be
  locale-specific, and/or `ignoresCache: true` must be passed. This cost an hour and initially
  looked like "Spanish is unsupported".
- **Locale support is narrow.** Probed directly: `en-US` ✅, `en-GB` ✅, `es-ES` ✅,
  but `es-MX` ❌, `es-US` ❌, `fr-FR` ❌ (all `SFSpeechErrorDomain code=1`).

Build cost: training data export **0–3 ms**, model compile **514–642 ms**, producing a
**6.4–7.2 MB** binary. One-time, cacheable.

## 2. What Parakeet / FluidAudio supports

FluidAudio v0.15.6 ships a **`CustomVocabulary` subsystem**: `CustomVocabularyContext`,
`CtcKeywordSpotter`, `VocabularyRescorer`, a BK-tree for fuzzy candidate lookup, and
`configureVocabularyBoosting(vocabulary:ctcModels:config:)`.

**This corrects Phase 2.5 §1.1**, which concluded FluidAudio offered nothing beyond script
filtering. That was wrong — I had only examined the `language:` parameter.

**Classified honestly**, as instructed. From the library's own source:

> *"This implements 'shallow fusion' or 'CTC rescoring' … The rescorer computes ACTUAL CTC
> scores for both vocabulary terms AND original words, enabling a fair comparison rather than
> relying on heuristics."*

| Category | Verdict |
|---|---|
| Actual decoder / recognition biasing | **No.** It does not alter the TDT beam search. |
| Token filtering | No — that is the separate `language:` script filter. |
| Post-transcription replacement | **Yes, but acoustically verified.** |

It is a **second-pass acoustic rescorer**: a separate CTC model runs over the same audio, and a
vocabulary term replaces a decoded word only where CTC log-probabilities support it. That is
**materially stronger than our deterministic dictionary**, which matches strings blindly and
cannot decline an unsupported substitution — but it is **not** decoder-time biasing and should
not be called that.

**Availability is split across two managers, and this turns out to decide the outcome:**

| Manager | Model | Vocabulary boosting | Batch API |
|---|---|---|---|
| `UnifiedAsrManager` | `parakeet-unified-**en**-0.6b` — **English only** | ✅ | ✅ |
| `SlidingWindowAsrManager` | Parakeet **TDT v3** — multilingual | ✅ | ✗ streaming only |
| `AsrManager` (what we spiked in Phase 2.5) | TDT v3 — multilingual | ✗ | ✅ |

## 3. What was experimentally tested

| Experiment | Command |
|---|---|
| `contextualStrings` on `SpeechTranscriber`, ± context | `--spike-vocab-bias` |
| Custom LM on `DictationTranscriber`, ± model | `--spike-customlm` |
| Custom-LM locale support matrix | `--spike-clm-probe` |
| es-ES training-content bisect | `--spike-clm-bisect` |
| `DictationTranscriber` regression over the real corpus | `--spike-engine-cost` |
| FluidAudio CTC rescoring, ± boosting, weight sweep, WER | `--spike-fluid-vocab` |
| Parakeet regression over the real corpus | `--spike-fluid-corpus` |
| Parakeet **TDT v3** multilingual + vocabulary | `--spike-fluid-multi` — **did not complete, see §8** |

**Corpus:** 3 real recordings from the Phase 2.5 benchmark — including
`configurar Supabase con Claude Code`, the reported failure — plus 10 TTS coverage sentences.
TTS is *indicative only* (TECH_RESEARCH §15.4). **34 term-recognition opportunities.**

## 4. Before / after — the four paths

Terms correctly recognised, out of 34:

| # | Path | Terms | General agreement vs `SpeechTranscriber` | Latency |
|---|---|---|---|---|
| **1** | **Apple `SpeechTranscriber`** (current default) | **11 / 34** | — (reference) | 94 ms |
| **2** | **Apple `DictationTranscriber` + custom LM** | **15 / 34** | **90%** (EN+ES) | no penalty |
| **3** | **Parakeet / FluidAudio baseline** (Unified, EN-only) | **18 / 34** | **63%** — EN 88%, **ES 9%** | 73 ms |
| **4** | **Parakeet + `CustomVocabulary`** | **31 / 34** | **61%** — EN 86%, **ES 8%** | 214 ms |

**Path 4 is by far the best term recovery — and it is unusable, for a reason unrelated to
vocabulary.** See §8.

### Path 2 — custom LM works

```
Anthropic Dogs  ← "check the tropic dogs"      (real recording #8)
SwiftUI         ← "swift UI"
Parakeet        ← "para gate"
Claude Code     ← "Clock Code"                 (real recording #19)
```

### Path 4 — dramatic recovery, including the exact reported failure

```
real-19  "configurar Supabase con Claude Code"   1/3 → 3/3   BOTH terms recovered
en-4     CoreML, FluidAudio, Parakeet            2/3 → 3/3
es-4     CoreML, FluidAudio, Parakeet            1/3 → 3/3
es-3     Anthropic, Claude, OpenAI, ChatGPT      2/4 → 4/4
en-5     Wispr Flow ← "Whisper Flow"             0/1 → 1/1
```

Word error against exact TTS ground truth **improved**, 38% → 32%. The vocabulary pass makes
transcription better overall, not just on the terms.

**But it also fabricates.** Vocabulary terms get written over ordinary words:

```
"login wall for my users"  →  "login wall CoreML users"
"open VS Code to check"    →  "OpenAI CoreML check"
"I use Claude Code"        →  "I Claude Code"
```

**One tuning finding worth keeping.** Listing `Claude` as a standalone term made the rescorer
replace the ordinary word *"code"* with *"Claude"*, corrupting `VS Code → VS Claude` and
`Claude Code → Claude Claude`. Removing it lifted recovery from **27/34 to 31/34** and cut the
damage. **Short terms phonetically close to common words are actively dangerous in a CTC
rescorer** — the opposite of the deterministic dictionary, where a short exact rule is safe.

Term weight (10.0 / 3.0 / 1.5) changed **nothing** — not the useful knob.

## 5. English results

| Path | Terms (of 19) | EN agreement |
|---|---|---|
| `SpeechTranscriber` | 9 | reference |
| `DictationTranscriber` plain | 8 | — |
| `DictationTranscriber` + custom LM | 11 | 90% (EN+ES) |
| Parakeet plain | 12 | 88% |
| **Parakeet + CustomVocabulary** | **~19** | 86% |

For English alone, path 4 is genuinely strong: near-total term recovery for ~2 points of
general agreement and +140 ms.

## 6. Spanish-with-English-technical-terms results

| Path | Terms (of 15) | **ES agreement** |
|---|---|---|
| `SpeechTranscriber` | 2 | reference |
| `DictationTranscriber` plain | 1 | — |
| `DictationTranscriber` + custom LM | 4 | 90% (EN+ES) |
| Parakeet plain (Unified) | 6 | **9%** |
| Parakeet + CustomVocabulary | 12 | **8%** |

**The Spanish agreement figures for paths 3 and 4 are catastrophic, and the cause is not the
vocabulary layer — it is the model.** `UnifiedAsrManager` loads
`parakeet-unified-**en**-0.6b-coreml`, an **English-only** model. Measuring Spanish against it
repeats exactly the locale-mismatch error made earlier in Phase 2.5 (§15.7). On the 39-second
Spanish utterance, **99 of 100 words differed** from the `SpeechTranscriber` reference.

So paths 3 and 4 have **no valid Spanish measurement.** Their English numbers stand; their
Spanish numbers measure the wrong model and must not be read as a verdict on Parakeet.

On the real Spanish recording, for the paths that *are* valid:

```
spoken                      : Necesito configurar Supabase con Claude Code … en VS Code
SpeechTranscriber           : …configurar su pabase con Clock Code … en VS Code      2/3
DictationTranscriber        : …configurar su Page con Clock Code … en B Code         0/3
DictationTranscriber + LM   : …configurar su Page con Claude Code … en B Code        1/3
```

The custom LM fixed `Claude Code` and `DictationTranscriber` simultaneously broke `VS Code`
into `B Code`. **Net gain on the real Spanish sentence: zero.**

## 7. Latency impact

| | |
|---|---|
| Custom-LM training export | 0–3 ms (one-time) |
| Custom-LM compile | 514–642 ms (one-time, cacheable, 6.4–7.2 MB) |
| Transcription ± custom LM | **no measurable penalty** |
| FluidAudio CTC models, first load | 22.2 s (one-time download) |
| Parakeet ± CustomVocabulary | **73 → 214 ms (+141 ms)** |

+141 ms is affordable against the Phase 2.5 budget (Fast mode is 94 ms end-to-end). **Latency
is not the obstacle for any path.**

## 8. Is engine-level vocabulary biasing viable?

**Path 2 (Apple custom LM): technically yes, practically no.** It is welded to
`DictationTranscriber`, measured at **90% word agreement** with `SpeechTranscriber` over the
real 20-utterance corpus, 9 of 20 utterances below 90%, worst 78%. The trade is **+4 terms out
of 34 against ~10% general word error**. A dictated sentence holds one or two technical terms
and dozens of ordinary words. Bad exchange.

**Path 4 (FluidAudio CustomVocabulary): the most effective mechanism tested, and I could not
make it usable for this app.**

- It requires **either** `UnifiedAsrManager` — which is **English-only**, disqualifying for a
  bilingual app — **or** `SlidingWindowAsrManager`, which exposes it only through a streaming
  API.
- I attempted the multilingual TDT v3 path through `SlidingWindowAsrManager`
  (`--spike-fluid-multi`), feeding audio in 1-second chunks rather than one buffer.
  **It hung with no output and was killed after 20 minutes.** The likely cause is
  `startStreaming(source: .system)` blocking on system-audio capture instead of consuming
  pushed buffers. I did not pursue it further, per the scope limit.

**So the headline number — 31/34 — was obtained on an English-only model and does not
transfer to our bilingual requirement as measured.** I am reporting path 4 as *promising and
unresolved*, not as available.

## 9. Is it worth adding to V1?

**No.**

- **Path 1 + `contextualStrings`** — free, and does nothing. Not worth wiring.
- **Path 2** — works, but requires a recogniser that is ~10% worse across everything.
- **Path 4** — best term recovery by a wide margin, but only demonstrated on an English-only
  model; the multilingual route is unproven and hung under test. It also **fabricates terms
  over ordinary words**, which the deterministic dictionary never does.

Adopting path 4 would additionally reopen ADR-002 — Parakeet still has no English/Spanish
language control (§1.1, confirmed at runtime), which is the reason Apple is the default.

## 10. Recommendation

**V1: keep Apple `SpeechTranscriber` + the deterministic personal dictionary. Ship no
engine-level biasing.**

1. **No path improves the bilingual case.** Path 2 nets zero on the real Spanish sentence.
   Paths 3 and 4 have no valid Spanish measurement at all.
2. **The dictionary is exact, 0.13 ms, and cannot fabricate.** It fixed `clock code → Claude
   Code` and `su pae → Supabase` the moment rules were added — the same failures path 2 only
   half-fixed. Path 4, by contrast, invented `CoreML` where the user said *"for my"*.
3. **Its weakness is reactive, not incorrect** — each term must be misheard once. That is an
   onboarding cost, fully under your control, not a correctness risk.

**Pre-seed the observed variants** rather than waiting to encounter each:
`clock code`, `cloud code`, `glock code`, `claw code`, `su pae`, `supa base`, `superbase`,
`cloud flair`, `cloud flurry`, `whisper flow`, `whisker flow`, `swift ui`, `core ml`,
`score ml`, `get up`, `para gate`, `open eye`, `b code`. That captures most of what biasing
promised, at no risk.

**Carry two items into Phase 6, neither of them V1 work:**

- **FluidAudio's `CustomVocabulary` is the strongest mechanism found in this phase** — 18→31/34
  with WER *improving* 38%→32%. If Phase 6 evaluates Parakeet seriously, resolving the
  multilingual streaming path is worth a focused attempt. Acoustically-verified replacement is
  strictly better than blind string matching: it can decline a substitution the audio does not
  support, which our dictionary cannot.
- **Weigh technical-vocabulary accuracy explicitly in the engine benchmark**, not WER alone.
  Even English-only, Parakeet plain beat `SpeechTranscriber` on terms (12/19 vs 9/19).

**A caution for whoever picks this up:** the term list is not a free parameter. Adding
`Claude` as a standalone term *lowered* recovery from 31 to 27 and corrupted `VS Code` into
`VS Claude`. A CTC rescorer needs long, distinctive terms; short ones that rhyme with common
words do active damage.

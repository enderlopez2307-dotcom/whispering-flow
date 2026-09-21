# Starter vocabulary tools

The shipped dictionary (`StarterVocabulary.swift`) is **generated**, not hand-typed, so it can be
grown safely and re-checked whenever the recogniser changes.

## How it is made

1. `terms.txt` lists names people dictate (Supabase, Cloudflare, ChatGPT…).
2. `harvest.py synth` speaks each one, inside three English and two Spanish carrier sentences,
   with nine English and four Spanish voices built into macOS (`say`). ~6,000 clips.
3. `harvest.py transcribe` runs the **real** recogniser over them (the app's headless
   `--transcribe-dir`). No network.
4. `harvest.py analyze` compares what was written with what was spoken, and keeps a mistake only if:
   - at least **two clips and two different voices** produced it;
   - it sounds like the term (edit distance ≤ 40% of its length);
   - it is **not a single ordinary English or Spanish word** (system word list plus the macOS
     spell checker in both languages);
   - it does not start with a lone letter or contain a comma/apostrophe (those match inside
     things like "let's lint");
   - it does not point at two different terms.
   Casing rules (`supabase` → `Supabase`) are kept only when the engine was actually seen writing
   the wrong case and the lower-case form is not an ordinary word.
5. **A human reads what is left.** `review.json` records every form refused by hand and why
   ("get up → GitHub", "my journey → Midjourney", "Xavier → Zapier", "sales force → Salesforce"…).
   Synthetic voices find systematic mistakes; only a person can tell that "sales force" is a real
   business phrase.
6. `harvest.py emit` writes `Packages/TextProcessingCore/Sources/TextProcessingCore/StarterVocabulary.swift`.
7. `StarterVocabularyTests` hold the policy regardless of how the file was made: no rule fires on a
   list of ordinary sentences, no single ordinary word, no fragile forms.

## Run it

```bash
./Scripts/build.sh                                  # the harvest uses the built app
python3 Scripts/vocab/harvest.py synth              # ~10 min
python3 Scripts/vocab/harvest.py transcribe --binary .build/release/WhisperingFlow   # ~15 min
python3 Scripts/vocab/harvest.py analyze            # prints candidates + why others were dropped
# read the list, add refusals to review.json, then:
python3 Scripts/vocab/harvest.py emit
(cd Packages/TextProcessingCore && swift test)
```

Audio and results live in `build/vocab-harvest/` (git-ignored, safe to delete).

After changing the pack, bump `currentSeedVersion` in `VocabularyStore.swift`: that is what makes
the new built-in rules reach people who already have a dictionary, without touching their own rules.

## Limits

- Synthetic voices are only indicative (TECH_RESEARCH §15.4). This finds systematic mistakes,
  not every mistake a human accent will produce.
- Roughly 1,200 variants were heard only once or by one voice and were dropped on purpose.
- Spanish product names are re-spelled differently each run, so Spanish coverage converges slowly.

## Helpers for a single person's dictionary

- `add-rule.py` — add corrections to `vocabulary.json` safely (refuses ordinary words, backs up,
  handles the running app).
- `suggest.py` — read the opt-in local log and list words neither language recognises.
- `wordcheck.swift` — the spell-check helper both use.

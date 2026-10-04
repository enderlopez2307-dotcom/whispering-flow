# Make Whispering Flow more accurate for one person — instructions for an AI agent

Whispering Flow does **not** train a speech model on anyone's voice, and you cannot make it do
that. What it can do, and what makes it better over time, is a **personal dictionary of text
corrections** applied after Apple's engine has produced its transcript: "the engine wrote X,
the person meant Y". Each mistake is fixed once, permanently, in about 0.1 ms.

Ask the human before starting: the log this uses contains **everything they dictated**. Stay
local: never send the log or its contents anywhere.

## The loop

1. **Turn logging on** (opt-in, off by default). Menu-bar icon → Settings… → General →
   Diagnostics → *Record transcripts for troubleshooting*. It writes to
   `~/Library/Application Support/WhisperingFlow/whispering-flow-transcripts.log`.
2. **Let them use the app for a few days.** Nothing to do meanwhile.
3. **Find suspects:**
   ```bash
   python3 Scripts/vocab/suggest.py
   ```
   It lists words that neither English nor Spanish dictionaries recognise, most frequent first,
   with a little context. Brand names and mishearings both appear; you decide which is which.
4. **Read the log around the suspects** (each entry has `engine`, `deterministic`, `smart`,
   `final` lines) and work out what the person actually said. If it is not obvious, **ask
   them** rather than guess: a wrong rule silently changes their words.
5. **Add rules:**
   ```bash
   python3 Scripts/vocab/add-rule.py --restart "clock code" "Claude Code" "su pae" "Supabase"
   ```
   Arguments are pairs: *what the recogniser wrote*, then *what they meant*. `--restart`
   quits the app, edits the dictionary, and starts it again (the app would otherwise overwrite
   the change). A backup is written first. The person can also do it from the app: select the
   wrong text anywhere, menu-bar icon → **Add Correction to Vocabulary…**.
6. **Check it worked:** ask them to say the sentence again. Tell them what you added.

## Test a sentence or a rule without speaking

```bash
~/Applications/WhisperingFlow.app/Contents/MacOS/WhisperingFlow --process-text "check the calendarly link, is that possible."
~/Applications/WhisperingFlow.app/Contents/MacOS/WhisperingFlow --process-text "configurar su pae hoy" --es
```

It prints the text after the person's dictionary and the rule-based cleanup (Fast-mode behaviour;
Smart is not deterministic), and which rules fired. It reads the dictionary and changes nothing.
Vocabulary and question marks are deterministic, so **a few typed checks prove them; do not ask a
human to speak the same sentence over and over.** What varies from dictation to dictation is what
the speech engine writes, and that is only learned from the log.

## Rules for rules (they are what keeps this accurate)

- **Never add a rule whose spoken form is a single ordinary word** ("claw", "notion", "cloud").
  It would also rewrite every time they say that word on purpose. `add-rule.py` refuses these.
  Prefer a distinctive multi-word form ("claw code" → "Claude Code") or a non-word ("supabas").
- A rule is exact, case-insensitive, whole-word, longest match first. It replaces the whole
  spoken phrase with the replacement exactly as typed (so casing is yours to set).
- **Casing-only rules** (`supabase` → `Supabase`) are always safe for non-words.
- Rules never rewrite each other's output.
- English and Spanish share one dictionary, so a rule must be safe in both. Spanish speech
  contains "su", "se", "es"… — never build a rule on words like those.
- Spanish product names are re-spelled differently on every run. Expect to add several
  variants for one name; it converges.
- Do not add a rule from one uncertain sighting of a mistake. Wait until you see it twice, or
  ask.

## What the dictionary file is

`~/Library/Application Support/WhisperingFlow/vocabulary.json` — a JSON array of objects:
`id` (UUID), `spoken`, `replacement`, `isEnabled`, `isBuiltIn`, `note`. **Only edit it while
the app is quit**, or use `add-rule.py`. A corrupt file is moved aside (`.corrupt-<time>`), never
silently wiped.

## What cannot be fixed with a rule

- A word the engine never produced anything close to. Say it slower, or spell out the name.
- Grammar the engine got wrong. That is what **Smart** mode (menu-bar → Mode) polishes.
- Language mixing inside one sentence. **Automatic** (menu-bar → Language) handles switches between
  sentences and phrases; a single foreign word inside a sentence stays in the sentence's language.

## Growing the shared starter dictionary (optional, developers)

The starter dictionary is generated from `Scripts/vocab/terms.txt`. Add a term, then run
`python3 Scripts/vocab/harvest.py all`: it speaks the term with several synthetic voices, asks
the real recogniser what it wrote, and keeps only safe, repeated mistakes. See
`Scripts/vocab/README.md`. Contribute rules, never transcripts.

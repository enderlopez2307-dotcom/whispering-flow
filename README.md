# Whispering Flow

Local-first dictation for macOS. **Hold Right Command, speak, let go, and your words are typed
at the cursor** — in any app. English and Spanish. Everything runs on your Mac: no account, no
cloud, no telemetry, no subscription, no paid API.

It is built to be installed by **your own AI agent**. Give it this repository and one sentence:

> Clone this repository and follow `AGENT_INSTALL.md` to install Whispering Flow on my Mac.

## What it does

- **Hold to talk, or double-tap to keep talking.** Hold Right Command while you speak. Or
  double-tap it to go hands-free, tap once to finish, Escape to cancel.
- **A live waveform** appears next to your text cursor while it listens, so you always know the
  microphone is open. In hands-free mode it also tells you how to stop, and turns orange to
  count down the last 15 seconds before a long session ends by itself (just under 5 minutes).
- **English and Spanish**, switched from the menu bar.
- **Two modes.** *Fast* inserts the text about a tenth of a second after you let go and never
  runs a language model. It still removes "um"/"uh" and stumbles like "the the" or "my, my".
  *Smart* adds Apple's on-device model to tidy the result (false starts, run-on sentences). It
  takes a second or more, and it is *more polished*, not *more accurate*: if the model drops a
  number, adds a currency sign, softens a swear word or deletes a name, its version is thrown
  away and you get the Fast text instead.
- **A starter dictionary** of about 170 corrections for product and developer names
  (Supabase, Cloudflare, ChatGPT, GitHub, Claude Code…), so common names come out right from
  the first day.
- **Question marks** are added to sentences that are plainly questions.
- **Safe by design.** It never types into password fields, a browser's address bar, or a
  different app from the one you started in. Text is never lost: if insertion is refused you can
  copy the last transcript from the menu bar. It never presses Return for you.

## It gets better for *you*

There is no cloud model being trained on you, and this is not fine-tuning. Instead:

1. **Your personal dictionary.** Fix a mistake once (select the wrong text → menu bar →
   *Add Correction to Vocabulary…*) and it is fixed forever.
2. **An opt-in log, kept only on your Mac.** Turn on *Record transcripts for troubleshooting*
   and, after a few days, your agent reads it and proposes the corrections for *your* words and
   *your* pronunciation. See `AGENT_TUNING.md`.
3. **Starter dictionary growth.** New terms are added by speaking them to the real recogniser
   and keeping only safe, repeated mistakes (`Scripts/vocab/`).

## What it is not

- It does not clone or train on your voice.
- It cannot fix a word the speech engine got badly wrong, only ones it gets wrong the same way
  each time.
- Language switching is manual.
- Spanish speech with English product names is the weakest area: those names are spelled
  differently on each run, and the dictionary catches them one variant at a time.

## Requirements

macOS 26 or later, Apple Silicon, Xcode 26+ (or its command-line tools). No paid Apple developer
account: the app is signed with a certificate created on your own Mac.

## For people

Read `AGENT_INSTALL.md` (it is short and written in plain steps) or hand it to an agent. You
will be asked to click three privacy prompts (Microphone, Input Monitoring, Accessibility) —
that part is deliberately yours.

## Privacy

Audio is captured, transcribed and inserted entirely on your Mac. Apple's speech models are
downloaded once by macOS itself on first launch; after that recognition makes no network
requests (measured: zero open sockets across a full session). Dictated text is never written to
the system log. The optional diagnostic log is a plain file in
`~/Library/Application Support/WhisperingFlow/` that you can view or delete from the app.

## Before you install: what this is, honestly

This is a personal project, written by one person with AI assistance and shared because it
turned out to be useful. It is not a product and there is no company behind it. Please read
this part before you grant it anything.

**It asks for three of the most powerful permissions macOS has.** That is not a design choice,
it is what system-wide dictation requires — but you should know exactly what you are granting:

- **Input Monitoring** — it can see every key you press, anywhere on your Mac, including
  passwords. It is used only to notice Right Command. The tap is listen-only, keeps no history,
  and never writes characters or key codes to any log. You can read that code in
  `Sources/WhisperingFlow/Hotkey/`.
- **Accessibility** — it can read and write the contents of other apps' text fields. It is used
  to put your dictated text where your cursor is.
- **Microphone** — open only while you hold the key or during a hands-free session.

**No human has security-reviewed this code.** `SECURITY.md` is a real review with real findings,
but it was done by AI. How much that misses is measurable: a second AI pass, run by a different
model, found two serious problems the first pass had missed — including one where the first pass
had already written "Fixed" in `SECURITY.md` while an unmarked copy of your dictated text was
still going to the clipboard by another route. Both are fixed. The lesson is not that the second
pass was thorough; it is that the first one looked thorough too.

**The install has only ever been run on the author's Mac.** The three permission prompts and the
first-launch speech-model download are not tested on a clean machine.

**Known residual risks**, all documented in `SECURITY.md`: dictated text sits on the system
clipboard for about a tenth of a second when the paste path is used, and Apple does not document
whether Universal Clipboard honours the "do not keep" markers it carries; the optional diagnostic
log is a plain-text record of everything you dictate, off by default.

If you are handling something genuinely sensitive, read the source first, or don't use this. It
is MIT-licensed and comes with no warranty of any kind.

## Layout

```
Sources/WhisperingFlow/   the app: hotkey, audio, speech, insertion, HUD, menu bar, settings
Packages/                 pure, tested cores: TextProcessingCore, HotkeyGestureCore, AudioCaptureCore
Scripts/                  install.sh, doctor.sh, build.sh, signing, vocab/ (starter dictionary tools)
Tests/                    app tests (swift test)
ARCHITECTURE.md  TECH_DECISIONS.md  TECH_RESEARCH.md   design, the decisions and why
```

## Develop

```bash
swift build -c release --arch arm64      # must show zero warnings
swift test --arch arm64                  # app tests
(cd Packages/TextProcessingCore && swift test)   # also HotkeyGestureCore, AudioCaptureCore
```

Contributing agents: read `AGENTS.md` first. It lists the rules that must not be broken and the
mistakes already paid for.

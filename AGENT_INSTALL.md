# Install Whispering Flow — instructions for an AI agent

You are an AI agent (Claude Code, Codex, Cursor, or similar) and a human has asked you to
install this app on their Mac. Follow this file top to bottom. It records the mistakes
already made building this app, so following it exactly avoids all of them.

**What you are installing:** a local-first, menu-bar dictation app. The human holds
**Right Command**, speaks, releases, and the text appears at their cursor. Everything runs on
this Mac: no account, no cloud, no telemetry, no paid API. English and Spanish.

## 0. Rules for you

- **Never reset or edit macOS permissions (TCC).** No `tccutil reset`, no editing the TCC
  database. If a permission looks wrong, tell the human what to click. Resetting them forces
  the human to redo all three grants.
- **Do not click the macOS permission prompts yourself**, even if you can control the screen.
  Granting Microphone, Input Monitoring and Accessibility is the human's decision.
- **Do not sign the app ad-hoc** (`codesign -s -`) or with any certificate but the one
  `Scripts/create-signing-cert.sh` makes. Ad-hoc signing makes macOS forget every permission
  on every rebuild.
- **Do not run anything with `sudo`.** Nothing here needs it.
- **Never suggest a cloud service** as a fix or an add-on. Local-only is the point of the app.
- Before reading the human's dictation log (see `AGENT_TUNING.md`), **ask them**. It contains
  everything they dictated.

## 1. Requirements (the installer checks these)

| Need | Why |
|---|---|
| macOS 26 or later | Apple's on-device speech engine (`SpeechAnalyzer`) ships with macOS 26 |
| Apple Silicon (arm64) | The build targets arm64 only |
| Xcode 26 or later, or its Command Line Tools (Swift 6.2+) | The app is built from source on this Mac |
| A human at the keyboard for ~3 clicks | Keychain and privacy prompts cannot be answered by an agent |
| Internet, once | Apple downloads the English and Spanish speech models on first launch |
| *(optional)* Apple Intelligence turned on | Only for Smart mode. Fast mode never needs it |

If Swift is missing, tell the human to run `xcode-select --install` and click through the
dialog, then continue.

## 2. Install (one command)

```bash
git clone <this-repository-url> whispering-flow
cd whispering-flow
./Scripts/install.sh
```

`install.sh` is safe to re-run. It: checks the Mac, creates a local code-signing certificate
(once), builds the app, installs it to `~/Applications/WhisperingFlow.app`, checks the
signature is stable, registers the app with macOS privacy settings, and starts it. It prints
the human's remaining steps at the end. **Relay them to the human word for word.**

Expect the first build to take a few minutes. It prints progress.

### If it seems stuck

A macOS keychain dialog is almost always waiting for the human. One appears while the
certificate is created and another the first time `codesign` uses it ("codesign wants to use
the key" — the human should choose **Always Allow**). Tell the human to look for a dialog.
Do not try to work around it.

## 3. The human's steps (you cannot do these)

1. **Microphone** — click **Allow** in the prompt.
2. **Input Monitoring** — System Settings → Privacy & Security → Input Monitoring → turn
   **Whispering Flow** on.
3. **Accessibility** — System Settings → Privacy & Security → Accessibility → turn
   **Whispering Flow** on.
4. Then restart the app once so it picks the grants up: `./Scripts/install.sh --launch`.

macOS may offer a "Quit & Reopen" button after step 2 or 3; either way works.

## 4. Verify (do not skip; "it installed" proves nothing)

```bash
./Scripts/doctor.sh --relaunch
```

This restarts the app and prints what the app itself reports about permissions and the
keyboard hook. You want to see the keyboard tap start and no `[FIX]` lines. Then ask the
human to do this live test, and wait for their answer:

1. Click into TextEdit (or Notes).
2. **Hold Right Command**, say "hello world, this is a test", release.
3. The text should appear within about a second and a small waveform pill should have shown
   under their cursor while they spoke.
4. **Double-tap Right Command**, speak for a few seconds, **tap once** to finish. Escape
   cancels instead.

Only report success when the human confirms the text appeared.

## 5. What they get, so you can explain it

- **Hold Right Command** to talk, release to insert. **Double-tap** to keep talking hands-free;
  tap once to finish; Escape cancels. A hands-free session ends by itself after 5 minutes.
- **Menu-bar icon → Language:** English or Spanish. It is a manual switch, not automatic.
- **Menu-bar icon → Mode:**
  - **Fast** — vocabulary and rule-based cleanup only. About 0.1 s after release. Never runs
    a model. Best if speed matters most.
  - **Smart** — adds Apple's on-device model for a more polished result (fixes repeated
    words, run-ons). It takes longer (around 1 to 5 s depending on length) and can rephrase.
    It is "more polished", not "more accurate". Needs Apple Intelligence; if it is
    unavailable the app falls back to Fast and shows a warning icon.
- **Starter vocabulary:** about 170 pre-made corrections for common product and developer
  names (Supabase, Cloudflare, ChatGPT, GitHub…), so it is accurate on those from day one.
- **Question marks:** sentences that are plainly questions get a "?" even when Apple's engine
  wrote a period.
- **It gets better for this person over time.** See `AGENT_TUNING.md`. This is *not* model
  training: it learns by adding text corrections to the person's own dictionary.
- **Never inserted:** into password fields, into a browser's address bar, or into a different
  app than the one they were in when they started. If something is refused, the text is not
  lost: menu-bar icon → **Copy Last Transcript**.

## 6. Known problems and their fixes (each one cost time already)

| Symptom | Cause | Fix |
|---|---|---|
| Hotkey does nothing | Input Monitoring not granted, or app not restarted after granting | Grant it, then `./Scripts/install.sh --launch`. `./Scripts/doctor.sh --relaunch` shows if the tap started |
| Menu says "Secure input is active" | Another app (Terminal with *Secure Keyboard Entry*, a password prompt) is holding secure input; no app can see any hotkey while it does | Turn off Terminal → Secure Keyboard Entry, or close the password dialog. It resumes by itself |
| Text transcribed but nothing appears | Accessibility not granted | Grant it and restart the app |
| Text refused in Chrome/Safari | The cursor was in the **address bar**. A new tab focuses it by default, so this is on purpose | Click into the page first, or use Copy Last Transcript |
| Permissions were lost after a rebuild | The app was signed ad-hoc | Run `./Scripts/install.sh`; `codesign -d -r- ~/Applications/WhisperingFlow.app` must show a certificate, never `cdhash` |
| `build.sh` or `install.sh` hangs | A keychain dialog is waiting for the human | Ask them to look for it and choose Always Allow |
| The app silently is not running after a restart | It has failed to launch before without saying so | `pgrep -lf WhisperingFlow.app`; run `~/Applications/WhisperingFlow.app/Contents/MacOS/WhisperingFlow` in a terminal to see the error |
| Right Option types `ó` / `ñ` instead of dictating | Right Option is how Spanish accents are typed | Keep the default, Right Command |
| F-key hotkeys (F6–F9) do nothing | macOS turns them into brightness/volume keys | System Settings → Keyboard → turn on "Use F1, F2, etc. keys as standard function keys" |
| `swift test` fails on `InsertionTests` | Those tests read the real focused element on screen, so they depend on what has focus | Close other windows, leave the keyboard alone, rerun before assuming a regression |
| Edited `vocabulary.json` and the change vanished | The running app overwrites that file when it saves | Quit the app first, or use `Scripts/vocab/add-rule.py` |
| Spanish product names come out spelled differently each time | The engine re-spells English names in Spanish speech | Add the variants with `add-rule.py`; see `AGENT_TUNING.md` |
| Smart mode never seems to run | Apple Intelligence is off or the model is unavailable | Turn on Apple Intelligence, or stay on Fast |

## 7. Update or uninstall

**Update:** `git pull` then `./Scripts/install.sh`. Permissions and the dictionary are kept
because the signing identity and data folder do not change.

**Uninstall:**

```bash
pkill -f WhisperingFlow.app
rm -rf ~/Applications/WhisperingFlow.app
rm -rf "$HOME/Library/Application Support/WhisperingFlow"     # dictionary + diagnostic log
```

Then ask the human to remove **Whispering Flow** from Login Items, Microphone, Input
Monitoring and Accessibility in System Settings (macOS does not let scripts do that), and
optionally delete the certificate named "Whispering Flow Local Signing" in Keychain Access.

## 8. When you report back

Tell the human plainly: what was installed and where, which steps they did, what the live test
showed, and anything that did not work. If something failed, say so with the output. Do not
describe it as working until they have seen text appear.

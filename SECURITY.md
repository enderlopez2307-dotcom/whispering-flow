# Security and code review

Reviewed 21 September 2026, before publication, at the request of the author: *"make sure I
don't get hacked."* Read this before you install, and re-run the checks at the bottom yourself.

**Limits of this review. Read this before you trust the table below.** No human has reviewed
this code. Two AI passes were run: the first by the model that had helped write the code, the
second by a different model in a fresh session, specifically to check the first.

The second pass found two serious problems the first had missed — including S6, where the first
pass had already published "**Fixed**" for S1 while a second code path was still putting your
dictated text on the clipboard unmarked. That path is the one used *because* insertion was
refused, so the most sensitive transcripts were the ones going out unprotected.

So this is a measurement, not a reassurance: a review that looked complete was not, and the only
reason anyone found out was that a second reviewer went looking. Neither pass is a penetration
test, nothing was fuzzed, and Apple's frameworks were not audited. Get an independent human
review before relying on this for anything sensitive.

## What the app can do (its attack surface)

| Capability | Why | How it is contained |
|---|---|---|
| Sees every key press, system-wide (a `CGEventTap`) | To notice Right Command | **Listen-only**: it never blocks or alters an event. It keeps no key history and logs modifier *names* only, never characters or key codes |
| Reads and writes other apps' text fields (Accessibility) | To insert dictated text | Refuses password fields, browser address bars and any app other than the one you started in; inserts with `AXSelectedText`, never by rewriting a whole field |
| Uses the clipboard and posts ⌘V | Fallback insertion | Saves and restores your clipboard; marks dictated text *transient / concealed* so clipboard managers skip it |
| Microphone | Dictation | Open only while you hold the key or during a hands-free session (which ends by itself after 285 s, with a visible 15 s countdown). Not open while idle |
| Local files | Dictionary, opt-in log | `~/Library/Application Support/WhisperingFlow/`. The transcript log is **off by default**, mode `0600`, capped at about 4 MB per file, and deletable from Settings |
| On-device language model (Smart mode) | Tidying | Apple's local model, no tools, no network. Output is rejected if it grows or shrinks the text too much, refuses, returns code fences, drops a number, adds a currency symbol, removes a swear word, or deletes a mid-sentence capitalised word |
| Network | none | No network code in the source. macOS itself downloads Apple's speech models once |
| Dependencies | none | No third-party packages. Only Apple frameworks and this repository's own packages |

Signing and privileges: hardened runtime, **not sandboxed** (an event tap and Accessibility
cannot be sandboxed), and the only entitlement is microphone access. The certificate is created
on your Mac by `Scripts/create-signing-cert.sh`, its private key is usable only by `codesign`, and
nothing in this repository contains a key, certificate or hash. The scripts need no `sudo` and
never touch macOS privacy (TCC) settings.

## Findings

| # | Severity | Finding | Status |
|---|---|---|---|
| S1 | Medium | Dictated text was written to the system clipboard without the "do not keep" markers, so a clipboard manager could record it. That undercuts "nothing leaves your Mac" | **Fixed.** Both writers — the paste inserter and "Copy last transcript" — use the `org.nspasteboard` transient/concealed markers. *Residual:* Apple does not document Universal Clipboard honouring them; the paste path leaves the text up for about 120 ms, and a copied transcript stays until something replaces it |
| S2 | Low | Accessibility calls on the main thread had no timeout, so a hung target app could freeze this app (and its hotkey) for several seconds | **Fixed.** 0.5 s bound |
| S3 | Low | Finding which app holds "secure input" ran `ioreg -l` synchronously on the main thread, stalling the hotkey | **Fixed.** Runs in the background |
| S4 | Low | The opt-in transcript log grew without limit: a plaintext record of everything dictated, forever, if left on | **Fixed.** Rolls at about 4 MB, keeps two files, `0600`, Delete removes both |
| S5 | Low | The hands-free time limit equalled the audio buffer's ceiling, so the last words could be clipped | **Fixed.** Limit is 285 s against a 300 s buffer |
| C1 | Low | A zero-length WAV `data` chunk would crash the developer-only corpus reader | **Fixed** |
| S6 | Medium | The first fix for S1 reached only the paste inserter. "Copy last transcript" still wrote a bare string, and that path is used *because* insertion was refused — so the most sensitive transcripts were the ones going to the clipboard unmarked, and staying there | **Fixed.** One shared writer, covered by a test that fails if either path loses the markers |
| S7 | Medium | The export script's leak scan filtered out whole lines containing the substituted `/Users/you` placeholder, so any name, address or product term sharing a line with a home path was silently dropped from the report and the export declared itself clean | **Fixed.** Identifiers are scanned with no filter at all; the placeholder allowance applies only to the separate home-path scan |
| S8 | Medium | Nothing checked non-text files in the export: the identifier substitution skips them and `grep -I` will not look inside them, so a stray screenshot or voice memo would have exported "clean" | **Fixed.** The export now refuses any file that is not text, and lists untracked files it is about to include |
| S9 | Medium | Changing the hotkey or the hands-free setting while dictating reset the gesture without telling the rest of the app: the session stayed "listening" with the microphone open, the safety timer cancelled, and no gesture able to end it | **Fixed.** One shared teardown path, used by rebinding, stopping and tap-disabled recovery alike. Regression-tested |
| S10 | Low | When Smart mode's result was rejected, the reason logged to the system log named the dropped number or word, so fragments of dictated text could appear in `log stream` output while it was being watched (not saved to disk) | **Fixed** the same day (26 Sept 2026). Reasons are fixed categories; a test asserts none quotes the input |
| I1 | Info | The certificate script passes a random one-time password to `security import` on the command line for a moment; other processes of the same user could see it | Accepted. `security import` has no other way; same user only |
| I2 | Info | Clipboard save/restore copies every clipboard type into memory; a huge copied image makes insertion slow | Accepted |
| I3 | Info | Developer flags: `--debug-audio-export` writes voice clips to the temp folder, `--debug-transcripts` logs text to the file. Both are off unless passed | Accepted, documented |
| I4 | Info | Smart mode feeds spoken (untrusted) text to a local model, so spoken or overheard words could steer its wording | Accepted. No tools, output bounded, and the app never presses Return, so you see the text before anything is sent |
| I5 | Info | Some `@unchecked Sendable` boxes and `MainActor.assumeIsolated` remain | Each is documented and confined to a run-loop or main-queue callback. A misuse here has crashed the app twice before and is called out in `AGENTS.md` |

S6–S9 come from a second review, run in a fresh session by a different model against the same
branch, precisely because S1–S5 had been found by the model that wrote the code. Each was
reproduced before it was fixed. An independent human pass is still worth doing.

Code-quality scans found: no `try!` outside constant regexes, force casts only after a
`CFGetTypeID` check, no unsafe pointer use outside audio buffers, no TODO/FIXME left, and no use
of private APIs beyond one undocumented registry key read for a diagnostic message.

## Test evidence

All suites pass (app, gesture, audio, text: 329 tests as of 26 Sept 2026), the release build
has zero warnings, and the safety rules above are held by tests (for example: the dictionary must
not change ordinary sentences, the clipboard markers must be present, the log must roll over).

## Check it yourself

```bash
# No network code:
grep -rnE "URLSession|NWConnection|URL\(string: \"https?" Sources Packages/*/Sources
# What it is entitled to (should list only audio-input / microphone):
codesign -d --entitlements - ~/Applications/WhisperingFlow.app
# It is signed with a certificate, not ad-hoc (must not contain 'cdhash'):
codesign -d -r- ~/Applications/WhisperingFlow.app
# Watch its network use while you dictate (expect nothing):
lsof -i -a -p "$(pgrep -f WhisperingFlow.app/Contents/MacOS)"
```

## Reporting a problem

Open an issue describing what you saw. Do **not** include dictated text or your log file.

#!/usr/bin/env python3
"""Look through your own dictation log for words the recogniser probably got wrong.

    python3 Scripts/vocab/suggest.py            # most frequent unknown words
    python3 Scripts/vocab/suggest.py --min 2

Needs Settings > Diagnostics > "Record transcripts for troubleshooting" ON for a
few days first. Everything stays on this Mac: it only reads the local log file and
prints to your terminal.

It lists words that neither English nor Spanish spell-checking recognises, with a
snippet of context. That is a HINT list, not an answer: brand names are unknown to
a dictionary on purpose, and so are mishearings. A human or agent decides which
ones are mistakes and what they should have been, then adds them with
add-rule.py. Never add a rule for an ordinary word.
"""
import argparse, collections, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SUPPORT = os.path.expanduser("~/Library/Application Support/WhisperingFlow")
LOG = os.path.join(SUPPORT, "whispering-flow-transcripts.log")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min", type=int, default=1, help="only words seen at least this many times")
    ap.add_argument("--top", type=int, default=40)
    args = ap.parse_args()
    if not os.path.exists(LOG):
        sys.exit("No log yet. Turn on Settings > Diagnostics > Record transcripts, dictate for a "
                 "few days, then run this again.")

    # The ENGINE line, not the final one. A dictionary rule is matched against
    # what the recogniser wrote, before cleanup and before Smart mode rewrites
    # it — so a word harvested from the final line may not exist in the engine
    # output at all, and a rule added for it would never fire.
    engine_lines, final_lines = [], []
    for line in open(LOG, encoding="utf-8", errors="ignore"):
        m = re.match(r"\s+engine\s+: (.*)", line)
        if m:
            engine_lines.append(m.group(1))
            continue
        m = re.match(r"\s+final\s+: (.*)", line)
        if m:
            final_lines.append(m.group(1))
    read_from = "engine output"
    if not engine_lines:
        # Older logs, written before per-stage tracing, only have a final line.
        engine_lines, read_from = final_lines, "final text (no engine lines in this log)"
    counts, contexts = collections.Counter(), {}
    for text in engine_lines:
        for m in re.finditer(r"[A-Za-zÁÉÍÓÚÜÑáéíóúüñ][A-Za-zÁÉÍÓÚÜÑáéíóúüñ'’-]{2,}", text):
            w = m.group(0).strip("'’-").lower()
            counts[w] += 1
            contexts.setdefault(w, text[max(0, m.start() - 30): m.end() + 30].replace("\n", " "))

    binary = os.path.join(SUPPORT, ".wordcheck")
    if not os.path.exists(binary):
        subprocess.run(["swiftc", "-O", "-o", binary, os.path.join(HERE, "wordcheck.swift")], check=True)
    out = subprocess.run([binary], input="\n".join(counts) + "\n", text=True,
                         capture_output=True, check=True).stdout
    unknown = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        w, en, es = parts
        if en == "0" and es == "0" and counts.get(w, 0) >= args.min:
            unknown.append((counts[w], w))
    unknown.sort(reverse=True)
    print(f"{len(engine_lines)} dictations read from the {read_from}. Words neither English "
          f"nor Spanish knows (likely brand names or mishearings):\n")
    for n, w in unknown[: args.top]:
        print(f"{n:4d}  {w:<22} ...{contexts[w]}...")
    if not unknown:
        print("Nothing suspicious found.")


if __name__ == "__main__":
    main()

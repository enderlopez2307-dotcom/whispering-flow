#!/usr/bin/env python3
"""Add correction rules to your Whispering Flow dictionary, safely.

    python3 Scripts/vocab/add-rule.py "clock code" "Claude Code"
    python3 Scripts/vocab/add-rule.py --restart "su pae" "Supabase" "cloud flare" "Cloudflare"

Arguments come in pairs: what the recogniser WROTE, then what you MEANT.

The app keeps the dictionary in memory and overwrites the file when it saves, so
this refuses to touch the file while the app is running (--restart quits it,
edits, and starts it again). A backup is written first. Rules are refused when
they would rewrite an ordinary word ("claw", "notion") because they would also
fire when you really say that word; pass --allow-common-word only if the person
this dictionary belongs to has asked for exactly that.
"""
import argparse, json, os, shutil, subprocess, sys, time, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
SUPPORT = os.path.expanduser("~/Library/Application Support/WhisperingFlow")
FILE = os.path.join(SUPPORT, "vocabulary.json")
APP_PATTERN = "WhisperingFlow.app/Contents/MacOS"


def running():
    return subprocess.run(["pgrep", "-f", APP_PATTERN], capture_output=True).returncode == 0


def running_app_bundle():
    """The .app the running process came from, so --restart reopens THAT copy,
    wherever it was installed (not just ~/Applications)."""
    out = subprocess.run(["ps", "-axo", "command"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        marker = ".app/Contents/MacOS/WhisperingFlow"
        if marker in line:
            return line[: line.index(marker) + len(".app")].strip()
    return None


def is_ordinary(tokens):
    """(en_valid, es_valid) per token via the macOS spell checker."""
    binary = os.path.join(SUPPORT, ".wordcheck")
    if not os.path.exists(binary):
        subprocess.run(["swiftc", "-O", "-o", binary, os.path.join(HERE, "wordcheck.swift")], check=True)
    out = subprocess.run([binary], input="\n".join(tokens) + "\n", text=True,
                         capture_output=True, check=True).stdout
    result = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            result[parts[0]] = parts[1] == "1" or parts[2] == "1"
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pairs", nargs="+", help="spoken replacement [spoken replacement ...]")
    ap.add_argument("--restart", action="store_true", help="quit the app first and start it again after")
    ap.add_argument("--allow-common-word", action="store_true")
    ap.add_argument("--note", default="Added with add-rule.py.")
    args = ap.parse_args()
    if len(args.pairs) % 2:
        sys.exit("Give rules in pairs: <what it wrote> <what you meant>")

    was_running = running()
    bundle = running_app_bundle() if was_running else None
    if was_running and not args.restart:
        sys.exit("Whispering Flow is running and would overwrite this change. Quit it first, "
                 "or add --restart to have this script quit and reopen it.")
    if was_running:
        # Wait for it to actually go. A fixed sleep was not enough: if the app
        # was still alive (mid-transcription, say) the write below would be
        # overwritten the next time it saved its in-memory rules, and `open`
        # on an already-running app is a no-op, so the "Restarted" line lied.
        subprocess.run(["pkill", "-f", APP_PATTERN])
        for _ in range(40):
            if not running():
                break
            time.sleep(0.25)
        else:
            sys.exit("Whispering Flow is still running 10 s after being asked to quit. Nothing "
                     "was changed. Quit it yourself, then run this again.")
        time.sleep(0.3)   # let its last atomic write land before we read

    rules = []
    if os.path.exists(FILE):
        rules = json.load(open(FILE, encoding="utf-8"))
        shutil.copy(FILE, FILE + f".backup-{int(time.time())}")
    known = {r["spoken"].lower(): r for r in rules}

    wanted = list(zip(args.pairs[0::2], args.pairs[1::2]))
    singles = [s.lower() for s, _ in wanted if " " not in s.strip()]
    ordinary = is_ordinary(singles) if singles else {}

    added = 0
    for spoken, replacement in wanted:
        spoken, replacement = spoken.strip(), replacement.strip()
        if not spoken or not replacement or spoken == replacement:
            print(f"skip   {spoken!r}: empty or identical to its replacement"); continue
        if " " not in spoken and ordinary.get(spoken.lower()) and not args.allow_common_word:
            print(f"REFUSE {spoken!r}: it is an ordinary word, so this rule would also rewrite "
                  f"every time it is said on purpose. Use a longer, distinctive phrase.")
            continue
        existing = known.get(spoken.lower())
        if existing:
            existing["replacement"], existing["isEnabled"] = replacement, True
            print(f"update {spoken!r} -> {replacement!r}")
        else:
            rule = {"id": str(uuid.uuid4()).upper(), "spoken": spoken, "replacement": replacement,
                    "isEnabled": True, "isBuiltIn": False, "note": args.note}
            rules.append(rule); known[spoken.lower()] = rule
            print(f"add    {spoken!r} -> {replacement!r}")
        added += 1

    os.makedirs(SUPPORT, exist_ok=True)
    tmp = FILE + ".tmp"
    json.dump(rules, open(tmp, "w", encoding="utf-8"), indent=2, sort_keys=True, ensure_ascii=False)
    os.replace(tmp, FILE)
    print(f"{added} change(s); dictionary now has {len(rules)} rules.")
    if was_running:
        target = bundle or os.path.expanduser("~/Applications/WhisperingFlow.app")
        if subprocess.run(["open", target]).returncode == 0:
            print("Restarted Whispering Flow.")
        else:
            print(f"Could not reopen {target}. The rules are saved; start the app yourself.")
    elif added:
        print("Start Whispering Flow to use them (open ~/Applications/WhisperingFlow.app).")


if __name__ == "__main__":
    main()

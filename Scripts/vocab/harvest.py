#!/usr/bin/env python3
"""Harvest a starter vocabulary from the real recogniser.

Speak each term in terms.txt with several synthetic voices, ask the app's own
speech engine what it wrote (`--transcribe-dir`), and turn the recurring
mistakes into dictionary rules. Everything runs on this Mac: `say` for the
voices, the app binary for recognition, macOS's spell checker for safety. No
network, no accounts.

    python3 Scripts/vocab/harvest.py synth       # make the audio
    python3 Scripts/vocab/harvest.py transcribe  # run the recogniser
    python3 Scripts/vocab/harvest.py analyze     # candidates.json + report
    python3 Scripts/vocab/harvest.py emit        # write StarterVocabulary.swift
    python3 Scripts/vocab/harvest.py all

Synthetic voices are only INDICATIVE (TECH_RESEARCH 15.4): they find the
systematic mistakes, not every mistake real speech will produce. A rule only
survives if several voices agree on it AND it passes the safety filters below.
"""
import argparse, collections, concurrent.futures as cf, json, math, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

EN_VOICES = ["Samantha", "Daniel", "Karen", "Moira", "Rishi", "Tessa", "Tara", "Aman",
             "Flo (English (US))"]
ES_VOICES = ["Mónica", "Eddy (Spanish (Spain))", "Sandy (Spanish (Spain))", "Paulina"]
EN_TEMPLATES = [
    "I need to open {T} and check the settings.",
    "Can you tell me how {T} works with our project?",
    "We decided to use {T} for the next release.",
]
ES_TEMPLATES = [
    "Necesito abrir {T} y revisar la configuración.",
    "Decidimos usar {T} para la próxima versión.",
]

MIN_CLIPS = 2       # a variant must be heard this many times ...
MIN_VOICES = 2      # ... from at least this many different voices


def read_terms():
    terms = []
    for line in open(os.path.join(HERE, "terms.txt"), encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#"):
            terms.append(line)
    return terms


def work_dir(args):
    path = os.path.abspath(args.work)
    os.makedirs(path, exist_ok=True)
    return path


# ---------------------------------------------------------------- synth

def build_manifest(terms):
    manifest, n = [], 0
    for term in terms:
        for locale, voices, templates in (("en-US", EN_VOICES, EN_TEMPLATES),
                                          ("es-ES", ES_VOICES, ES_TEMPLATES)):
            for ti, template in enumerate(templates):
                for voice in voices:
                    n += 1
                    manifest.append({"n": n, "term": term, "locale": locale, "voice": voice,
                                     "template": ti, "text": template.replace("{T}", term)})
    return manifest


def synth_one(work, item):
    path = os.path.join(work, "audio", f"{item['n']:05d}__{item['locale']}.wav")
    if os.path.exists(path) and os.path.getsize(path) > 1000:
        return True
    r = subprocess.run(["say", "-v", item["voice"], "--file-format=WAVE",
                        "--data-format=LEI16@16000", "-o", path, item["text"]],
                       capture_output=True)
    return r.returncode == 0


def stage_synth(args):
    work = work_dir(args)
    os.makedirs(os.path.join(work, "audio"), exist_ok=True)
    manifest = build_manifest(read_terms())
    with open(os.path.join(work, "manifest.jsonl"), "w", encoding="utf-8") as f:
        for item in manifest:
            f.write(json.dumps(item, ensure_ascii=False) + "\n")
    ok = 0
    with cf.ThreadPoolExecutor(max_workers=6) as pool:
        for i, good in enumerate(pool.map(lambda it: synth_one(work, it), manifest), 1):
            ok += good
            if i % 500 == 0:
                print(f"  synthesised {i}/{len(manifest)}", flush=True)
    print(f"synth: {ok}/{len(manifest)} clips in {work}/audio")


# ---------------------------------------------------------- transcribe

def find_binary(args):
    for candidate in (args.binary,
                      os.path.join(ROOT, "build", "WhisperingFlow.app", "Contents", "MacOS", "WhisperingFlow"),
                      os.path.join(ROOT, ".build", "release", "WhisperingFlow")):
        if candidate and os.path.exists(candidate):
            return candidate
    sys.exit("No built app found. Run ./Scripts/build.sh first, or pass --binary.")


def stage_transcribe(args):
    work = work_dir(args)
    binary = find_binary(args)
    results = os.path.join(work, "results.jsonl")
    done = set()
    if os.path.exists(results):
        for line in open(results, encoding="utf-8"):
            try:
                done.add(json.loads(line)["file"])
            except Exception:
                pass
    files = sorted(f for f in os.listdir(os.path.join(work, "audio")) if f.endswith(".wav"))
    todo = [f for f in files if f not in done]
    print(f"transcribe: {len(todo)} to do, {len(done)} already done")
    shards = 4
    procs = []
    for s in range(shards):
        shard = os.path.join(work, f"shard{s}")
        if os.path.isdir(shard):
            for f in os.listdir(shard):
                os.remove(os.path.join(shard, f))
        os.makedirs(shard, exist_ok=True)
        for f in todo[s::shards]:
            os.symlink(os.path.join(work, "audio", f), os.path.join(shard, f))
        out = open(os.path.join(work, f"out{s}.jsonl"), "w", encoding="utf-8")
        procs.append((subprocess.Popen([binary, "--transcribe-dir", shard], stdout=out,
                                       stderr=subprocess.DEVNULL), out))
    for p, out in procs:
        p.wait()
        out.close()
    with open(results, "a", encoding="utf-8") as f:
        for s in range(shards):
            for line in open(os.path.join(work, f"out{s}.jsonl"), encoding="utf-8"):
                if line.strip().startswith("{"):
                    f.write(line if line.endswith("\n") else line + "\n")
    print("transcribe: done")


# ------------------------------------------------------------- analyze

def word_lists(work):
    """Lower-case English words from the system list (proper nouns excluded)."""
    words = set()
    try:
        for w in open("/usr/share/dict/words", encoding="utf-8", errors="ignore"):
            w = w.strip()
            if w and w == w.lower():
                words.add(w)
    except OSError:
        pass
    return words


def spellcheck(work, tokens):
    """{token: (valid_en, valid_es)} via NSSpellChecker."""
    binary = os.path.join(work, "wordcheck")
    if not os.path.exists(binary):
        subprocess.run(["swiftc", "-O", "-o", binary, os.path.join(HERE, "wordcheck.swift")],
                       check=True)
    out = subprocess.run([binary], input="\n".join(sorted(tokens)) + "\n", text=True,
                         capture_output=True, check=True).stdout
    table = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            table[parts[0]] = (parts[1] == "1", parts[2] == "1")
    return table


def levenshtein(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def extract(template, transcript):
    """The words the engine wrote where {T} was spoken, or None if the carrier
    sentence itself was not recognised (then the clip proves nothing)."""
    prefix, suffix = template.split("{T}")
    def flex(text):
        words = re.findall(r"[\w']+", text.lower())
        return r"\W+".join(re.escape(w) for w in words)
    pattern = r"^\W*" + flex(prefix) + r"\W+(.+?)\W*" + flex(suffix) + r"\W*$"
    m = re.match(pattern, transcript.lower(), re.S)
    if not m:
        return None
    return transcript[m.start(1):m.end(1)]


def norm_spoken(text):
    text = text.strip(" ,.;:!?¿¡\"'“”‘’()")
    text = re.sub(r"[.\-]", " ", text) if not re.search(r"\d", text) else text
    return re.sub(r"\s+", " ", text).strip().lower()


def load_review():
    path = os.path.join(HERE, "review.json")
    if os.path.exists(path):
        return json.load(open(path, encoding="utf-8"))
    return {"deny": [], "notes": {}}


def stage_analyze(args):
    work = work_dir(args)
    manifest = {}
    for line in open(os.path.join(work, "manifest.jsonl"), encoding="utf-8"):
        item = json.loads(line)
        manifest[f"{item['n']:05d}__{item['locale']}.wav"] = item
    results = [json.loads(l) for l in open(os.path.join(work, "results.jsonl"), encoding="utf-8")
               if l.strip().startswith("{")]

    templates = {"en-US": EN_TEMPLATES, "es-ES": ES_TEMPLATES}
    stats = collections.defaultdict(lambda: {"clips": 0, "ok": 0, "unparsed": 0})
    variants = collections.defaultdict(lambda: {"count": 0, "voices": set(), "locales": set()})
    casing_seen = collections.Counter()      # how often the engine wrote a term in the wrong case
    for r in results:
        item = manifest.get(r.get("file"))
        if not item or "text" not in r:
            continue
        term = item["term"]
        s = stats[(term, item["locale"])]
        s["clips"] += 1
        got = extract(templates[item["locale"]][item["template"]], r["text"])
        if got is None:
            s["unparsed"] += 1
            continue
        got_clean = got.strip(" ,.;:!?¿¡\"'“”‘’()")
        if got_clean == term:
            s["ok"] += 1
            continue
        spoken = norm_spoken(got_clean)
        if not spoken or spoken == term.lower() and got_clean != term:
            spoken = term.lower()      # casing-only mistake
            casing_seen[term] += 1
        v = variants[(spoken, term)]
        v["count"] += 1
        v["voices"].add(item["voice"])
        v["locales"].add(item["locale"])

    review = load_review()
    deny = set(review.get("deny", []))
    dictionary = word_lists(work)

    # Tokens to spell-check: every token of every surviving spoken form.
    tokens = set()
    for (spoken, term) in variants:
        tokens.update(spoken.split())
    for term in read_terms():
        tokens.update(term.lower().split())
    check = spellcheck(work, tokens)

    def is_ordinary(token):
        en, es = check.get(token, (False, False))
        return token in dictionary or en or es

    candidates, dropped = [], collections.Counter()
    for (spoken, term), v in sorted(variants.items()):
        if spoken == term.lower():
            continue                         # casing handled separately
        if v["count"] < MIN_CLIPS or len(v["voices"]) < MIN_VOICES:
            dropped["too_rare"] += 1
            continue
        if spoken in deny:
            dropped["denied_in_review"] += 1
            continue
        tokens_ = spoken.split()
        # A comma or apostrophe means the engine broke the phrase up ("hey, jen");
        # a leading single letter would also match inside "let's lint" and the like.
        if re.search(r"[,'’]", spoken) or len(tokens_[0]) == 1 and len(tokens_) > 1 \
                and not all(len(t) == 1 for t in tokens_):
            dropped["fragile_form"] += 1
            continue
        joined_spoken = spoken.replace(" ", "")
        joined_term = re.sub(r"[^a-z0-9]", "", term.lower())
        distance = levenshtein(joined_spoken, joined_term)
        if distance > math.ceil(0.4 * len(joined_term)):
            dropped["not_close_to_term"] += 1
            continue
        if len(tokens_) == 1 and is_ordinary(tokens_[0]):
            dropped["single_ordinary_word"] += 1
            continue
        if len(joined_spoken) < 4:
            dropped["too_short"] += 1
            continue
        all_words = all(is_ordinary(t) for t in tokens_)
        candidates.append({"spoken": spoken, "replacement": term, "count": v["count"],
                           "voices": len(v["voices"]), "locales": sorted(v["locales"]),
                           "distance": distance,
                           "review": "all-ordinary-words" if all_words else ""})

    # A spoken form pointing at two different terms is ambiguous: drop unless
    # one clearly dominates.
    by_spoken = collections.defaultdict(list)
    for c in candidates:
        by_spoken[c["spoken"]].append(c)
    final = []
    for spoken, group in by_spoken.items():
        group.sort(key=lambda c: -c["count"])
        if len(group) > 1 and group[0]["count"] < 3 * group[1]["count"]:
            dropped["ambiguous"] += len(group)
            continue
        final.append(group[0])
    # A term's own lower-case spelling must never be rewritten to another term.
    lowers = {t.lower() for t in read_terms()}
    final = [c for c in final if c["spoken"] not in lowers]

    casing = []
    def acronym(term):
        return bool(re.fullmatch(r"[A-Z0-9]{2,}", term))
    def ordinary_token(token, term):
        en, es = check.get(token, (False, False))
        # macOS's dictionary accepts many acronyms ("api"), so for those only the
        # system word list and Spanish count as "ordinary".
        return token in dictionary or es or (en and not acronym(term))
    for term in read_terms():
        lower = term.lower()
        if lower == term:
            continue
        if casing_seen[term] < 1:
            dropped["casing_never_seen_wrong"] += 1        # the engine already gets it right
            continue
        if lower in review.get("deny_casing", []):
            dropped["casing_denied_in_review"] += 1
            continue
        toks = lower.split()
        if all(ordinary_token(t, term) for t in toks):
            dropped["casing_ordinary_word_or_phrase"] += 1
            continue
        casing.append({"spoken": lower, "replacement": term, "seen": casing_seen[term]})

    per_term = []
    for (term, locale), s in sorted(stats.items()):
        per_term.append({"term": term, "locale": locale, **s})
    out = {"candidates": sorted(final, key=lambda c: (c["replacement"], -c["count"])),
           "casing": casing, "dropped": dict(dropped), "per_term": per_term}
    json.dump(out, open(os.path.join(work, "candidates.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)

    total = sum(s["clips"] for s in stats.values())
    ok = sum(s["ok"] for s in stats.values())
    unparsed = sum(s["unparsed"] for s in stats.values())
    print(f"clips analysed: {total}  term written exactly right: {ok}  carrier not recognised: {unparsed}")
    print(f"candidate rules: {len(final)}  casing-only rules: {len(casing)}")
    print("dropped:", dict(dropped))
    flagged = [c for c in final if c["review"]]
    print(f"{len(flagged)} candidates made only of ordinary words: review them by eye "
          f"(add bad ones to Scripts/vocab/review.json deny list).")


# ---------------------------------------------------------------- emit

def swift_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def stage_emit(args):
    work = work_dir(args)
    data = json.load(open(os.path.join(work, "candidates.json"), encoding="utf-8"))
    review = load_review()
    deny = set(review.get("deny", []))
    lines = [
        "// GENERATED by Scripts/vocab/harvest.py — do not edit by hand.",
        "// Regenerate: python3 Scripts/vocab/harvest.py all   (see Scripts/vocab/README.md)",
        "//",
        "// Every mishearing rule below was produced by the real recogniser when a",
        "// known term was spoken by several synthetic voices, then filtered: heard by",
        "// at least two voices, close in sound to the term, never a single ordinary",
        "// English or Spanish word. Casing rules exist only for terms whose lower-case",
        "// form is not an ordinary word.",
        "",
        "enum StarterVocabulary {",
        "    /// (spoken, replacement, why)",
        "    static let observed: [(String, String, String)] = [",
    ]
    for c in data["candidates"]:
        if c["spoken"] in deny:
            continue
        why = f"Starter pack: heard for '{c['replacement']}' in {c['count']} clips, {c['voices']} voices ({'/'.join(c['locales'])})."
        lines.append(f"        ({swift_str(c['spoken'])}, {swift_str(c['replacement'])}, {swift_str(why)}),")
    lines += ["    ]", "", "    /// Canonical spelling only — the words are already recognised.",
              "    static let casingOnly: [(String, String)] = ["]
    for c in data["casing"]:
        lines.append(f"        ({swift_str(c['spoken'])}, {swift_str(c['replacement'])}),")
    lines += ["    ]", "}", ""]
    out = os.path.join(ROOT, "Packages", "TextProcessingCore", "Sources", "TextProcessingCore",
                       "StarterVocabulary.swift")
    open(out, "w", encoding="utf-8").write("\n".join(lines))
    print(f"wrote {out}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stage", choices=["synth", "transcribe", "analyze", "emit", "all"])
    ap.add_argument("--work", default=os.path.join(ROOT, "build", "vocab-harvest"))
    ap.add_argument("--binary")
    args = ap.parse_args()
    stages = {"synth": stage_synth, "transcribe": stage_transcribe,
              "analyze": stage_analyze, "emit": stage_emit}
    for name in (["synth", "transcribe", "analyze", "emit"] if args.stage == "all" else [args.stage]):
        stages[name](args)


if __name__ == "__main__":
    main()

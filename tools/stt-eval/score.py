#!/usr/bin/env python3
"""HyperVibe STT eval scorer. Stdlib only.

Subcommands:
  gen-refs --corpus <dir> [--refs refs.tsv]
      Write/extend a reference stub from corpus JSON sidecars.
      Columns: id <TAB> reference <TAB> kind   (kind: speech|command|silence)
      Hand-correct `reference` afterwards; that becomes ground truth.

  score --refs refs.tsv --hypotheses hypotheses.json [--out report.json]
      Report normalized WER/CER, command exact-match, hallucination-on-silence,
      and decode-latency aggregates. Utterances missing from refs (or left with
      kind outside speech/command/silence) count as unverified.
"""

import argparse
import json
import sys
import unicodedata
from pathlib import Path


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).lower()
    text = "".join(c if (c.isalnum() or c.isspace()) else " " for c in text)
    return " ".join(text.split())


def levenshtein(a, b) -> int:
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def wer(ref: str, hyp: str):
    """(errors, ref_len) over normalized words."""
    r, h = normalize(ref).split(), normalize(hyp).split()
    return levenshtein(r, h), len(r)


def cer(ref: str, hyp: str):
    r, h = normalize(ref), normalize(hyp)
    return levenshtein(r, h), len(r)


def percentile(values, p):
    if not values:
        return None
    values = sorted(values)
    k = min(len(values) - 1, max(0, round(p / 100 * (len(values) - 1))))
    return values[k]


def gen_refs(args):
    corpus = Path(args.corpus).expanduser()
    refs_path = Path(args.refs)
    existing = set()
    if refs_path.exists():
        with refs_path.open() as f:
            existing = {line.split("\t")[0] for line in f if line.strip()}
    rows = []
    for sidecar in sorted(corpus.glob("*.json")):
        meta = json.loads(sidecar.read_text())
        uid = meta.get("id", sidecar.stem)
        if uid in existing:
            continue
        raw = (meta.get("rawTranscript") or "").replace("\t", " ").replace("\n", " ")
        rows.append(f"{uid}\t{raw}\t{'silence' if not raw else 'speech'}")
    if rows:
        with refs_path.open("a") as f:
            f.write("\n".join(rows) + "\n")
    print(f"added {len(rows)} rows to {refs_path} ({len(existing)} already present)")
    print("hand-correct the reference column; set kind=command for exact-match clips")


def load_refs(path):
    refs = {}
    with open(path) as f:
        for line in f:
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            refs[parts[0]] = {"reference": parts[1], "kind": parts[2].strip()}
    return refs


def score(args):
    refs = load_refs(args.refs)
    hyps = {h["id"]: h for h in json.loads(Path(args.hypotheses).read_text())}

    rows, unverified = [], []
    word_err = word_tot = char_err = char_tot = 0
    cmd_total = cmd_exact = 0
    sil_total = sil_halluc = 0
    latencies = []

    for uid, hyp in sorted(hyps.items()):
        ref = refs.get(uid)
        latencies.append(hyp.get("decodeMs", 0))
        if ref is None or ref["kind"] not in ("speech", "command", "silence"):
            unverified.append(uid)
            continue
        kind, ref_text, hyp_text = ref["kind"], ref["reference"], hyp["text"]
        row = {"id": uid, "kind": kind, "reference": ref_text, "hypothesis": hyp_text,
               "decodeMs": hyp.get("decodeMs", 0)}
        if kind == "silence":
            sil_total += 1
            halluc = bool(normalize(hyp_text))
            sil_halluc += halluc
            row["hallucination"] = halluc
        else:
            we, wt = wer(ref_text, hyp_text)
            ce, ct = cer(ref_text, hyp_text)
            word_err += we; word_tot += wt
            char_err += ce; char_tot += ct
            row["wer"] = round(we / wt, 4) if wt else None
            row["cer"] = round(ce / ct, 4) if ct else None
            if kind == "command":
                cmd_total += 1
                exact = normalize(ref_text) == normalize(hyp_text)
                cmd_exact += exact
                row["exactMatch"] = exact
        rows.append(row)

    summary = {
        "utterances": len(hyps),
        "scored": len(rows),
        "unverified": len(unverified),
        "wer": round(word_err / word_tot, 4) if word_tot else None,
        "cer": round(char_err / char_tot, 4) if char_tot else None,
        "commandExactMatchRate": round(cmd_exact / cmd_total, 4) if cmd_total else None,
        "commandCount": cmd_total,
        "hallucinationOnSilenceRate": round(sil_halluc / sil_total, 4) if sil_total else None,
        "silenceCount": sil_total,
        "decodeMsMean": round(sum(latencies) / len(latencies), 1) if latencies else None,
        "decodeMsP95": percentile(latencies, 95),
    }

    report = {"summary": summary, "utterances": rows, "unverifiedIds": unverified}
    Path(args.out).write_text(json.dumps(report, indent=2, ensure_ascii=False))

    print(f"{'metric':<28}{'value'}")
    for k, v in summary.items():
        print(f"{k:<28}{v}")
    print(f"\nwrote {args.out}")


def self_test():
    assert normalize("Hello,  WORLD!") == "hello world"
    assert wer("a b c d", "a b c d") == (0, 4)
    assert wer("a b c d", "a x c d") == (1, 4)          # 1 sub over 4 words = 0.25
    assert wer("a b", "") == (2, 2)
    assert cer("abc", "abc") == (0, 3)
    e, t = cer("abc", "axc"); assert (e, t) == (1, 3)
    assert normalize("") == "" and not normalize("  .,  ")  # silence hallucination base
    print("self-test ok")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("gen-refs")
    g.add_argument("--corpus", required=True)
    g.add_argument("--refs", default="refs.tsv")
    g.set_defaults(fn=gen_refs)

    s = sub.add_parser("score")
    s.add_argument("--refs", required=True)
    s.add_argument("--hypotheses", required=True)
    s.add_argument("--out", default="report.json")
    s.set_defaults(fn=score)

    t = sub.add_parser("self-test")
    t.set_defaults(fn=lambda _: self_test())

    args = parser.parse_args()
    args.fn(args)


if __name__ == "__main__":
    sys.exit(main())

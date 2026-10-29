#!/usr/bin/env python3
"""UI strings (src/app/i18n.jai).

  python3 -I tools/i18n.py extract          rewrite src/app/lang/keys.txt from the L(...) / Lp(...) calls
                                            and the literals on lines marked "// i18n" (tables read by tr)
  python3 -I tools/i18n.py check [--fix]    per language: missing, stale and malformed lines (--fix drops
                                            stale lines and sorts the file in key order)
  python3 -I tools/i18n.py missing <code>   the untranslated keys of one language, one per line

A lang/<code>.txt line is "English<TAB>translation", both with \\n, \\t and \\\\ escaped. The English is
the text without any "##id" suffix. A plural (Lp) key is "one|other"; its translation lists the
language's forms (PLURAL_FORMS) joined by "|". A list key ("January|February|...") keeps its count.
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANG = os.path.join(ROOT, "src", "app", "lang")
LIT = r'"((?:[^"\\\n]|\\.)*)"'
CALL = re.compile(r'\b(L|Lp)\(\s*' + LIT + r'(?:\s*,\s*' + LIT + r')?')

# CLDR whole-number categories per language (i18n.jai plural_rule)
PLURAL_FORMS = {"fr": 2, "pt-BR": 2, "hi": 2, "ja": 1, "zh-CN": 1, "zh-TW": 1, "ko": 1, "th": 1, "vi": 1,
                "ru": 3, "uk": 3, "hr": 3, "pl": 3, "cs": 3, "lt": 3, "ro": 3}


def jai_unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c != "\\":
            out.append(c); i += 1; continue
        n = s[i + 1]
        if n in "uU":
            w = 4 if n == "u" else 8
            out.append(chr(int(s[i + 2:i + 2 + w], 16))); i += 2 + w; continue
        if n == "x":
            out.append(chr(int(s[i + 2:i + 4], 16))); i += 4; continue
        out.append({"n": "\n", "t": "\t", "r": "\r", "e": "\x1b", "0": "\0"}.get(n, n)); i += 2
    return "".join(out)


def esc(s):
    return s.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")


def unesc(s):
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), s)


def visible(k):
    i = k.find("##")
    return k if i < 0 else k[:i]


def strip_comments(text):
    out = []
    for line in text.split("\n"):
        i, q = 0, False
        while i < len(line):
            c = line[i]
            if q and c == "\\":
                i += 2; continue
            if c == '"':
                q = not q
            elif not q and line.startswith("//", i):
                line = line[:i]; break
            i += 1
        out.append(line)
    return "\n".join(out)


def scan():
    keys, plurals = set(), set()
    for d, _, files in os.walk(os.path.join(ROOT, "src")):
        for f in files:
            if not f.endswith(".jai"):
                continue
            raw = open(os.path.join(d, f), encoding="utf-8").read()
            text = strip_comments(raw)
            for line in raw.split("\n"):  # a table of strings shown through tr(): its line says "// i18n"
                if "// i18n" in line and f != "i18n.jai":
                    for lit in re.findall(LIT, strip_comments(line)):
                        if re.search(r"[A-Z]|\w[ .,!?…]", lit):  # not the ids and icon names beside them
                            keys.add(jai_unescape(lit))
            for m in CALL.finditer(text):
                a = jai_unescape(m.group(2))
                if m.group(1) == "Lp":
                    if m.group(3) is None:
                        sys.exit(f"{f}: Lp needs two literals: {a!r}")
                    a = a + "|" + jai_unescape(m.group(3))
                    plurals.add(a)
                keys.add(a)
    return keys, plurals


def lang_files():
    return sorted(f[:-4] for f in os.listdir(LANG) if f.endswith(".txt") and f != "keys.txt")


def read_lang(code):
    rows = {}
    for line in open(os.path.join(LANG, code + ".txt"), encoding="utf-8").read().split("\n"):
        if not line or line.startswith("#") or "\t" not in line:
            continue
        k, v = line.split("\t", 1)
        rows[unesc(k)] = unesc(v)
    return rows


def placeholders(s):
    return sorted(re.findall(r"%\d*", s.replace("%%", "")))


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    keys, plurals = scan()
    if cmd == "extract":
        os.makedirs(LANG, exist_ok=True)
        out = sorted(keys, key=lambda k: k.encode("utf-8"))
        open(os.path.join(LANG, "keys.txt"), "w", encoding="utf-8").write("".join(esc(k) + "\n" for k in out))
        print(f"{len(out)} keys")
        return
    vis = {}
    for k in keys:
        vis.setdefault(visible(k), k)
    if cmd == "missing":
        rows = read_lang(sys.argv[2])
        for v in sorted(vis, key=lambda k: k.encode("utf-8")):
            if v not in rows:
                print(esc(v))
        return
    if cmd != "check":
        sys.exit(__doc__)
    bad = False
    for code in lang_files():
        rows = read_lang(code)
        stale = [k for k in rows if k not in vis]
        missing = [k for k in vis if k not in rows]
        errs = []
        for k, v in rows.items():
            if k not in vis:
                continue
            if k in plurals:
                want = PLURAL_FORMS.get(code, 2)
                forms = v.split("|")
                if len(forms) != want:
                    errs.append(f"plural needs {want} forms: {k!r} -> {v!r}")
                for f in forms:
                    if placeholders(f) and placeholders(f) != placeholders(k.split("|")[1]):
                        errs.append(f"placeholders differ: {k!r} -> {v!r}")
            elif "|" in k and v.count("|") != k.count("|"):
                errs.append(f"list needs {k.count('|') + 1} items: {k!r}")
            elif placeholders(v) != placeholders(k) and placeholders(v) != [f"%{i + 1}" for i in range(len(placeholders(k)))] \
                    and sorted(placeholders(v)) != sorted(f"%{i + 1}" for i in range(len(placeholders(k)))):
                errs.append(f"placeholders differ: {k!r} -> {v!r}")
        print(f"{code}: {len(rows) - len(stale)}/{len(vis)} translated, {len(stale)} stale, {len(errs)} errors")
        for e in errs[:20]:
            print("  " + e)
        bad |= bool(errs)
        if "--fix" in sys.argv:
            head = [l for l in open(os.path.join(LANG, code + ".txt"), encoding="utf-8").read().split("\n") if l.startswith("#")]
            body = [esc(k) + "\t" + esc(rows[k]) for k in sorted(rows, key=lambda k: k.encode("utf-8")) if k in vis]
            open(os.path.join(LANG, code + ".txt"), "w", encoding="utf-8").write("\n".join(head + body) + "\n")
    sys.exit(1 if bad else 0)


main()

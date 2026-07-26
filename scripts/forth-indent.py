#!/usr/bin/env python3
"""Linter and indenter for muxleq-style Forth source.

LINT (the default, non-destructive) reports hazards a mechanical model can see
reliably, without a full grammar:
  - a multi-line "( ... )" comment: it compiles under gforth but breaks the
    self-hosting bootstrap, so it is an error here;
  - trailing whitespace and hard tabs.
These are what "make indent" runs on the Forth sources.

--fix strips trailing whitespace only, and never on a line that ends inside a
string (that tail is data). --reindent rewrites the leading whitespace run of a
line from the control-flow nesting depth, leaving every other byte (token text,
inter-token spacing, string and comment interiors, and trailing whitespace)
untouched, so a reindented file compiles identically. Reindent suits ordinary
Forth; the metacompiler's label and fall-through idioms are hand-tuned and do
not nest mechanically, so run it deliberately, not as a gate.

Usage:
  forth-indent.py FILE...            lint (multi-line comment, trailing ws, tab)
  forth-indent.py --fix FILE...      strip trailing whitespace in place
  forth-indent.py --reindent FILE... rewrite leading whitespace by depth
  forth-indent.py --check FILE...    report lines --reindent would change
  forth-indent.py --width N ...      spaces per nesting level (default 2)
"""

import argparse
import sys

# Colon-definition words; the following token is the NAME (skipped for depth).
DEFINERS = {":", ":m", ":s", ":a", ":to", ":so", ":e", ":r"}
# Control-block openers (indent the following lines). :noname opens an anonymous
# definition but consumes NO name, so it belongs here, not with the definers.
OPENERS = {"if", "+if", "begin", "do", "?do", "case", "of", "for", ":noname"}
# Dedent this line, net depth unchanged.
MIDDLES = {"else", "while", "aft"}
# Block closers, including the assembler's custom enders and fall-through.
CLOSERS = {
    ";",
    ";m",
    ";s",
    ";a",
    "(a);",
    "(fall-through);",
    "then",
    "repeat",
    "until",
    "again",
    "loop",
    "+loop",
    "endof",
    "endcase",
    "next",
}
STRING_WORDS = {'."', 'c"', 's"', 'abort"', 's\\"'}
PAREN_WORDS = {"(", ".("}
# Words that consume the NEXT token as a literal name, so it must not be read as
# a comment/string opener or a control word: "' (" references "(", it does not
# open a comment; "char ;" is the character ';', not a definition end.
NAME_CONSUMERS = DEFINERS | {"'", "[']", "char", "[char]", "postpone", "to", "is"}


def str_end(line, i, escaped):
    """Index of the closing '"' at or after i, skipping backslash escapes for
    s\\" strings. Returns -1 if the string runs off the end of the line."""
    n = len(line)
    while i < n:
        c = line[i]
        if escaped and c == "\\":
            i += 2
            continue
        if c == '"':
            return i
        i += 1
    return -1


def scan(line, cont):
    """Return (tokens, cont_out). cont carries a multi-line comment/string state
    (None | "paren" | "string" | "string\\") into and out of the line; "string\\"
    is an s\\" string whose closing quote may be backslash-escaped. Comment and
    string bodies are dropped; only significant Forth words are returned."""
    tokens = []
    i, n = 0, len(line)
    if cont == "paren":
        k = line.find(")")
        if k < 0:
            return tokens, "paren"
        i = k + 1
    elif cont in ("string", "string\\"):
        k = str_end(line, 0, cont == "string\\")
        if k < 0:
            return tokens, cont
        i = k + 1
    literal = False
    while i < n:
        while i < n and line[i] in " \t":
            i += 1
        if i >= n:
            break
        j = i
        while j < n and line[j] not in " \t":
            j += 1
        word, i = line[i:j], j
        if literal:  # a name after ' ['] : char postpone ...
            tokens.append(word)
            literal = False
            continue
        if word == "\\":
            break
        if word in PAREN_WORDS:
            k = line.find(")", i)
            if k < 0:
                return tokens, "paren"
            i = k + 1
            continue
        if word in STRING_WORDS:
            escaped = word == 's\\"'
            k = str_end(line, i, escaped)
            if k < 0:
                return tokens, "string\\" if escaped else "string"
            i = k + 1
            continue
        tokens.append(word)
        if word in NAME_CONSUMERS:
            literal = True
    return tokens, None


def indent_of(depth, tokens):
    """Indent level for a line that starts at `depth`, dedented by its leading
    run of closers/middles."""
    d = depth
    for t in tokens:
        if t in CLOSERS or t in MIDDLES:
            d -= 1
            if t in MIDDLES:
                break
        else:
            break
    return max(0, d)


def after(depth, tokens):
    """Nesting depth after the line's tokens are consumed. A name after any
    NAME_CONSUMER is a literal, not a control word, so it is skipped."""
    skip = False
    for t in tokens:
        if skip:
            skip = False
            continue
        if t in DEFINERS or t in OPENERS:
            depth += 1
        elif t in CLOSERS:
            depth -= 1
        if t in NAME_CONSUMERS:
            skip = True
    return max(0, depth)


def analyze(text, width):
    """Return (errors, diffs, ws_fixed, reindented).

    errors:     (lineno, msg) lint failures (multi-line comment, tab, trailing).
    diffs:      (lineno, old, new) leading-indent columns --reindent would set.
    ws_fixed:   trailing whitespace stripped, except on lines ending in a string.
    reindented: leading whitespace set from nesting depth, all other bytes kept.
    """
    errors, diffs, ws_out, ri_out = [], [], [], []
    depth, cont = 0, None
    for lineno, line in enumerate(text.split("\n"), 1):
        if line != line.rstrip():
            errors.append((lineno, "trailing whitespace"))
        if "\t" in line:
            errors.append((lineno, "hard tab"))
        body = line.strip()
        in_cont = cont is not None
        tokens, cont = scan(line, cont)
        if cont == "paren" and not in_cont:
            errors.append(
                (
                    lineno,
                    'multi-line "( )" comment (breaks bootstrap; '
                    "close it on one line)",
                )
            )
        ends_in_string = cont in ("string", "string\\")
        # trailing-whitespace fix: unsafe only when the tail is string data.
        ws_out.append(line if ends_in_string else line.rstrip())
        # reindent: rewrite the leading whitespace run only. Never touch a line
        # that is a continuation or that ends inside a string, and keep every
        # byte after the leading run (including any trailing whitespace).
        if in_cont or ends_in_string or not body:
            ri_out.append(line if (in_cont or body) else "")
        else:
            content = line.lstrip(" \t")
            col = indent_of(depth, tokens) * width
            ri_out.append(" " * col + content)
            old = len(line) - len(content)
            if old != col:
                diffs.append((lineno, old, col))
        depth = after(depth, tokens)
    return errors, diffs, "\n".join(ws_out), "\n".join(ri_out)


def main():
    ap = argparse.ArgumentParser(description="Forth linter and indenter")
    ap.add_argument("files", nargs="+")
    ap.add_argument(
        "--fix",
        action="store_true",
        help="strip trailing whitespace in place (safe, no reindent)",
    )
    ap.add_argument(
        "--reindent",
        action="store_true",
        help="rewrite leading whitespace from nesting depth (opt-in)",
    )
    ap.add_argument(
        "--check",
        action="store_true",
        help="report lines whose indent --reindent would change",
    )
    ap.add_argument("--width", type=int, default=2)
    args = ap.parse_args()

    rc = 0
    for path in args.files:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        errors, diffs, ws_fixed, reindented = analyze(text, args.width)
        for lineno, msg in errors:
            print(f"{path}:{lineno}: error: {msg}")
            if not args.fix:
                rc = 1
        if args.reindent:
            if reindented != text:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(reindented)
                print(f"{path}: reindented {len(diffs)} line(s)")
        elif args.fix:
            if ws_fixed != text:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(ws_fixed)
                print(f"{path}: stripped trailing whitespace")
        elif args.check and diffs:
            for lineno, o, c in diffs:
                print(f"{path}:{lineno}: indent {o} -> {c}")
            print(f"{path}: {len(diffs)} line(s) would be reindented")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())

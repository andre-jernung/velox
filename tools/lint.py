#!/usr/bin/env python3
"""Static checks for the register conventions in CLAUDE.md.

1. scratch: d1 or a1 read after a call (jsr/bsr or a library macro)
   without being written in between.  Calls may destroy d0-d1/a0-a1;
   d0 is the result and many helpers return a pointer in a0, so only
   d1/a1 are checked.  Straight-line code only (a label ends a run).
2. ccr: a routine whose callers branch on the flags right after the call
   must leave the CCR set from d0 at every rts, unless its header says
   the result is in the Z flag ("Z clear"/"Z set").

usage: tools/lint.py [src/*.s]   (exit status 1 if anything is found)
"""
import glob
import re
import sys

CALL_MACROS = ("exec", "dos", "intui", "gfx", "gt", "layers", "sock", "ssl")
# helpers that are known to keep d1/a1 (checked by hand)
KEEPS = {"Len", "Cpy", "StrLenA0", "ToLower", "MqNum", "MqOp", "SkipWs",
         "DomGetAttr", "StrCopy"}


def regs(text):
    out = set()
    for m in re.finditer(r"\b([da][0-7])(?:-([da][0-7]))?\b", text):
        a, b = m.group(1), m.group(2)
        if b and a[0] == b[0]:
            out |= {a[0] + str(n) for n in range(int(a[1]), int(b[1]) + 1)}
        else:
            out.add(a)
            if b:
                out.add(b)
    return out


def split_ops(line):
    code = line.split(";")[0]
    code = re.sub(r"^[.\w]+:", "", code)
    parts = code.strip().split(None, 1)
    if not parts:
        return None
    mn = parts[0].lower()
    args = parts[1] if len(parts) > 1 else ""
    depth, cut = 0, None
    for i, c in enumerate(args):
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif c == "," and depth == 0:
            cut = i
    if cut is None:
        return mn, args, ""
    return mn, args[:cut], args[cut + 1:]


def headers(files):
    """name -> the comment block above its label"""
    out = {}
    for f in files:
        lines = open(f, encoding="latin-1").read().split("\n")
        for i, line in enumerate(lines):
            m = re.match(r"^([A-Za-z_]\w*):", line)
            if m:
                block = []
                j = i - 1
                while j >= 0 and lines[j].startswith(";"):
                    block.insert(0, lines[j])
                    j -= 1
                out[m.group(1)] = "\n".join(block)
    return out


def returns(header, reg):
    """does the header say the routine gives back (or keeps) reg?"""
    out = header.split("Out:", 1)[1] if "Out:" in header else ""
    return bool(reg in regs(out) or
                re.search(rf"\b{reg}\b[^\n]*\b(kept|preserved)", header) or
                re.search(rf"(kept|preserved)[^\n]*\b{reg}\b", header))


def scratch(files):
    found = []
    hdr = headers(files)
    for f in files:
        lines = open(f, encoding="latin-1").read().split("\n")
        clob = {}
        for n, line in enumerate(lines, 1):
            if re.match(r"^[.\w]+:", line):
                clob = {}
            o = split_ops(line) if line[:1].isspace() or re.match(r"^[.\w]+:\s+\S", line) else None
            if not o:
                continue
            mn, src, dst = o
            if mn.startswith(("jsr", "bsr")) or mn in CALL_MACROS:
                callee = src.strip()
                h = hdr.get(callee, "")
                for r in ("d1", "a1"):
                    if callee not in KEEPS and not returns(h, r):
                        clob[r] = n
                    else:
                        clob.pop(r, None)
                continue
            if re.match(r"(bra|jmp|rts)\b", mn):
                clob = {}
                continue
            d = dst.strip()
            reads = regs(src)
            if mn.startswith("movem") and "(" in src:
                pass				# a load into registers
            elif d and not re.fullmatch(r"[da][0-7]", d):
                reads |= regs(d)
            elif d and not re.match(r"(move|moveq|lea|movem|clr|suba|exg|s\w\w)\b", mn):
                reads.add(d)
            if mn.startswith(("tst", "ext", "swap", "neg", "not")):
                reads |= regs(src)
            if mn.startswith("suba") and regs(src) == regs(d):
                reads -= regs(d)
            for r in sorted(reads & set(clob)):
                found.append(f"{f}:{n}: {r} read after the call in line {clob[r]}: {line.strip()}")
                del clob[r]
            written = set()
            if re.fullmatch(r"[da][0-7]", d):
                written.add(d)
            if mn.startswith("movem") and "(" in src:
                written |= regs(d)
            if mn.startswith(("clr", "s")) and re.fullmatch(r"[da][0-7]", src.strip()):
                written.add(src.strip())
            if mn.startswith("exg"):
                written |= regs(src + "," + d)
            for r in written:
                clob.pop(r, None)
    return found


def ccr(files):
    found = []
    text = {f: open(f, encoding="latin-1").read().split("\n") for f in files}
    users = {}
    for f, lines in text.items():
        for i, line in enumerate(lines):
            m = re.match(r"\s+(jsr|bsr)(\.\w)?\s+([A-Za-z]\w*)\s*(;.*)?$", line)
            if m and i + 1 < len(lines):
                nxt = lines[i + 1].split(";")[0].strip()
                if re.match(r"(beq|bne|bmi|bpl|bgt|blt|bge|ble)\b", nxt):
                    users.setdefault(m.group(3), []).append(f"{f}:{i + 1}")
    skip = re.compile(r"(movem|lea|pea|bra|jmp|addq\.l\s+#\d,sp|move\.l\s+\(sp\)\+,a[0-7]|move\.l\s+\w+,a[0-7]|rts)")
    good = re.compile(r"(tst\.l\s+d0|,d0\s*$|moveq\s+#[-\w$]+,d0|clr\.l\s+d0|,ccr\s*$|"
                      r"move\.l\s+d0,|jsr\s+\w+|bsr\s+\w+)")
    for name, calls in sorted(users.items()):
        for f, lines in text.items():
            starts = [i for i, l in enumerate(lines) if re.match(rf"^{name}:", l)]
            if not starts:
                continue
            start = starts[0]
            header = "\n".join(lines[max(0, start - 8):start])
            if re.search(r"Z (clear|set)", header):
                continue
            end = start + 1
            while end < len(lines) and not re.match(r"^[A-Za-z_]\w*:", lines[end]):
                end += 1
            for i in range(start, end):
                if not re.match(r"^([.\w]+:)?\s+rts\b", lines[i]):
                    continue
                j = i - 1
                while j > start:
                    body = re.sub(r"^[.\w]+:", "", lines[j].split(";")[0]).strip()
                    if body and not skip.match(body):
                        break
                    j -= 1
                body = re.sub(r"^[.\w]+:", "", lines[j].split(";")[0]).strip()
                if not good.search(body):
                    found.append(f"{f}:{i + 1}: {name} may return the CCR of '{body}' "
                                 f"(callers test it: {calls[0]})")
    return found


def main():
    files = sys.argv[1:] or sorted(glob.glob("src/*.s"))
    problems = scratch(files) + ccr(files)
    for p in problems:
        print(p)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()

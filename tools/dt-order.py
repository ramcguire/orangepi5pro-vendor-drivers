#!/usr/bin/env python3
"""Node order in device tree overlays.

    tools/dt-order.py reverse < overlay.dts > overlay.dts
    tools/dt-order.py check base.dtb ours.dtb merged.dtb

Applying an overlay adds each new node before its parent's first child, reversing a
fragment's nodes; probe order, and so core numbering, follows node order.

reverse: reverses the child nodes in every node, so they apply in source order.
check: the children merged (base plus one overlay) adds, and base's own, are in ours's
order.
"""
import re
import subprocess
import sys

# "name {" or "label: name {", maybe a whole node on one line.
NODE = re.compile(r"^(?:[\w-]+:\s*)?[\w,.@+#-]+\s*\{")


def block_end(lines, i):
    """Index of the "};" closing the node whose header is lines[i]."""
    depth = 0
    for j in range(i, len(lines)):
        depth += lines[j].count("{") - lines[j].count("}")
        if depth == 0:
            return j
    sys.exit(f"dt-order.py: no end for the node at line {i + 1}: {lines[i]!r}")


def reorder(lines, nested):
    """lines: one node's body. Returns it with child nodes reversed if nested."""
    props, nodes, pending = [], [], []
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if not s or s.startswith("//"):
            pending.append(lines[i])
            i += 1
        elif s.startswith("/*"):
            j = i
            while "*/" not in lines[j]:
                j += 1
            pending += lines[i : j + 1]
            i = j + 1
        elif NODE.match(s):
            j = block_end(lines, i)
            if j == i:
                nodes.append(pending + [lines[i]])
            else:
                nodes.append(pending + [lines[i]] + reorder(lines[i + 1 : j], True) + [lines[j]])
            pending = []
            i = j + 1
        else:
            j = i
            while not lines[j].strip().endswith(";"):
                j += 1
            props.append(pending + lines[i : j + 1])
            pending = []
            i = j + 1
    if nested:
        nodes.reverse()
    return [l for p in props for l in p] + [l for n in nodes for l in n] + pending


def reverse(text):
    lines = text.split("\n")
    out, i = [], 0
    while i < len(lines):
        if lines[i].rstrip().endswith("{"):
            j = block_end(lines, i)
            out += [lines[i]] + reorder(lines[i + 1 : j], True) + [lines[j]]
            i = j + 1
        else:
            out.append(lines[i])
            i += 1
    return "\n".join(out)


def children(dtb):
    """{parent path: [child paths in tree order]}, from dtc's unsorted output."""
    dtc = ["dtc", "-q", "-I", "dtb", "-O", "dts", dtb]
    dts = subprocess.run(dtc, check=True, capture_output=True, text=True).stdout
    kids, stack = {}, []
    for line in dts.splitlines():
        s = line.strip()
        if s.endswith("{"):
            name = s[:-1].strip().split(": ")[-1]
            path = "/" if name == "/" else (stack[-1].rstrip("/") + "/" + name)
            if stack:
                kids.setdefault(stack[-1], []).append(path)
            stack.append(path)
        elif s == "};":
            stack.pop()
    return kids


def check(base, ours, merged):
    base, ours, merged = children(base), children(ours), children(merged)
    bad = 0
    for parent, got in merged.items():
        if parent.split("/")[1:2] in (["__symbols__"], ["__fixups__"], ["__local_fixups__"]):
            continue
        old = set(base.get(parent, []))
        here = set(got)
        want = [p for p in ours.get(parent, []) if p in here]
        for kind, keep in (("new", lambda p: p not in old), ("existing", lambda p: p in old)):
            w = [p for p in want if keep(p)]
            g = [p for p in got if keep(p)]
            if w != g:
                bad = 1
                print(f"dt-order.py: {kind} children of {parent} in a different order:", file=sys.stderr)
                print(f"  ours:   {' '.join(p.rsplit('/', 1)[1] for p in w)}", file=sys.stderr)
                print(f"  merged: {' '.join(p.rsplit('/', 1)[1] for p in g)}", file=sys.stderr)
    return bad


if __name__ == "__main__":
    if sys.argv[1:2] == ["reverse"]:
        sys.stdout.write(reverse(sys.stdin.read()))
    elif sys.argv[1:2] == ["check"] and len(sys.argv) == 5:
        sys.exit(check(*sys.argv[2:]))
    else:
        sys.exit(__doc__)

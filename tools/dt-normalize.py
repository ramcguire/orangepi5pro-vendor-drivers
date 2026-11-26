#!/usr/bin/env python3
"""Print a decompiled device tree with phandles as node paths, for diffing.

    dtc -I dtb -O dts -s x.dtb | tools/dt-normalize.py

Builds number phandles differently, so references become &/path with their cells, and
phandle properties and __symbols__/__fixups__/__local_fixups__ are dropped. Unknown or
unparsable properties stay as they are, so they still diff.
"""
import re
import sys

# Specifier lists: phandle, then the provider's #<cells> cells.
CELLS = {
    "clocks": "#clock-cells",
    "assigned-clocks": "#clock-cells",
    "assigned-clock-parents": "#clock-cells",
    "resets": "#reset-cells",
    "iommus": "#iommu-cells",
    "power-domains": "#power-domain-cells",
    "phys": "#phy-cells",
    "dmas": "#dma-cells",
    "thermal-sensors": "#thermal-sensor-cells",
    "cooling-device": "#cooling-cells",
    "pwms": "#pwm-cells",
    "io-channels": "#io-channel-cells",
    "sound-dai": "#sound-dai-cells",
    "mboxes": "#mbox-cells",
    "interrupts-extended": "#interrupt-cells",
    "gpio": "#gpio-cells",
    "gpios": "#gpio-cells",
}
# Lists of bare phandles.
BARE = re.compile(
    r"^(interrupt-parent|operating-points-v2|remote-endpoint|cpu|cpus|sram|memory-region"
    r"|nvmem-cells|trip|phy-handle|i2c-bus|ddc-i2c-bus|pinctrl-\d+|mmc-pwrseq"
    r"|cpu-idle-states|next-level-cache|[\w,-]+-supply"
    r"|snps,(axi|mtl-rx|mtl-tx)-config|simple-audio-card,[\w-]+-master|[\w,-]+,aux-devs"
    r"|rockchip,(srv|ccu|sram|pmu|[\w-]*grf))$"
)
SKIP_NODES = {"__symbols__", "__fixups__", "__local_fixups__"}

PROP = re.compile(r"^(\s*)([\w,.+#?-]+) = (.*);$")
NODE = re.compile(r"^(\s*)(?:[\w-]+: )?([\w,.@+-]+|/) \{$")


def walk(lines):
    """Yield (path, parent path, line, prop name or None, value or None)."""
    stack = []

    def path(s):
        return ("/" + "/".join(s[1:])) if s else ""

    for line in lines:
        line = line.rstrip("\n")
        if m := NODE.match(line):
            stack.append(m.group(2))
            yield path(stack), path(stack[:-1]), line, None, None
        elif line.strip() == "};":
            yield path(stack), path(stack[:-1]), line, None, None
            stack.pop()
        elif m := PROP.match(line):
            yield path(stack), path(stack[:-1]), line, m.group(2), m.group(3)
        else:
            yield path(stack), path(stack[:-1]), line, None, None


class Unresolved(Exception):
    pass


def main():
    lines = sys.stdin.readlines()
    path_of, props = {}, {}
    for path, _, _, name, value in walk(lines):
        if name is not None:
            props.setdefault(path, {})[name] = value
            if name == "phandle":
                path_of[int(value.strip("<>"), 16)] = path

    def cell(path, key, default=0):
        v = props.get(path, {}).get(key)
        return int(v.strip("<>"), 16) if v else default

    def ph(tok):
        p = path_of.get(int(tok, 16))
        if p is None:
            raise Unresolved
        return p

    # Each layout reads one entry from tokens[i:], returns (rendered, next i).
    def specifier(key):
        def f(t, i, node, parent):
            p = ph(t[i])
            n = cell(p, key) if key else 0
            return ["&" + p] + t[i + 1 : i + 1 + n], i + 1 + n
        return f

    def fixed(before, after):
        def f(t, i, node, parent):
            p = ph(t[i + before])
            return t[i : i + before] + ["&" + p] + t[i + before + 1 : i + before + 1 + after], i + before + 1 + after
        return f

    def idmap(key):
        # iommu-map/msi-map: rid-base, phandle, base (#cells), length.
        def f(t, i, node, parent):
            p = ph(t[i + 1])
            n = cell(p, key, 1)
            return [t[i], "&" + p] + t[i + 2 : i + 3 + n], i + 3 + n
        return f

    def interrupt_map(t, i, node, parent):
        # child unit address, child specifier, parent, parent unit address, its specifier.
        a = cell(node, "#address-cells", cell(parent, "#address-cells", 2))
        c = cell(node, "#interrupt-cells")
        p = ph(t[i + a + c])
        pa, pc = cell(p, "#address-cells"), cell(p, "#interrupt-cells")
        j = i + a + c + 1
        return t[i : i + a + c] + ["&" + p] + t[j : j + pa + pc], j + pa + pc

    def layout(name):
        if name in CELLS:
            return specifier(CELLS[name])
        if name.endswith("-gpios"):
            return specifier("#gpio-cells")
        if BARE.match(name):
            return specifier(None)
        return {
            "rockchip,pins": fixed(3, 0),
            "gpio-ranges": fixed(0, 3),
            "iommu-map": idmap("#iommu-cells"),
            "msi-map": idmap("#msi-cells"),
            "interrupt-map": interrupt_map,
        }.get(name)

    def resolve(name, value, node, parent):
        f = layout(name)
        groups = re.findall(r"<([^>]*)>", value)
        if f is None or not groups or re.sub(r"<[^>]*>|,|\s", "", value):
            return value
        out = []
        try:
            for g in groups:
                t, i, res = g.split(), 0, []
                while i < len(t):
                    r, i = f(t, i, node, parent)
                    res += r
                if i != len(t):
                    raise Unresolved
                out.append("<" + " ".join(res) + ">")
        except (Unresolved, IndexError):
            return value
        return ", ".join(out)

    skip = 0
    for path, parent, line, name, value in walk(lines):
        if skip or (line.endswith("{") and path.split("/")[1:2] and path.split("/")[1] in SKIP_NODES):
            skip += line.endswith("{") - (line.strip() == "};")
            continue
        if name == "phandle":
            continue
        if name is not None:
            indent = line[: len(line) - len(line.lstrip())]
            line = f"{indent}{name} = {resolve(name, value, path, parent)};"
        print(line)


main()

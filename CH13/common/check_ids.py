#!/usr/bin/env python3
"""Assert every copy of a kernel id agrees.

    common/check_ids.py            # exits non-zero on any disagreement

A kernel id exists in four places, and it has to, because none of them can read
the others:

    SystemVerilog/hdl/rm_<name>.sv   the localparam the hardware reports at 0x3C
    common/config.tcl                the build's registry
    sw/rm_ref.py                     the golden model's registry
    sw/dfx_socket.py                 the driver's registry

Three copies too many, and the reason it matters more here than usual: the id
is what proves a swap actually happened. If the driver's copy drifts from the
hardware's, the check after a swap compares two stale constants and passes
whatever is in the socket -- so the one safeguard against loading the wrong
partial silently stops working, and nothing looks wrong.

So the build calls this, and it fails the build rather than warning.
"""
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent


def from_rtl():
    """The localparam in each RM top -- what the hardware actually reports."""
    out = {}
    for f in sorted((ROOT / "SystemVerilog" / "hdl").glob("rm_*.sv")):
        name = f.stem[len("rm_"):]
        if name.endswith("_core") or name in ("shell", "axi_rd", "axi_wr"):
            continue
        m = re.search(r"localparam\s*\[31:0\]\s*KERNEL_ID\s*=\s*32'h([0-9A-Fa-f_]+)\s*;",
                      f.read_text())
        if m:
            out[name] = int(m.group(1).replace("_", ""), 16)
    return out


def from_tcl():
    """The build's registry, ch13_rms in common/config.tcl."""
    text = (HERE / "config.tcl").read_text()
    m = re.search(r"set ch13_rms \{(.*?)\n\}", text, re.S)
    if not m:
        raise SystemExit("could not find ch13_rms in common/config.tcl")
    out = {}
    for line in m.group(1).splitlines():
        fields = line.strip().strip("{}").split()
        if len(fields) >= 2 and fields[1].lower().startswith("0x"):
            out[fields[0]] = int(fields[1], 16)
    return out


def from_python(module, prefix="KERNEL_"):
    """A Python registry, read as text so this runs without numpy or PYNQ."""
    text = (ROOT / "sw" / module).read_text()
    out = {}
    for m in re.finditer(rf"^{prefix}([A-Z]+)\s*=\s*(0x[0-9A-Fa-f]+)\s*$", text, re.M):
        name = m.group(1).lower()
        if name in ("names",):
            continue
        out[name] = int(m.group(2), 16)
    return out


def main():
    sources = {
        "rtl (hdl/rm_*.sv)":  from_rtl(),
        "tcl (config.tcl)":   from_tcl(),
        "sw/rm_ref.py":       from_python("rm_ref.py"),
        "sw/dfx_socket.py":   from_python("dfx_socket.py"),
    }

    names = sorted(set().union(*(set(d) for d in sources.values())))
    if not names:
        print("check_ids: found no kernel ids at all -- the patterns are wrong")
        return 1

    width = max(len(n) for n in names)
    bad = 0
    for name in names:
        vals = {src: d.get(name) for src, d in sources.items()}
        distinct = set(v for v in vals.values() if v is not None)
        missing = [s for s, v in vals.items() if v is None]
        if len(distinct) == 1 and not missing:
            print(f"  {name:<{width}}  {distinct.pop():#010x}  ok")
        else:
            bad += 1
            print(f"  {name:<{width}}  MISMATCH")
            for src, v in vals.items():
                print(f"      {src:<22} {'absent' if v is None else f'{v:#010x}'}")

    if bad:
        print(f"check_ids: {bad} kernel id(s) disagree across sources")
        return 1
    print(f"check_ids: {len(names)} kernel ids agree across {len(sources)} sources")
    return 0


if __name__ == "__main__":
    sys.exit(main())

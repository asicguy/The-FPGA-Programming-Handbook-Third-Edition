#!/usr/bin/env python3
"""Check the SYSMON notebook actually runs, including the interactive cell.

    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 \
        check_notebook.py [path/to/ch13_xadc_sysmon.ipynb]

WHY THIS EXISTS

The notebook shipped once with cell 5 collapsed into a single 1116-character
line -- `import ipywidgets as widgetsfrom IPython.display import display...` --
which is a syntax error the moment anyone runs it. Two separate mistakes let
that through, and both are worth naming:

  1. The cells were built with `.strip().split("\\n")`, which drops the
     trailing newlines nbformat expects. Jupyter joins a cell's source list
     with no separator, so a cell written that way becomes one long line.

  2. The verification SKIPPED the interactive cell, because it contains a
     `while` loop that never returns. Skipping the only cell that was broken
     is not verification, and "the other cells ran" is not evidence about the
     one that did not.

So this does two things the earlier check did not:

  * COMPILES every code cell, including the interactive one. A syntax error
    needs no execution to find, and compiling is free.
  * EXECUTES the interactive cell's body exactly once, by rewriting its
    `while` into a single-iteration `for`. Every line in the loop then runs
    against real hardware without hanging.
"""
import json
import io
import os
import re
import sys

SW_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SW_DIR)

DEFAULT = os.path.join(SW_DIR, os.pardir, "notebooks", "ch13_xadc_sysmon.ipynb")
path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
if not os.path.exists(path):
    # The notebook sits beside the project in the repo and the Jupyter tree,
    # and one level up in the flat harness. Same search the notebook itself
    # does, for the same reason.
    for rel in ("../notebooks", "../project_xadc_sysmon/notebooks", "notebooks"):
        cand = os.path.join(SW_DIR, rel, "ch13_xadc_sysmon.ipynb")
        if os.path.exists(cand):
            path = cand
            break
    else:
        sys.exit("cannot find ch13_xadc_sysmon.ipynb; pass it as an argument")

nb = json.load(io.open(path, encoding="utf-8"))
print("notebook: %s" % os.path.realpath(path))
print("cells   : %d\n" % len(nb["cells"]))

code_cells = [(i, "".join(c["source"]))
              for i, c in enumerate(nb["cells"]) if c["cell_type"] == "code"]

# --- 1. every code cell must compile -------------------------------------
print("--- compiling every code cell ---")
broken = 0
for i, src in code_cells:
    try:
        compile(src, "<cell%d>" % i, "exec")
        print("  cell %-2d compiles   (%d lines)" % (i, src.count("\n") + 1))
    except SyntaxError as e:
        broken += 1
        print("  cell %-2d SYNTAX ERROR line %s: %s" % (i, e.lineno, e.msg))
if broken:
    sys.exit("\n%d cell(s) will not compile" % broken)

# --- 2. a cell of one line and many characters is the collapse bug --------
print("\n--- checking cell line structure ---")
for i, c in enumerate(nb["cells"]):
    n, length = len(c["source"]), len("".join(c["source"]))
    if n <= 1 and length > 200:
        sys.exit("  cell %d is one line of %d chars -- collapsed source" % (i, length))
print("  no collapsed cells")

# --- 3. run them, with the interactive loop bounded to one iteration ------
print("\n--- executing against hardware ---")
g = {}
for i, src in code_cells:
    if "while not stop.value:" in src:
        # Run the body once instead of forever. `stop` is still constructed,
        # so the widget setup is exercised too.
        src = src.replace("while not stop.value:", "for _once in range(1):")
        print("  cell %-2d running (loop bounded to one iteration)" % i)
    else:
        print("  cell %-2d running" % i)
    exec(compile(src, "<cell%d>" % i, "exec"), g)

print("\nNOTEBOOK OK -- every cell compiled and ran, interactive cell included")

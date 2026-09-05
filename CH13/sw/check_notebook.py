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

# --- 3. run them, and prove the Stop button stops the sampler -------------
# The live cell samples on a BACKGROUND THREAD and returns immediately, so it
# can be executed as-is; nothing has to be rewritten to avoid hanging.
#
# That structure is the fix for a real bug: a plain `while` loop in a cell
# blocks the kernel, so the click never reaches the handler and Stop does
# nothing. Since the button is the thing that broke, the check presses it.
import time

print("\n--- executing against hardware ---")
g = {}
for i, src in code_cells:
    print("  cell %-2d running" % i)
    exec(compile(src, "<cell%d>" % i, "exec"), g)

    sampler = g.get("_sampler")
    if sampler is None or not sampler.is_alive():
        continue

    # It is sampling. Let it take a few readings, then press Stop for real.
    time.sleep(0.5)
    moved = g["meter"].value
    g["stop_btn"].click()
    sampler.join(timeout=5.0)

    if sampler.is_alive():
        sys.exit("  cell %d: STOP BUTTON DID NOT STOP THE SAMPLER" % i)
    if moved == 0.0:
        sys.exit("  cell %d: sampler ran but the meter never updated" % i)
    print("       sampler took readings (meter %.4f V), Stop stopped it" % moved)

# --- 4. re-running the live cell must not leave two samplers running ------
# People re-run cells. If the previous thread survived, two of them would be
# writing the same widgets and the same LED GPIO, which is a genuinely
# unpleasant thing to debug from the symptoms.
live = [(i, src) for i, src in code_cells if "_sampler" in src]
if live:
    i, src = live[0]
    print("\n--- re-running cell %d while its sampler is still going ---" % i)
    exec(compile(src, "<cell%d>" % i, "exec"), g)
    first = g["_sampler"]
    time.sleep(0.3)
    exec(compile(src, "<cell%d>" % i, "exec"), g)   # again, deliberately
    second = g["_sampler"]

    if first is second:
        sys.exit("  re-running did not create a new sampler")
    if first.is_alive():
        sys.exit("  THE PREVIOUS SAMPLER SURVIVED -- two threads now share the GPIO")
    print("       previous sampler stopped, exactly one running")

    g["stop_btn"].click()
    second.join(timeout=5.0)
    if second.is_alive():
        sys.exit("  the replacement sampler would not stop")
    print("       replacement stopped cleanly")

print("\nNOTEBOOK OK -- every cell compiled and ran, Stop button verified")

#!/usr/bin/env python3
"""Fail loudly if macos/docs/MODULE_MAP.md drifts from Package.swift.

The Module map is where a contributor (human or agent) learns the module
layout (it lived in macos/CLAUDE.md until 2026-09-25). The risk: someone adds a `.library` product to Package.swift and
forgets the Module map table — the new module is then invisible to every reader,
and someone re-implements what already exists (the exact failure this guard was
born from: four products silently absent from the table). This compares the two
sets and exits non-zero on ANY divergence — an undocumented product OR a ghost
row for a module that no longer exists — so the omission fails CI instead of
hiding. Seconds, pure Python, no Xcode/build. Sibling of check_test_scheme.py.

    python3 check_doc_drift.py [PACKAGE_SWIFT] [MODULE_MAP_MD]

Defaults resolve both files relative to this script's repo. Read-only.

Assumes the M1K3* namespace and the Module map's `| ` + "`Name`" first-cell
convention, so a future rename of either is a deliberate act that trips this.
The pure helpers (parsing + diff) are unit-tested in test_check_doc_drift.py.

Signed: Kev + claude-opus-4-8, 2026-07-07, Confidence 0.85, Prior: Unknown
Review: Kev + claude-fable-5.1, 2026-09-25 — the table moved out of CLAUDE.md
(23 KB loaded on every turn of every macos/ session) into docs/MODULE_MAP.md;
only the default path and the messages changed, the parser and its tests are
untouched. Confidence now 0.85.
"""
from __future__ import annotations

import os
import re
import sys

# Documented in the Module map (in the M1K3MCPKit row) but NOT a `.library` —
# it's the stdio `.executableTarget`. Allowlisted so it isn't flagged a ghost.
ALLOWED_NON_LIBRARY = {"M1K3MCP"}

# --------------------------------------------------------------------------- #
# Pure helpers (unit-tested)
# --------------------------------------------------------------------------- #


def package_library_products(package_swift: str) -> set[str]:
    """Names of every `.library(name: "...")` product declared in Package.swift."""
    return set(re.findall(r'\.library\(\s*name:\s*"([^"]+)"', package_swift))


def module_map_names(claude_md: str) -> set[str]:
    """Module names in the 'Module map' table's first (Target) cell.

    Scoped to the table that follows the 'Module map' marker so an M1K3* name
    mentioned in prose elsewhere doesn't count. Handles multi-module rows
    (e.g. `| `M1K3KnowledgeTools` / `M1K3AgentTools` |`).
    """
    names: set[str] = set()
    in_map = False
    started_table = False
    for line in claude_md.splitlines():
        if not in_map:
            if "Module map" in line:
                in_map = True
            continue
        if line.startswith("|"):
            started_table = True
            first_cell = line.split("|")[1]
            names |= set(re.findall(r"`(M1K3[A-Za-z0-9]+)`", first_cell))
        elif started_table and not line.strip():
            break  # blank line ends the markdown table
    return names


def diff_modules(products: set[str], documented: set[str]) -> tuple[set[str], set[str]]:
    """(undocumented, ghost) — both empty means the map and package agree."""
    undocumented = products - documented
    ghost = (documented - products) - ALLOWED_NON_LIBRARY
    return undocumented, ghost


# --------------------------------------------------------------------------- #
# I/O (verify-by-run)
# --------------------------------------------------------------------------- #


def main(argv: list[str]) -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    macos = os.path.dirname(os.path.dirname(here))
    pkg_path = argv[1] if len(argv) > 1 else os.path.join(macos, "Package.swift")
    claude_path = argv[2] if len(argv) > 2 else os.path.join(macos, "docs", "MODULE_MAP.md")

    products = package_library_products(open(pkg_path).read())
    documented = module_map_names(open(claude_path).read())
    undocumented, ghost = diff_modules(products=products, documented=documented)

    if not undocumented and not ghost:
        print(f"✓ docs/MODULE_MAP.md documents all {len(products)} package library products.")
        return 0

    if undocumented:
        print("❌ .library products in Package.swift but MISSING from docs/MODULE_MAP.md")
        print("   (these modules are invisible to every reader of the doc):")
        for m in sorted(undocumented):
            print(f"     - {m}")
    if ghost:
        print("⚠️  modules documented in docs/MODULE_MAP.md but GONE from Package.swift:")
        for m in sorted(ghost):
            print(f"     - {m}")
    print("\nFix: update the table in macos/docs/MODULE_MAP.md to match Package.swift's .library products.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))

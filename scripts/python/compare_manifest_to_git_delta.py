#!/usr/bin/env python3
"""
Compare manifest/package.xml to sfdx-git-delta constructive package/package.xml.

Exits 0 always; prints lines to stdout for bash:
  STATUS
  EXCESS_LINE   # semicolon-separated TYPE:Member or empty
  MISSING_LINE  # semicolon-separated TYPE:Member or empty

STATUS is one of: aligned, warning, error
"""
import sys
import xml.etree.ElementTree as ET
from typing import Dict, List, Set, Tuple

NS = "http://soap.sforce.com/2006/04/metadata"


def _q(tag: str) -> str:
    return f"{{{NS}}}{tag}"


def parse_package(path: str) -> Tuple[Dict[str, List[str]], Set[str]]:
    """Return (type -> members list) and set of types that use * wildcard."""
    tree = ET.parse(path)
    root = tree.getroot()
    out: Dict[str, List[str]] = {}
    star_types: Set[str] = set()
    for t in root.findall(_q("types")):
        name_el = t.find(_q("name"))
        if name_el is None or not name_el.text:
            continue
        tname = name_el.text.strip()
        members: List[str] = []
        for m in t.findall(_q("members")):
            if m.text and m.text.strip():
                txt = m.text.strip()
                if txt == "*":
                    star_types.add(tname)
                else:
                    members.append(txt)
        if members:
            out.setdefault(tname, []).extend(members)
    return out, star_types


def pairs_from_pkg(pkg: Dict[str, List[str]], star: Set[str]) -> Set[Tuple[str, str]]:
    s: Set[Tuple[str, str]] = set()
    for tname, members in pkg.items():
        if tname in star:
            continue
        for m in members:
            s.add((tname, m))
    return s


def fmt_pairs(pairs: Set[Tuple[str, str]], limit: int = 40) -> str:
    if not pairs:
        return ""
    items = sorted(f"{a}:{b}" for a, b in pairs)
    if len(items) > limit:
        return "; ".join(items[:limit]) + f"; … (+{len(items) - limit} more)"
    return "; ".join(items)


def main() -> None:
    if len(sys.argv) != 3:
        print("error", file=sys.stdout)
        print("", file=sys.stdout)
        print("", file=sys.stdout)
        print(
            "usage: compare_manifest_to_git_delta.py <delta_package.xml> <manifest_package.xml>",
            file=sys.stderr,
        )
        sys.exit(2)

    delta_path, manifest_path = sys.argv[1], sys.argv[2]
    try:
        delta_pkg, delta_star = parse_package(delta_path)
        man_pkg, man_star = parse_package(manifest_path)
    except (ET.ParseError, OSError) as e:
        print("error", file=sys.stdout)
        print("", file=sys.stdout)
        print("", file=sys.stdout)
        print(str(e), file=sys.stderr)
        return

    delta_pairs = pairs_from_pkg(delta_pkg, delta_star)
    man_pairs = pairs_from_pkg(man_pkg, man_star)

    # Excess: declared in manifest but not in additive git delta
    excess = set()
    for pair in man_pairs:
        if pair not in delta_pairs:
            excess.add(pair)

    # Missing: in delta but not covered by manifest (ignore types fully wildcarded in manifest)
    missing = set()
    for pair in delta_pairs:
        t, _ = pair
        if t in man_star:
            continue
        if pair not in man_pairs:
            missing.add(pair)

    if excess or missing:
        print("warning", file=sys.stdout)
        print(fmt_pairs(excess), file=sys.stdout)
        print(fmt_pairs(missing), file=sys.stdout)
    else:
        print("aligned", file=sys.stdout)
        print("", file=sys.stdout)
        print("", file=sys.stdout)


if __name__ == "__main__":
    main()

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
from typing import Dict, Iterable, List, Set, Tuple

NS = "http://soap.sforce.com/2006/04/metadata"

# Salesforce metadata-type names are treated case-insensitively by the Metadata API
# (e.g. GenAIPromptTemplate vs GenAiPromptTemplate are accepted as the same type),
# but tools disagree on the canonical casing. sfdx-git-delta uses the casing from
# metadataRegistry.json while developers often follow the casing in Salesforce docs.
# Normalize on the type name so we don't false-flag the same member twice.
def _norm_type(tname: str) -> str:
    return tname.lower()


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


def pairs_from_pkg(
    pkg: Dict[str, List[str]], star: Set[str]
) -> Dict[Tuple[str, str], str]:
    """Return {(type_lower, member) -> "OriginalType:Member"} for case-insensitive
    set ops on the key while preserving the package's original casing for display."""
    star_norm = {_norm_type(s) for s in star}
    out: Dict[Tuple[str, str], str] = {}
    for tname, members in pkg.items():
        if _norm_type(tname) in star_norm:
            continue
        for m in members:
            key = (_norm_type(tname), m)
            # First write wins; both packages within themselves should already be
            # internally consistent on casing, so this is fine.
            out.setdefault(key, f"{tname}:{m}")
    return out


def fmt_pairs(displays: Iterable[str], limit: int = 40) -> str:
    items = sorted(displays)
    if not items:
        return ""
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

    delta_map = pairs_from_pkg(delta_pkg, delta_star)
    man_map = pairs_from_pkg(man_pkg, man_star)

    delta_keys = set(delta_map.keys())
    man_keys = set(man_map.keys())
    man_star_norm = {_norm_type(s) for s in man_star}

    # Excess: declared in manifest but not in additive git delta.
    # Use the manifest's display casing so the MR comment matches what the dev wrote.
    excess_displays = {man_map[k] for k in (man_keys - delta_keys)}

    # Missing: in delta but not covered by manifest. Skip types fully wildcarded
    # in the manifest. Use the delta's display casing (it's what sgd would suggest).
    missing_displays = {
        delta_map[k] for k in (delta_keys - man_keys) if k[0] not in man_star_norm
    }

    if excess_displays or missing_displays:
        print("warning", file=sys.stdout)
        print(fmt_pairs(excess_displays), file=sys.stdout)
        print(fmt_pairs(missing_displays), file=sys.stdout)
    else:
        print("aligned", file=sys.stdout)
        print("", file=sys.stdout)
        print("", file=sys.stdout)


if __name__ == "__main__":
    main()

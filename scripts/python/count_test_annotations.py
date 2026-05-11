"""
One-off audit script: count Apex classes and triggers that have a valid
``@tests:`` annotation as defined by ``scripts/python/package_check.py``.

Definitions (mirroring ``find_apex_tests`` / ``validate_tests``):

* A class is treated as a test class (and therefore EXCLUDED from this count)
  if its source contains ``@istest`` (case-insensitive).
* A non-test class or trigger has a *valid* ``@tests:`` annotation if:
    1. It contains at least one ``@tests:`` line (regex
       ``@tests\\s*:\\s*([^\\r\\n]+)``, case-insensitive), AND
    2. After cleaning, at least one referenced name resolves to an existing
       ``.cls`` file in ``force-app/main/default/classes/``.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

CLASSES_DIR = Path("force-app/main/default/classes")
TRIGGERS_DIR = Path("force-app/main/default/triggers")

TESTS_RE = re.compile(r"@tests\s*:\s*([^\r\n]+)", re.IGNORECASE)


def clean_names(test_line: str) -> list[str]:
    cleaned = re.sub(r"[\s,]+", " ", test_line.strip())
    out = []
    for name in cleaned.split():
        if name.lower().endswith(".cls"):
            name = name[:-4]
        out.append(name)
    return out


def existing_class_names() -> set[str]:
    return {
        f[:-4] for f in os.listdir(CLASSES_DIR) if f.endswith(".cls")
    }


def is_test_class(src: str) -> bool:
    return "@istest" in src.lower()


def annotation_status(src: str, valid_classes: set[str]) -> tuple[bool, bool]:
    """Return (has_annotation, has_valid_annotation)."""
    matches = TESTS_RE.findall(src)
    if not matches:
        return False, False
    for line in matches:
        for name in clean_names(line):
            if name in valid_classes:
                return True, True
    return True, False


def scan(paths: list[Path], valid_classes: set[str]) -> dict:
    total = 0
    excluded_test = 0
    with_annotation = 0
    with_valid_annotation = 0
    with_invalid_annotation_only = 0
    no_annotation = 0
    invalid_examples: list[str] = []
    missing_examples: list[str] = []

    for p in paths:
        try:
            src = p.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            src = p.read_text(encoding="utf-8", errors="replace")

        if p.suffix == ".cls" and is_test_class(src):
            excluded_test += 1
            continue

        total += 1
        has_ann, has_valid = annotation_status(src, valid_classes)
        if has_valid:
            with_valid_annotation += 1
            with_annotation += 1
        elif has_ann:
            with_annotation += 1
            with_invalid_annotation_only += 1
            if len(invalid_examples) < 10:
                invalid_examples.append(p.name)
        else:
            no_annotation += 1
            if len(missing_examples) < 10:
                missing_examples.append(p.name)

    return {
        "total": total,
        "excluded_test": excluded_test,
        "with_annotation": with_annotation,
        "with_valid_annotation": with_valid_annotation,
        "with_invalid_annotation_only": with_invalid_annotation_only,
        "no_annotation": no_annotation,
        "invalid_examples": invalid_examples,
        "missing_examples": missing_examples,
    }


def main() -> None:
    valid_classes = existing_class_names()

    cls_files = sorted(CLASSES_DIR.glob("*.cls"))
    trigger_files = sorted(TRIGGERS_DIR.glob("*.trigger"))

    print(f"Apex classes on disk:   {len(cls_files)}")
    print(f"Apex triggers on disk:  {len(trigger_files)}")
    print()

    cls_stats = scan(cls_files, valid_classes)
    trg_stats = scan(trigger_files, valid_classes)

    def report(label: str, stats: dict) -> None:
        print(f"== {label} ==")
        print(f"  excluded as test class (@isTest):    {stats['excluded_test']}")
        print(f"  non-test files evaluated:            {stats['total']}")
        print(f"  with any @tests: annotation:         {stats['with_annotation']}")
        print(f"  with VALID @tests: annotation:       {stats['with_valid_annotation']}")
        print(f"  with @tests: but no resolvable name: {stats['with_invalid_annotation_only']}")
        print(f"  with NO @tests: annotation:          {stats['no_annotation']}")
        if stats["invalid_examples"]:
            print(f"  sample invalid: {stats['invalid_examples']}")
        if stats["missing_examples"]:
            print(f"  sample missing: {stats['missing_examples']}")
        print()

    report("Apex classes (.cls)", cls_stats)
    report("Apex triggers (.trigger)", trg_stats)

    combined_valid = cls_stats["with_valid_annotation"] + trg_stats["with_valid_annotation"]
    combined_total = cls_stats["total"] + trg_stats["total"]
    print(f"COMBINED: {combined_valid} / {combined_total} non-test Apex files have a valid @tests: annotation")


if __name__ == "__main__":
    main()

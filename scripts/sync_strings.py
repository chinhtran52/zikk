#!/usr/bin/env python3
"""Regenerates each module's Localizable.xcstrings from L("...") call sites.

English is the source language; Vietnamese translations come from Localization/vi.json.
Keys without a Vietnamese translation are reported so they can be added.
Usage: scripts/sync_strings.py [--check]
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Packages/ZikkKit/Sources"
VI = json.loads((ROOT / "Localization/vi.json").read_text())
PATTERN = re.compile(r'\bL\("((?:[^"\\]|\\.)*)"\)')

missing = set()
interpolated = []
for module in sorted(p for p in SOURCES.iterdir() if (p / "Localization.swift").exists()):
    keys = set()
    for swift in module.rglob("*.swift"):
        keys.update(m.replace("\\\"", "\"").replace("\\\\", "\\") for m in PATTERN.findall(swift.read_text()))
    interpolated += [k for k in keys if "\\(" in k]
    strings = {}
    for key in sorted(keys):
        entry = {"extractionState": "manual", "generatesSymbol": False}
        if key in VI:
            entry["localizations"] = {"vi": {"stringUnit": {"state": "translated", "value": VI[key]}}}
        else:
            missing.add(key)
        strings[key] = entry
    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    out = module / "Resources/Localizable.xcstrings"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

if interpolated:
    print("L() keys must not use string interpolation; use String(format: L(\"… %lld …\"), value):")
    for key in sorted(interpolated):
        print(f"  {key!r}")
    sys.exit(1)

if missing:
    print("Missing Vietnamese translations:")
    for key in sorted(missing):
        print(f"  {key!r}")
    if "--check" in sys.argv:
        sys.exit(1)

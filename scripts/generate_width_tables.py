#!/usr/bin/env python3
"""Emits CharacterWidthTables.swift from Unicode Character Database files.

Takes one argument: a directory containing EastAsianWidth.txt and
DerivedGeneralCategory.txt. Writes Swift source to stdout.
"""
import sys
import os


def parse(path, wanted):
    ranges = []
    for line in open(path, encoding="utf-8"):
        line = line.split("#")[0].strip()
        if not line:
            continue
        cps, _, prop = line.partition(";")
        if prop.strip() not in wanted:
            continue
        cps = cps.strip()
        lo, _, hi = cps.partition("..")
        hi = hi or lo
        ranges.append((int(lo, 16), int(hi, 16)))
    ranges.sort()
    merged = []
    for lo, hi in ranges:
        if merged and lo <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], hi))
        else:
            merged.append((lo, hi))
    return merged


def version_of(path):
    with open(path, encoding="utf-8") as handle:
        first = handle.readline().strip()
    return first.lstrip("# ").strip()


def emit(name, ranges, doc):
    print(doc)
    print(f"let {name}: [ClosedRange<UInt32>] = [")
    line = "    "
    for lo, hi in ranges:
        item = f"0x{lo:04X}...0x{hi:04X}, "
        if len(line) + len(item) > 96:
            print(line.rstrip())
            line = "    "
        line += item
    if line.strip():
        print(line.rstrip().rstrip(","))
    print("]")
    print()


def main():
    directory = sys.argv[1]
    eaw = os.path.join(directory, "EastAsianWidth.txt")
    gc = os.path.join(directory, "DerivedGeneralCategory.txt")

    print("// Generated from the Unicode Character Database. Do not edit by hand.")
    print("//")
    print("// Source files, both from https://www.unicode.org/Public/UCD/latest/ucd/ :")
    print(f"//   {version_of(eaw)}")
    print(f"//   {version_of(gc)}")
    print("//")
    print("// Regenerate with `scripts/generate-width-tables.sh`.")
    print("//")
    print("// Cell width is a rendering decision, not a Unicode property, so these tables encode a")
    print("// policy: East Asian Wide and Fullwidth occupy two cells; non-spacing and enclosing")
    print("// marks occupy none, because they compose onto the preceding character. Everything else")
    print("// occupies one. This matches what `wcwidth(3)` does, which is what remote programs")
    print("// assume when they lay out their own output.")
    print()
    emit(
        "eastAsianWideRanges",
        parse(eaw, {"W", "F"}),
        "/// Code points whose East Asian Width is Wide (W) or Fullwidth (F).",
    )
    emit(
        "zeroWidthMarkRanges",
        parse(gc, {"Mn", "Me"}),
        "/// Non-spacing (Mn) and enclosing (Me) marks, which add no cells of their own.",
    )


if __name__ == "__main__":
    main()

#!/usr/bin/env bash
# Lists interface strings that have no Ukrainian translation, and translations
# that are no longer used. The compiler extracts every LocalizedStringKey.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# A clean build, so every source file is compiled and no stale output is counted.
rm -rf .build/strings
swift build --product MacCleaner --scratch-path .build/strings \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null
# The Command Line Tools write .stringsdata to $OUT; Xcode's build system keeps
# them next to the object files.
find .build/strings -name '*.stringsdata' -exec cp {} "$OUT/" \;

python3 - "$OUT" Resources/Localization/uk.lproj/Localizable.strings <<'PY'
import glob, json, subprocess, sys

out_dir, strings_path = sys.argv[1], sys.argv[2]
used = set()
for path in glob.glob(f"{out_dir}/*.stringsdata"):
    for entries in json.load(open(path)).get("tables", {}).values():
        used.update(e["key"] for e in entries)

# .strings is an old-style plist; plutil converts it to JSON.
translated = set(json.loads(subprocess.check_output(
    ["plutil", "-convert", "json", "-o", "-", strings_path])).keys())

missing, unused = sorted(used - translated), sorted(translated - used)
for key in missing:
    print(f"missing: {key!r}")
for key in unused:
    print(f"unused:  {key!r}")
print(f"{len(used)} strings, {len(missing)} missing, {len(unused)} unused")
sys.exit(1 if missing else 0)
PY

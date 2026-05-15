#!/usr/bin/env bash
# Verify all three reference apps pin the same bithuman-sdk-public
# version, and that they match version.yml at the repo root.
#
# Why: each app declares its SwiftPM dependency in a different file
# format (Package.swift literal for expression/mac/, xcodegen YAML for
# expression/ipad/ and archive/iPhone/). There's no auto-propagation.
# version.yml is the human-edited source of truth; this script is the
# CI guardrail that fails when someone bumps the version in two files
# but forgets the third.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f version.yml ]]; then
    echo "::error::version.yml is missing at repo root."
    exit 1
fi

# Strict-but-portable parse: pick the `version: "X.Y.Z"` line under the
# `bithuman-sdk-public:` key. We don't take a YAML library dep for
# something this small.
expected=$(awk '
    /^bithuman-sdk-public:/ { in_block = 1; next }
    in_block && /^[[:space:]]+version:/ {
        gsub(/[",]/, "", $2)
        print $2
        exit
    }
' version.yml)

if [[ -z "$expected" ]]; then
    echo "::error::Could not parse version.yml — expected bithuman-sdk-public.version key."
    exit 1
fi

echo "version.yml says bithuman-sdk-public version = $expected"
echo

# Each entry is FILE:GREP_PATTERN. The pattern must capture the version
# in group 1; we extract it and compare.
declare -a checks=(
    "expression/mac/Package.swift|from:[[:space:]]*\"([0-9]+\.[0-9]+\.[0-9]+)\""
    "expression/ipad/App/project.yml|^[[:space:]]+from:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)"
    "archive/iPhone/App/project.yml|^[[:space:]]+from:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)"
)

mismatches=0
for entry in "${checks[@]}"; do
    file="${entry%%|*}"
    pattern="${entry#*|}"

    if [[ ! -f "$file" ]]; then
        echo "::error file=$file::file missing"
        mismatches=$((mismatches + 1))
        continue
    fi

    found=$(grep -E "$pattern" "$file" | head -1 | sed -E "s/.*$pattern.*/\1/")
    if [[ -z "$found" ]]; then
        echo "::error file=$file::could not extract bithuman-sdk-public version (no line matched /$pattern/)"
        mismatches=$((mismatches + 1))
        continue
    fi

    if [[ "$found" == "$expected" ]]; then
        printf '  %-30s %s  OK\n' "$file" "$found"
    else
        printf '  %-30s %s  MISMATCH (expected %s)\n' "$file" "$found" "$expected"
        echo "::error file=$file::pinned bithuman-sdk-public version $found does not match version.yml ($expected)"
        mismatches=$((mismatches + 1))
    fi
done

echo
if [[ $mismatches -gt 0 ]]; then
    echo "$mismatches file(s) out of sync with version.yml. Fix the files OR bump version.yml."
    exit 1
fi

echo "All app pins are in sync with version.yml at $expected."

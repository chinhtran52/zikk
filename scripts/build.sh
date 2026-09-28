#!/bin/zsh
# Compact package build/test output: prints only unique error lines (or the tail on success).
cd "$(dirname $0)/../Packages/ZikkKit"
cmd=${1:-build}; shift
out=$(swift $cmd "$@" 2>&1); code=$?
if [[ $code -ne 0 ]]; then
  print -r -- "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E "^/.*(error|warning): |✘|failed|Test .* recorded an issue" | grep -v "Failed frontend" | sort -u | head -60
else
  print -r -- "$out" | tail -${TAIL:-8}
fi
exit $code

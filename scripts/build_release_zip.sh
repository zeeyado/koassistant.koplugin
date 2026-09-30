#!/bin/sh
# Build a release zip the way .github/workflows/release.yml does: the ref's
# tracked files (the workflow's checkout), the same excluded folders, one
# koassistant.koplugin/ folder at the top. tests/unit/test_release_zip.lua keeps
# the exclude list below equal to the workflow's.
#
#   scripts/build_release_zip.sh <git-ref> <out.zip> [version]
#
# [version] rewrites the version in _meta.lua. Only the updater tester passes
# it (tests/tools/updater_e2e.sh), to offer an update from a build; a release
# build never does, since the updater requires _meta.lua to equal the tag.
set -eu

if [ $# -lt 2 ]; then
    echo "usage: $0 <git-ref> <out.zip> [version]" >&2
    exit 2
fi
ref=$1
out=$2
stamp=${3:-}

root=$(git rev-parse --show-toplevel)
case $out in /*) ;; *) out=$(pwd)/$out ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/koa_zip.XXXXXX")
trap 'rm -rf "$work"' EXIT

mkdir "$work/src"
git -C "$root" archive --format=tar "$ref" | tar -x -C "$work/src"

mkdir -p "$work/build/koassistant.koplugin"
# release.yml's exclude list (keep equal; the unit test compares them)
rsync -a --exclude='.git' \
         --exclude='.github' \
         --exclude='.claude' \
         --exclude='build' \
         --exclude='docs' \
         --exclude='tests' \
         --exclude='scripts' \
         --exclude='hooks' \
         --exclude='screenshots' \
         --exclude='.gitignore' \
         "$work/src/" "$work/build/koassistant.koplugin/"

if [ -n "$stamp" ]; then
    meta="$work/build/koassistant.koplugin/_meta.lua"
    sed "s/version = \"[^\"]*\"/version = \"$stamp\"/" "$meta" > "$meta.new"
    mv "$meta.new" "$meta"
    grep -q "version = \"$stamp\"" "$meta" || { echo "could not stamp $stamp" >&2; exit 1; }
fi

(cd "$work/build" && zip -qr koassistant.koplugin.zip koassistant.koplugin)
mv "$work/build/koassistant.koplugin.zip" "$out"
echo "$out"

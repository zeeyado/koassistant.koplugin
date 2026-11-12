#!/bin/sh
# Build the release zip: the ref's tracked files minus the excluded folders
# below, one koassistant.koplugin/ folder at the top. .github/workflows/release.yml
# runs this very script, so the zip the updater tester installs
# (tests/tools/updater_e2e.sh) is the zip readers download.
#
#   scripts/build_release_zip.sh <git-ref> <out.zip> [version]
#
# [version] rewrites the version in _meta.lua. Only the updater tester passes
# it, to offer an update from a build; a release build never does, since the
# updater requires _meta.lua to equal the tag.
#
# While scripts/release_shims.txt exists in the ref (v0.24.0 and v0.25.0, B481), the zip
# also carries a one-line file at every path a module had before the layout
# change, returning the module at its new one: a plugin still running from
# memory after the update loads modules by their old names until the restart.
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
# the exclude list (tests/unit/test_release_zip.lua checks it)
rsync -a --exclude='.git' \
         --exclude='.github' \
         --exclude='.claude' \
         --exclude='build' \
         --exclude='docs' \
         --exclude='tests' \
         --exclude='scripts' \
         --exclude='hooks' \
         --exclude='screenshots' \
         --exclude='wiki' \
         --exclude='*.pot' \
         --exclude='.luacheckrc' \
         --exclude='OWNER' \
         --exclude='.gitignore' \
         --exclude='.git-blame-ignore-revs' \
         "$work/src/" "$work/build/koassistant.koplugin/"

# transitional shims (see the header): "<old path> <module id>" per line, comments with #
shims="$work/src/scripts/release_shims.txt"
if [ -f "$shims" ]; then
    n=0
    while IFS=' ' read -r old new; do
        case $old in ''|'#'*) continue ;; esac
        dest="$work/build/koassistant.koplugin/$old"
        [ -e "$dest" ] && { echo "shim target exists in the tree: $old" >&2; exit 1; }
        mkdir -p "$(dirname "$dest")"
        printf -- '-- Transitional: this module moved to %s. A plugin still running from memory\n-- after an update loads it by this name until the restart.\nreturn require("%s")\n' "$new" "$new" > "$dest"
        n=$((n + 1))
    done < "$shims"
    echo "shims: $n" >&2
fi

if [ -n "$stamp" ]; then
    meta="$work/build/koassistant.koplugin/_meta.lua"
    sed "s/version = \"[^\"]*\"/version = \"$stamp\"/" "$meta" > "$meta.new"
    mv "$meta.new" "$meta"
    grep -q "version = \"$stamp\"" "$meta" || { echo "could not stamp $stamp" >&2; exit 1; }
fi

(cd "$work/build" && zip -qr koassistant.koplugin.zip koassistant.koplugin)
mv "$work/build/koassistant.koplugin.zip" "$out"
echo "$out"

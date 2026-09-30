#!/bin/sh
# The updater tester (B379). Each case installs a release zip with the updater
# a reader has installed, through its real Update Now code (updater_e2e.lua
# under KOReader's LuaJIT), then checks what the reader is left with:
#   - a good update: exactly the zip's files plus every user file byte for
#     byte, nothing left beside the plugin folder, every .lua loading, and the
#     restart message with no "Note:";
#   - an update that must fail: the old install untouched and nothing left
#     beside it.
# Readers update with the version they have installed, so a fix to the updater
# reaches them one release late: both the last release's updater (the one that
# installs this release) and this tree's (the one that installs the next) run.
#
#   tests/tools/updater_e2e.sh              development: HEAD is stamped as the
#                                           next release
#   tests/tools/updater_e2e.sh v0.23.0      before tagging (release recipe):
#                                           HEAD's _meta.lua must read 0.23.0
#
# KOREADER_DIR (default /Applications/KOReader.app/Contents/koreader) is the
# KOReader whose LuaJIT and archive code run the updater. KEEP=1 keeps the work
# folder. Nothing outside a fresh temp folder is touched.
set -eu

KO=${KOREADER_DIR:-/Applications/KOReader.app/Contents/koreader}
root=$(git rev-parse --show-toplevel)
tag=${1:-}
last=$(git -C "$root" describe --tags --abbrev=0 HEAD)
last_version=${last#v}

head_meta=$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' "$root/_meta.lua" | head -1)
if [ -n "$tag" ]; then
    new=${tag#v}
    [ "$head_meta" = "$new" ] || { echo "FAIL: _meta.lua reads $head_meta, the release is $new (bump it first)"; exit 1; }
    new_stamp=""
else
    new=${head_meta%-dev}
    new_stamp=$new
fi
next="${new%.*}.$(( ${new##*.} + 1 ))"

work=$(mktemp -d "${TMPDIR:-/tmp}/koa_upd.XXXXXX")
cleanup() {
    if [ "${KEEP:-}" = 1 ]; then echo "work folder kept: $work"; return; fi
    case $work in "${TMPDIR:-/tmp}"/koa_upd.*) rm -rf "$work" ;; esac
}
trap cleanup EXIT

# This tree: the working tree's tracked files, uncommitted changes included
# (git stash create snapshots them without touching the stash or the files)
src=$(git -C "$root" stash create)
if [ -n "$src" ]; then src_label="the working tree (uncommitted changes)"; else src=HEAD; src_label="HEAD"; fi

echo "updater tester: $last ($last_version) -> $new, then $new -> $next; this tree = $src_label"
echo "building zips..."
sh "$root/scripts/build_release_zip.sh" "$last" "$work/last.zip" >/dev/null
sh "$root/scripts/build_release_zip.sh" "$src" "$work/head_new.zip" "$new_stamp" >/dev/null
sh "$root/scripts/build_release_zip.sh" "$src" "$work/head_next.zip" "$next" >/dev/null
[ -n "$tag" ] || sh "$root/scripts/build_release_zip.sh" "$src" "$work/head_unbumped.zip" >/dev/null

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }

# A fresh plugins folder holding <zip>'s plugin plus a reader's own files
install_fixture() { # <dir> <zip>
    mkdir -p "$1/plugins" "$1/settings"
    (cd "$1/plugins" && unzip -q "$2")
    p="$1/plugins/koassistant.koplugin"
    printf 'return { anthropic = "not-a-real-key" }\n' > "$p/apikeys.lua"
    printf -- '-- tester configuration\nreturn { features = {} }\n' > "$p/configuration.lua"
    printf -- '-- tester actions\nreturn {}\n' > "$p/custom_actions.lua"
    printf -- '-- tester models\nreturn {}\n' > "$p/custom_models.lua"
    mkdir -p "$p/behaviors" "$p/domains"
    printf 'Tester behavior.\n' > "$p/behaviors/tester.md"
    printf 'Tester domain.\n' > "$p/domains/tester.md"
    # Not the reader's to keep: an unregistered file and a module the new
    # release no longer has
    printf 'scratch\n' > "$p/notes.txt"
    printf 'return {}\n' > "$p/koassistant_obsolete.lua"
}

# The tree a good update leaves: the zip's files plus the user files
expected_tree() { # <dir> <zip> <fixture_plugin>
    mkdir -p "$1"
    (cd "$1" && unzip -q "$2")
    e="$1/koassistant.koplugin"
    for f in apikeys.lua configuration.lua custom_actions.lua custom_models.lua; do cp "$3/$f" "$e/$f"; done
    cp -R "$3/behaviors" "$e/behaviors"
    cp -R "$3/domains" "$e/domains"
}

run_update() { # <dir> <zip> <version> [size] [sha256]
    (cd "$KO" && ./luajit "$root/tests/tools/updater_e2e.lua" "$1/plugins" "$2" "$3" "$1/settings" "${4:-}" "${5:-}") \
        > "$1/out.txt" 2>&1 || true
}

leftovers() { # <dir>: anything beside the plugin folder
    ls -A "$1/plugins" | grep -v '^koassistant\.koplugin$' || true
}

lua_loads() { # <plugin dir>
    find "$1" -name '*.lua' | (cd "$KO" && ./luajit -e 'local n=0 for f in io.lines() do assert(loadfile(f)); n=n+1 end io.write(n)')
}

expect_success() { # <name> <installed_zip> <zip> <version> [symlink]
    name=$1
    d="$work/$name"
    install_fixture "$d" "$2"
    fixture="$d/plugins/koassistant.koplugin"
    if [ "${5:-}" = symlink ]; then
        # The reader keeps domains/ elsewhere and links it in
        mkdir -p "$d/elsewhere"
        mv "$fixture/domains" "$d/elsewhere/domains"
        ln -s "$d/elsewhere/domains" "$fixture/domains"
    fi
    cp -R "$fixture" "$d/before"
    size=$(wc -c < "$3" | tr -d ' ')
    sha=$(shasum -a 256 "$3" | cut -d' ' -f1)
    run_update "$d" "$3" "$4" "$size" "$sha"
    if ! grep -q "^MSG restart: KOAssistant updated to version $4" "$d/out.txt"; then
        bad "$name: no success message"; sed 's/^/       /' "$d/out.txt" | grep -v DEBUG | tail -8; return
    fi
    if grep -q "Note:" "$d/out.txt"; then bad "$name: the restart message carries a Note"; return; fi
    lo=$(leftovers "$d")
    [ -z "$lo" ] || { bad "$name: left beside the plugin: $lo"; return; }
    expected_tree "$d/expected" "$3" "$d/before"
    if [ "${5:-}" = symlink ]; then
        [ -f "$d/elsewhere/domains/tester.md" ] || { bad "$name: the linked domains folder was emptied"; return; }
    fi
    if ! diff -r "$d/expected/koassistant.koplugin" "$fixture" > "$d/diff.txt" 2>&1; then
        bad "$name: installed tree differs from the zip plus user files"; head -8 "$d/diff.txt" | sed 's/^/       /'; return
    fi
    n=$(lua_loads "$fixture") || { bad "$name: a .lua file does not load"; return; }
    ok "$name ($n .lua files load, user files byte-identical, nothing left over)"
}

expect_failure() { # <name> <installed_zip> <zip> <version> <message> [size] [sha256]
    name=$1
    d="$work/$name"
    install_fixture "$d" "$2"
    fixture="$d/plugins/koassistant.koplugin"
    cp -R "$fixture" "$d/before"
    run_update "$d" "$3" "$4" "${6:-}" "${7:-}"
    if ! grep -q "^MSG info: Update failed" "$d/out.txt"; then
        bad "$name: no failure message"; sed 's/^/       /' "$d/out.txt" | grep -v DEBUG | tail -8; return
    fi
    grep -q "$5" "$d/out.txt" || { bad "$name: failure does not say \"$5\""; grep '^MSG' "$d/out.txt" | sed 's/^/       /'; return; }
    diff -r "$d/before" "$fixture" > /dev/null 2>&1 || { bad "$name: the old install changed"; return; }
    lo=$(leftovers "$d")
    [ -z "$lo" ] || { bad "$name: left beside the plugin: $lo"; return; }
    ok "$name (old install untouched, nothing left over)"
}

expect_refusal() { # <name> <installed_zip> <zip> <version>: a git checkout (.git is a file in a worktree)
    name=$1
    d="$work/$name"
    install_fixture "$d" "$2"
    fixture="$d/plugins/koassistant.koplugin"
    printf 'gitdir: /elsewhere/.git/worktrees/koassistant\n' > "$fixture/.git"
    cp -R "$fixture" "$d/before"
    run_update "$d" "$3" "$4"
    grep -q "^MSG info: Auto-update is disabled for git-based installs" "$d/out.txt" \
        || { bad "$name: no refusal"; grep '^MSG' "$d/out.txt" | sed 's/^/       /'; return; }
    diff -r "$d/before" "$fixture" > /dev/null 2>&1 || { bad "$name: the checkout changed"; return; }
    lo=$(leftovers "$d")
    [ -z "$lo" ] || { bad "$name: left beside the plugin: $lo"; return; }
    ok "$name (checkout untouched)"
}

echo "the update readers will make ($last's updater):"
expect_success "last-installs-new" "$work/last.zip" "$work/head_new.zip" "$new"
[ -n "$tag" ] || expect_failure "last-rejects-unbumped" "$work/last.zip" "$work/head_unbumped.zip" "$new" "Version mismatch"

echo "the next update (this tree's updater):"
expect_success "new-installs-next" "$work/head_new.zip" "$work/head_next.zip" "$next"
expect_success "new-keeps-linked-domains" "$work/head_new.zip" "$work/head_next.zip" "$next" symlink
expect_refusal "new-refuses-git-worktree" "$work/head_new.zip" "$work/head_next.zip" "$next"

# Damaged downloads, installed by this tree's updater
head -c 3000000 "$work/head_next.zip" > "$work/cut.zip"
dd if=/dev/urandom of="$work/garbage.zip" bs=1024 count=512 2>/dev/null
mkdir -p "$work/flat" && (cd "$work/flat" && unzip -q "$work/head_next.zip" && cd koassistant.koplugin && zip -qr "$work/no_top_folder.zip" .)
mkdir -p "$work/nometa" && (cd "$work/nometa" && unzip -q "$work/head_next.zip" && rm koassistant.koplugin/_meta.lua && zip -qr "$work/no_meta.zip" koassistant.koplugin)
next_size=$(wc -c < "$work/head_next.zip" | tr -d ' ')
expect_failure "new-rejects-cut-download" "$work/head_new.zip" "$work/cut.zip" "$next" "incomplete" "$next_size"
expect_failure "new-rejects-damaged-download" "$work/head_new.zip" "$work/head_next.zip" "$next" "damaged" "$next_size" "0000000000000000000000000000000000000000000000000000000000000000"
expect_failure "new-rejects-garbage" "$work/head_new.zip" "$work/garbage.zip" "$next" "extract"
expect_failure "new-rejects-no-top-folder" "$work/head_new.zip" "$work/no_top_folder.zip" "$next" "_meta.lua not found"
expect_failure "new-rejects-no-meta" "$work/head_new.zip" "$work/no_meta.zip" "$next" "_meta.lua not found"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

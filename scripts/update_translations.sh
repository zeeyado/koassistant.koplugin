#!/bin/bash
# Update translation files for KOAssistant
# Run this after modifying translatable strings in the codebase
#
# Usage: ./scripts/update_translations.sh
#
# What it does:
# 1. Regenerates locale/koassistant.pot from source files
# 2. Merges new strings into each language's .po file
# 3. Reports what changed

# Get script directory and plugin root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PLUGIN_DIR"

echo "=== KOAssistant Translation Updater ==="
echo ""

# Check for required tools
if ! command -v xgettext &> /dev/null; then
    echo "Error: xgettext not found. Install gettext package."
    echo "  Ubuntu/Debian: sudo apt install gettext"
    echo "  macOS: brew install gettext"
    exit 1
fi

if ! command -v msgmerge &> /dev/null; then
    echo "Error: msgmerge not found. Install gettext package."
    exit 1
fi

# Get version from _meta.lua (macOS-compatible)
VERSION=$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' _meta.lua 2>/dev/null)
VERSION=${VERSION:-0.0.0}
echo "Plugin version: $VERSION"
echo ""

# Step 1: Regenerate .pot file
echo "Step 1: Extracting translatable strings..."
if ! xgettext --from-code=UTF-8 -L Lua \
    --package-name="KOAssistant" \
    --package-version="$VERSION" \
    --msgid-bugs-address="https://github.com/zeeyado/koassistant.koplugin/issues" \
    --copyright-holder="zeeyado" \
    -o locale/koassistant.pot \
    *.lua koassistant_ui/*.lua prompts/*.lua 2>/dev/null; then
    echo "Error: xgettext failed"
    exit 1
fi

# Count strings in .pot
POT_COUNT=$(grep -c "^msgid " locale/koassistant.pot 2>/dev/null || echo "0")
echo "  Found $POT_COUNT translatable strings"
echo ""

# Step 2: Update each language
echo "Step 2: Updating language files..."
LANGUAGES="ar zh es pt pt_BR fr de it ru ja pl tr ko_KR vi id th nl_NL cs uk hi"

for lang in $LANGUAGES; do
    PO_FILE="locale/$lang/LC_MESSAGES/koassistant.po"

    if [ -f "$PO_FILE" ]; then
        # Merge with .pot (-N disables fuzzy matching, only exact matches)
        if ! msgmerge -U -N --backup=none "$PO_FILE" locale/koassistant.pot 2>/dev/null; then
            echo "  $lang: msgmerge failed, skipping"
            continue
        fi

        # Remove obsolete entries (count msgid lines only, not msgstr)
        OBSOLETE=$(grep -c "^#~ msgid" "$PO_FILE" || true)
        if [ "$OBSOLETE" -gt 0 ]; then
            msgattrib --no-obsolete -o "$PO_FILE" "$PO_FILE"
        fi

        # Get counts after merge (exclude header by matching non-empty msgid)
        AFTER_FUZZY=$(grep -c "^#, fuzzy" "$PO_FILE" || true)
        UNTRANSLATED=$(msgattrib --untranslated "$PO_FILE" 2>/dev/null | grep -c '^msgid "[^"]' || true)

        echo "  $lang: fuzzy=$AFTER_FUZZY, empty=$UNTRANSLATED, removed=$OBSOLETE"
    else
        echo "  $lang: file not found, skipping"
    fi
done

echo ""
echo "=== Done ==="
echo ""
echo "Next steps:"
echo "  1. Review changes: git diff locale/"
echo "  2. Commit: git add locale/ && git commit -m 'Update translation strings'"
echo "  3. Push to remote"

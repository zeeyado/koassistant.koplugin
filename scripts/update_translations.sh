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

# Save old strings for comparison
OLD_STRINGS=$(grep '^msgid "' locale/koassistant.pot 2>/dev/null | sort)

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

# Remove lua-format flags — xgettext detects T() placeholders (%1, %2) as Lua
# format specifiers, but they're not. False positives cause valid translations
# to be marked fuzzy.
sed -i '' '/^#, lua-format$/d' locale/koassistant.pot
sed -i '' 's/#, fuzzy, lua-format/#, fuzzy/' locale/koassistant.pot

# Count strings in .pot (subtract 1 for the header entry)
POT_COUNT=$(grep -c "^msgid " locale/koassistant.pot 2>/dev/null || echo "0")
POT_COUNT=$((POT_COUNT - 1))
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

        # Get counts after merge using msgfmt --statistics (handles multi-line msgids)
        STATS=$(msgfmt --statistics -o /dev/null "$PO_FILE" 2>&1)
        AFTER_FUZZY=$(echo "$STATS" | grep -o '[0-9]* fuzzy' | grep -o '[0-9]*' || echo "0")
        UNTRANSLATED=$(echo "$STATS" | grep -o '[0-9]* untranslated' | grep -o '[0-9]*' || echo "0")
        AFTER_FUZZY=${AFTER_FUZZY:-0}
        UNTRANSLATED=${UNTRANSLATED:-0}

        echo "  $lang: fuzzy=$AFTER_FUZZY, empty=$UNTRANSLATED, removed=$OBSOLETE"
    else
        echo "  $lang: file not found, skipping"
    fi
done

# Show new and removed strings
NEW_STRINGS=$(grep '^msgid "' locale/koassistant.pot 2>/dev/null | sort)
ADDED=$(comm -13 <(echo "$OLD_STRINGS") <(echo "$NEW_STRINGS") | sed 's/^msgid "//;s/"$//')
REMOVED=$(comm -23 <(echo "$OLD_STRINGS") <(echo "$NEW_STRINGS") | sed 's/^msgid "//;s/"$//')

if [ -n "$ADDED" ]; then
    echo ""
    echo "=== New strings ==="
    echo "$ADDED" | while read -r line; do echo "  + $line"; done
fi
if [ -n "$REMOVED" ]; then
    echo ""
    echo "=== Removed strings ==="
    echo "$REMOVED" | while read -r line; do echo "  - $line"; done
fi
if [ -z "$ADDED" ] && [ -z "$REMOVED" ]; then
    echo ""
    echo "No string changes."
fi

echo ""
echo "=== Done ==="
echo ""
echo "Next steps:"
echo "  1. Review changes: git diff locale/"
echo "  2. Commit: git add locale/ && git commit -m 'Update translation strings'"
echo "  3. Push to remote"

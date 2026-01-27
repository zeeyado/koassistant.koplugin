#!/bin/bash
# Apply translations from a TSV file to a .po file
# Usage: ./apply_translations.sh <lang_code> <translations.tsv>
#
# TSV format: msgid<TAB>msgstr (one per line)

LANG_CODE=$1
TSV_FILE=$2

if [ -z "$LANG_CODE" ] || [ -z "$TSV_FILE" ]; then
    echo "Usage: $0 <lang_code> <translations.tsv>"
    exit 1
fi

PO_FILE="locale/$LANG_CODE/LC_MESSAGES/koassistant.po"

if [ ! -f "$PO_FILE" ]; then
    echo "Error: $PO_FILE not found"
    exit 1
fi

if [ ! -f "$TSV_FILE" ]; then
    echo "Error: $TSV_FILE not found"
    exit 1
fi

echo "Applying translations from $TSV_FILE to $PO_FILE..."

# Use Python for reliable PO file manipulation (inline, no external deps)
python3 << PYEOF
import re
import sys

# Read translations
translations = {}
with open("$TSV_FILE", 'r', encoding='utf-8') as f:
    for line in f:
        line = line.rstrip('\n')
        if '\t' in line:
            parts = line.split('\t', 1)
            if len(parts) == 2:
                translations[parts[0]] = parts[1]

print(f"Loaded {len(translations)} translations")

# Read PO file
with open("$PO_FILE", 'r', encoding='utf-8') as f:
    content = f.read()

# Parse and update entries
lines = content.split('\n')
new_lines = []
i = 0
translated = 0

while i < len(lines):
    line = lines[i]
    
    # Look for msgid
    if line.startswith('msgid "'):
        msgid_lines = [line]
        i += 1
        
        # Collect multi-line msgid
        while i < len(lines) and lines[i].startswith('"'):
            msgid_lines.append(lines[i])
            i += 1
        
        # Extract msgid text
        msgid_text = ''
        for ml in msgid_lines:
            if ml.startswith('msgid "'):
                msgid_text += ml[7:-1]  # Remove 'msgid "' and trailing '"'
            else:
                msgid_text += ml[1:-1]  # Remove leading and trailing '"'
        
        # Unescape
        msgid_text = msgid_text.replace('\\n', '\n').replace('\\t', '\t').replace('\\"', '"')
        
        # Check for translation
        if msgid_text in translations:
            trans = translations[msgid_text]
            # Escape for PO format
            trans = trans.replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t')

            # Check if we need to add fuzzy marker BEFORE msgid
            # Look back to see if there's already a #, fuzzy or other flag
            if new_lines and not new_lines[-1].startswith('#, '):
                # Insert fuzzy marker before msgid lines
                new_lines.append('#, fuzzy')

            # Add msgid lines
            new_lines.extend(msgid_lines)

            # Skip any existing fuzzy marker (shouldn't be here but just in case)
            if i < len(lines) and lines[i].startswith('#, '):
                i += 1
            
            # Handle msgstr
            if i < len(lines) and lines[i].startswith('msgstr'):
                # Skip old msgstr
                while i < len(lines) and (lines[i].startswith('msgstr') or lines[i].startswith('"')):
                    i += 1
            
            # Write new msgstr
            if '\n' in translations[msgid_text]:
                # Multi-line translation
                new_lines.append('msgstr ""')
                for part in trans.split('\\n'):
                    if part:
                        new_lines.append(f'"{part}\\n"')
                    else:
                        new_lines.append('""')
            else:
                new_lines.append(f'msgstr "{trans}"')
            
            translated += 1
        else:
            # No translation, keep original
            new_lines.extend(msgid_lines)
    else:
        new_lines.append(line)
        i += 1

# Write back
with open("$PO_FILE", 'w', encoding='utf-8') as f:
    f.write('\n'.join(new_lines))

print(f"Applied {translated} translations to $PO_FILE")
PYEOF

echo "Done!"

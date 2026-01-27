#!/usr/bin/env python3
"""
KOAssistant PO File Translator
Reads translations from a JSON file and applies them to a .po file.
Usage: python3 translate_po.py <lang_code> <translations.json>
"""
import sys
import json
import re
import os

def escape_po_string(s):
    """Escape special characters for PO format"""
    s = s.replace('\\', '\\\\')
    s = s.replace('"', '\\"')
    s = s.replace('\n', '\\n')
    s = s.replace('\t', '\\t')
    return s

def read_translations(json_file):
    """Read translations from JSON file"""
    with open(json_file, 'r', encoding='utf-8') as f:
        return json.load(f)

def translate_po_file(lang_code, translations):
    """Apply translations to a .po file"""
    po_path = f"locale/{lang_code}/LC_MESSAGES/koassistant.po"
    
    if not os.path.exists(po_path):
        print(f"Error: {po_path} not found")
        return False
    
    with open(po_path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    translated_count = 0
    
    for msgid, msgstr in translations.items():
        # Find the msgid and replace its msgstr
        # Handle both single-line and multi-line msgids
        
        # For simple single-line entries
        escaped_msgid = re.escape(msgid)
        
        # Pattern for single-line: msgid "text"\nmsgstr ""
        pattern = rf'(msgid "{escaped_msgid}"\n)(msgstr "")'
        replacement = rf'\1#, fuzzy\nmsgstr "{escape_po_string(msgstr)}"'
        
        new_content, count = re.subn(pattern, replacement, content)
        if count > 0:
            content = new_content
            translated_count += count
            continue
        
        # For multi-line entries, try simpler approach
        if msgid in content:
            # This is a simplification - real implementation would need proper PO parsing
            pass
    
    # Write back
    with open(po_path, 'w', encoding='utf-8') as f:
        f.write(content)
    
    print(f"Applied {translated_count} translations to {po_path}")
    return True

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 translate_po.py <lang_code> <translations.json>")
        sys.exit(1)
    
    lang_code = sys.argv[1]
    json_file = sys.argv[2]
    
    translations = read_translations(json_file)
    translate_po_file(lang_code, translations)

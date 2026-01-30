#!/usr/bin/env python3
"""
KOAssistant Translation Tool

Usage:
    translate.py LANG                    # Show status (default)
    translate.py LANG check              # Validate existing translations
    translate.py LANG plan               # Show what would be translated + cost estimate
    translate.py LANG export             # Export for manual translation
    translate.py LANG import FILE        # Import manual translations
    translate.py LANG run                # Translate empty strings via API
    translate.py LANG run --redo-fuzzy   # Re-translate fuzzy strings
    translate.py LANG run --new-lang     # Translate all (new language)

Key behaviors:
- Verified translations are NEVER extracted or overwritten
- AI translations always get fuzzy markers
- Brand names and technical terms are validated programmatically
"""

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

# ============================================================================
# SINGLE SOURCE OF TRUTH - Edit these lists to add new providers/brands/terms
# ============================================================================

# MUST appear unchanged if in source - ERROR if missing
BRANDS = ["KOAssistant", "KOReader"]

# Should appear unchanged - WARNING if missing
PROVIDERS = [
    "Claude", "GPT", "OpenAI", "Anthropic", "DeepSeek", "Gemini",
    "Ollama", "Groq", "Mistral", "xAI", "OpenRouter", "Qwen",
    "Kimi", "Together", "Fireworks", "SambaNova", "Cohere", "Doubao"
]

# Keep as technical acronym - typically preserved in translations
TECH_TERMS = ["API"]

# NOTE: We previously had token/tokens/cache/streaming here, but those are
# user-facing UI terms that translators should adapt to their language.
# Only true technical identifiers that should never be translated go here.

# ============================================================================
# Language Configuration
# ============================================================================

LANGUAGE_NAMES = {
    "ar": "Arabic",
    "zh": "Chinese (Simplified)",
    "es": "Spanish",
    "pt": "Portuguese",
    "pt_BR": "Brazilian Portuguese",
    "fr": "French",
    "de": "German",
    "it": "Italian",
    "ru": "Russian",
    "ja": "Japanese",
    "pl": "Polish",
    "tr": "Turkish",
    "ko_KR": "Korean",
    "vi": "Vietnamese",
    "id": "Indonesian",
    "th": "Thai",
    "nl_NL": "Dutch",
    "cs": "Czech",
    "uk": "Ukrainian",
    "hi": "Hindi",
}

# ============================================================================
# Export Header Template (auto-generated from lists above)
# ============================================================================

def generate_export_header(lang_code: str, lang_name: str, count: int) -> str:
    """Generate context-aware export header with translation guidelines."""
    providers_line1 = ", ".join(PROVIDERS[:8])
    providers_line2 = ", ".join(PROVIDERS[8:])
    terms = ", ".join(TECH_TERMS)
    brands = ", ".join(BRANDS)

    return f"""# {lang_name} ({lang_code}) - {count} strings to translate
# Plugin: KOAssistant - AI assistant for KOReader e-reader
#
# OUTPUT FORMAT: Replace each English string with {lang_name} translation.
# Keep the number prefix (1. 2. 3.) and section headers (## Settings).
#
# Example:
#   Input:  1. Chat Settings
#   Output: 1. [translation in {lang_name}]
#
# NEVER TRANSLATE (keep exactly as written):
#   Brand: {brands}
#   Providers: {providers_line1},
#              {providers_line2}
#   Terms: {terms}
#
# PLACEHOLDERS: Keep %1, %2, %3 exactly (NEVER use %s, %d)
#
# TRANSLATE: Everything else - settings, actions, behaviors, messages
"""

# ============================================================================
# PO File Parsing (reused from existing code)
# ============================================================================

class POEntry:
    """Represents a single translation entry in a PO file."""
    def __init__(self):
        self.comments: List[str] = []
        self.references: List[str] = []
        self.flags: List[str] = []
        self.msgid: str = ""
        self.msgid_plural: str = ""
        self.msgstr: str = ""
        self.msgstr_plural: List[str] = []
        self.line_number: int = 0
        self.is_header: bool = False

    @property
    def is_fuzzy(self) -> bool:
        return "fuzzy" in self.flags

    @property
    def is_translated(self) -> bool:
        return bool(self.msgstr) and not self.is_header

    @property
    def is_verified(self) -> bool:
        """Verified = translated AND not fuzzy (human-approved)."""
        return self.is_translated and not self.is_fuzzy

    @property
    def is_empty(self) -> bool:
        """Empty = no translation yet."""
        return not self.msgstr and not self.is_header

    def get_group(self) -> str:
        """Determine which group this entry belongs to based on references."""
        # Check content-based groups first
        if self.msgid.startswith("KOAssistant:"):
            return "Gestures"

        if not self.references:
            return "General"

        ref = self.references[0].lower()

        if "prompts/actions.lua" in ref:
            return "Actions"
        elif "prompts/system_prompts.lua" in ref or "behavior" in ref:
            return "Behaviors"
        elif "settings_schema" in ref or "settings_manager" in ref:
            return "Settings"
        elif "chat_history" in ref:
            return "Chat History"
        elif "koassistant_ui/" in ref:
            return "UI Managers"
        elif "domain" in ref:
            return "Domains"
        elif "error" in self.msgid.lower() or "fail" in self.msgid.lower():
            return "Error Messages"
        else:
            return "General"


def parse_po_file(filepath: Path) -> List[POEntry]:
    """Parse a PO file and return list of POEntry objects."""
    entries = []
    current_entry = None
    current_field = None
    line_number = 0

    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            line_number += 1
            line = line.rstrip('\n')

            if not line.strip():
                if current_entry and (current_entry.msgid or current_entry.is_header):
                    entries.append(current_entry)
                current_entry = None
                current_field = None
                continue

            if current_entry is None:
                current_entry = POEntry()
                current_entry.line_number = line_number

            if line.startswith('#'):
                current_entry.comments.append(line)
                if line.startswith('#:'):
                    refs = line[2:].strip().split()
                    current_entry.references.extend(refs)
                elif line.startswith('#,'):
                    flags = line[2:].strip().split(',')
                    current_entry.flags.extend([f.strip() for f in flags])
                continue

            if line.startswith('msgid '):
                current_field = 'msgid'
                value = line[6:].strip()
                if value.startswith('"') and value.endswith('"'):
                    current_entry.msgid = unescape_po_string(value[1:-1])
                    if not current_entry.msgid and entries == []:
                        current_entry.is_header = True
                continue

            if line.startswith('msgid_plural '):
                current_field = 'msgid_plural'
                value = line[13:].strip()
                if value.startswith('"') and value.endswith('"'):
                    current_entry.msgid_plural = unescape_po_string(value[1:-1])
                continue

            if line.startswith('msgstr '):
                current_field = 'msgstr'
                value = line[7:].strip()
                if value.startswith('"') and value.endswith('"'):
                    current_entry.msgstr = unescape_po_string(value[1:-1])
                continue

            match = re.match(r'msgstr\[(\d+)\] "(.*)"', line)
            if match:
                idx = int(match.group(1))
                value = unescape_po_string(match.group(2))
                while len(current_entry.msgstr_plural) <= idx:
                    current_entry.msgstr_plural.append("")
                current_entry.msgstr_plural[idx] = value
                current_field = f'msgstr[{idx}]'
                continue

            if line.startswith('"') and line.endswith('"'):
                value = unescape_po_string(line[1:-1])
                if current_field == 'msgid':
                    current_entry.msgid += value
                elif current_field == 'msgid_plural':
                    current_entry.msgid_plural += value
                elif current_field == 'msgstr':
                    current_entry.msgstr += value
                elif current_field and current_field.startswith('msgstr['):
                    idx = int(current_field[7:-1])
                    current_entry.msgstr_plural[idx] += value
                continue

    if current_entry and (current_entry.msgid or current_entry.is_header):
        entries.append(current_entry)

    return entries


def unescape_po_string(s: str) -> str:
    """Unescape PO string escape sequences."""
    return s.replace('\\n', '\n').replace('\\t', '\t').replace('\\"', '"').replace('\\\\', '\\')


def escape_po_string(s: str) -> str:
    """Escape string for PO format."""
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t')


def format_msgstr_for_po(msgstr: str) -> List[str]:
    """Format msgstr for PO file (handles multi-line strings)."""
    if not msgstr:
        return ['msgstr ""']

    if '\n' in msgstr:
        lines = ['msgstr ""']
        parts = msgstr.split('\n')
        for i, part in enumerate(parts):
            if i < len(parts) - 1:
                lines.append(f'"{escape_po_string(part)}\\n"')
            else:
                if part:
                    lines.append(f'"{escape_po_string(part)}"')
        return lines
    else:
        return [f'msgstr "{escape_po_string(msgstr)}"']


def write_po_file(entries: List[POEntry], filepath: Path,
                  remove_fuzzy_for: Optional[Set[str]] = None,
                  add_fuzzy_for: Optional[Set[str]] = None):
    """Write entries back to a PO file with proper formatting."""
    remove_fuzzy_for = remove_fuzzy_for or set()
    add_fuzzy_for = add_fuzzy_for or set()

    with open(filepath, 'w', encoding='utf-8') as f:
        for i, entry in enumerate(entries):
            should_remove_fuzzy = entry.msgid in remove_fuzzy_for
            should_add_fuzzy = entry.msgid in add_fuzzy_for and not entry.is_verified

            wrote_fuzzy_line = False
            for comment in entry.comments:
                if comment.startswith('#,'):
                    flags = [fl.strip() for fl in comment[2:].split(',')]
                    if should_remove_fuzzy:
                        flags = [fl for fl in flags if fl != 'fuzzy']
                    if should_add_fuzzy and 'fuzzy' not in flags:
                        flags.append('fuzzy')
                    if flags:
                        f.write(f"#, {', '.join(flags)}\n")
                    wrote_fuzzy_line = True
                else:
                    f.write(comment + '\n')

            if should_add_fuzzy and not wrote_fuzzy_line:
                f.write('#, fuzzy\n')

            if '\n' in entry.msgid or len(entry.msgid) > 70:
                f.write('msgid ""\n')
                for part in entry.msgid.split('\n'):
                    escaped = escape_po_string(part)
                    if part != entry.msgid.split('\n')[-1]:
                        f.write(f'"{escaped}\\n"\n')
                    elif part:
                        f.write(f'"{escaped}"\n')
            else:
                f.write(f'msgid "{escape_po_string(entry.msgid)}"\n')

            if entry.msgid_plural:
                f.write(f'msgid_plural "{escape_po_string(entry.msgid_plural)}"\n')

            for line in format_msgstr_for_po(entry.msgstr):
                f.write(line + '\n')

            for idx, plural in enumerate(entry.msgstr_plural):
                f.write(f'msgstr[{idx}] "{escape_po_string(plural)}"\n')

            if i < len(entries) - 1:
                f.write('\n')


# ============================================================================
# Filtering and Status
# ============================================================================

def filter_entries(entries: List[POEntry], mode: str) -> List[POEntry]:
    """Filter entries based on extraction mode.

    Modes:
        'empty': Only empty strings (no translation yet) - DEFAULT
        'fuzzy': Only fuzzy strings (need quality improvement)
        'all': All strings EXCEPT verified (new language)

    IMPORTANT: Verified translations are NEVER included.
    """
    result = []
    for entry in entries:
        if entry.is_header or not entry.msgid:
            continue
        if entry.is_verified:
            continue

        if mode == 'empty' and entry.is_empty:
            result.append(entry)
        elif mode == 'fuzzy' and entry.is_fuzzy:
            result.append(entry)
        elif mode == 'all':
            result.append(entry)

    return result


def get_status(entries: List[POEntry]) -> dict:
    """Get translation status for entries."""
    translatable = [e for e in entries if e.msgid and not e.is_header]
    return {
        "total": len(translatable),
        "verified": len([e for e in translatable if e.is_verified]),
        "fuzzy": len([e for e in translatable if e.is_fuzzy]),
        "empty": len([e for e in translatable if e.is_empty]),
    }


# ============================================================================
# Validation (merged from validate_translations.py)
# ============================================================================

class ValidationResult:
    """Stores validation results."""
    def __init__(self):
        self.errors: List[str] = []
        self.warnings: List[str] = []

    def add_error(self, message: str, line: int = None):
        prefix = f"Line {line}: " if line else ""
        self.errors.append(f"{prefix}{message}")

    def add_warning(self, message: str, line: int = None):
        prefix = f"Line {line}: " if line else ""
        self.warnings.append(f"{prefix}{message}")

    @property
    def passed(self) -> bool:
        return len(self.errors) == 0


def validate_entry(entry: POEntry, result: ValidationResult):
    """Validate a single translation entry.

    For fuzzy strings, issues are warnings (expected to be fixed on retranslation).
    For verified strings, issues are errors (real problems).
    """
    msgid = entry.msgid
    msgstr = entry.msgstr

    if not msgid or not msgstr:
        return

    # Use warning for fuzzy (expected issues), error for verified (real problems)
    add_issue = result.add_warning if entry.is_fuzzy else result.add_error

    # 1. Placeholder count match
    for i in range(1, 10):
        pattern = f"%{i}"
        if msgid.count(pattern) != msgstr.count(pattern):
            add_issue(
                f"{pattern} count mismatch: source={msgid.count(pattern)}, translation={msgstr.count(pattern)}",
                entry.line_number
            )

    # 2. Wrong placeholder format
    if re.search(r'%[1-9]', msgid):
        wrong = re.findall(r'%[sdf]', msgstr)
        if wrong:
            add_issue(
                f"Wrong placeholder format: {wrong} (use %1, %2, etc.)",
                entry.line_number
            )

    # 3. Brand names (ERROR if missing, even for fuzzy)
    for brand in BRANDS:
        if brand in msgid and brand not in msgstr:
            add_issue(
                f"Brand '{brand}' must appear in translation",
                entry.line_number
            )

    # 4. Provider names (WARNING if missing)
    for provider in PROVIDERS:
        if provider in msgid and provider not in msgstr:
            result.add_warning(
                f"Provider '{provider}' should be preserved",
                entry.line_number
            )

    # 5. Technical terms (WARNING if missing)
    # Use simple substring check instead of word boundaries for CJK compatibility
    # (CJK languages don't have word boundaries, so "APIキー" wouldn't match \bAPI\b)
    for term in TECH_TERMS:
        if term.upper() in msgid.upper():
            if term.upper() not in msgstr.upper():
                result.add_warning(
                    f"Technical term '{term}' should be preserved",
                    entry.line_number
                )


def validate_language(entries: List[POEntry]) -> ValidationResult:
    """Validate all entries for a language.

    Only verified (non-fuzzy) translations can produce errors.
    Fuzzy strings produce warnings (they need retranslation anyway).
    """
    result = ValidationResult()
    for entry in entries:
        if not entry.is_header and entry.msgstr:
            validate_entry(entry, result)
    return result


# ============================================================================
# Export (Grouped, Numbered Format)
# ============================================================================

def group_entries(entries: List[POEntry]) -> Dict[str, List[POEntry]]:
    """Group entries by their context/source."""
    groups = defaultdict(list)
    for entry in entries:
        groups[entry.get_group()].append(entry)
    return dict(groups)


def export_grouped_format(lang_code: str, entries: List[POEntry],
                          mapping_path: Path) -> str:
    """Export entries in grouped, numbered format for AI translation."""
    lang_name = LANGUAGE_NAMES.get(lang_code, lang_code)

    # Group entries
    groups = group_entries(entries)

    # Build output
    lines = [generate_export_header(lang_code, lang_name, len(entries))]

    # Build mapping: number -> msgid
    mapping = {}
    number = 1

    # Define group order
    group_order = ["Settings", "Actions", "Behaviors", "Domains", "Gestures",
                   "Chat History", "UI Managers", "Error Messages", "General"]

    for group_name in group_order:
        if group_name not in groups:
            continue

        entries_in_group = groups[group_name]
        lines.append(f"\n## {group_name}")

        for entry in entries_in_group:
            # Use single line for short strings, preserve newlines for multi-line
            display_text = entry.msgid.replace('\n', '\\n')
            lines.append(f"{number}. {display_text}")
            mapping[number] = entry.msgid
            number += 1

    # Write mapping file
    with open(mapping_path, 'w', encoding='utf-8') as f:
        json.dump(mapping, f, ensure_ascii=False, indent=2)

    return '\n'.join(lines)


# ============================================================================
# Import (Parse Numbered Format)
# ============================================================================

def parse_numbered_format(text: str) -> Dict[int, str]:
    """Parse numbered translation format back to dict."""
    translations = {}
    current_num = None
    current_lines = []

    for line in text.split('\n'):
        # Skip headers and comments
        if line.startswith('#') or line.startswith('##') or not line.strip():
            # Save previous entry if any
            if current_num is not None and current_lines:
                translations[current_num] = '\n'.join(current_lines)
            current_num = None
            current_lines = []
            continue

        # Check for numbered line
        match = re.match(r'^(\d+)\.\s*(.*)$', line)
        if match:
            # Save previous entry
            if current_num is not None and current_lines:
                translations[current_num] = '\n'.join(current_lines)

            current_num = int(match.group(1))
            text_part = match.group(2)
            # Unescape \n back to actual newlines
            text_part = text_part.replace('\\n', '\n')
            current_lines = [text_part] if text_part else []
        elif current_num is not None:
            # Continuation of multi-line entry
            current_lines.append(line)

    # Don't forget last entry
    if current_num is not None and current_lines:
        translations[current_num] = '\n'.join(current_lines)

    return translations


def import_translations(import_path: Path, mapping_path: Path,
                       entries: List[POEntry]) -> Tuple[Dict[str, str], List[str], int]:
    """Import translations from numbered format file.

    Returns: (translations dict, errors list, skipped verified count)
    """
    # Load mapping
    if not mapping_path.exists():
        return {}, [f"Mapping file not found: {mapping_path}"], 0

    with open(mapping_path, 'r', encoding='utf-8') as f:
        mapping = json.load(f)

    # Convert mapping keys to int (JSON stores as strings)
    mapping = {int(k): v for k, v in mapping.items()}

    # Load and parse import file
    with open(import_path, 'r', encoding='utf-8') as f:
        import_text = f.read()

    numbered_translations = parse_numbered_format(import_text)

    # Build msgid lookup
    msgid_to_entry = {e.msgid: e for e in entries if e.msgid}

    translations = {}
    errors = []
    skipped = 0

    for num, msgstr in numbered_translations.items():
        if num not in mapping:
            errors.append(f"Unknown number {num} - not in mapping")
            continue

        msgid = mapping[num]

        if msgid not in msgid_to_entry:
            errors.append(f"Number {num}: msgid not found in PO file")
            continue

        entry = msgid_to_entry[msgid]

        # Never overwrite verified
        if entry.is_verified:
            skipped += 1
            continue

        # Validate before accepting
        temp_result = ValidationResult()
        # Create temp entry for validation
        temp_entry = POEntry()
        temp_entry.msgid = msgid
        temp_entry.msgstr = msgstr
        temp_entry.line_number = num

        validate_entry(temp_entry, temp_result)

        if temp_result.errors:
            for err in temp_result.errors:
                errors.append(f"Number {num}: {err}")
            continue

        translations[msgid] = msgstr

    return translations, errors, skipped


# ============================================================================
# Commands
# ============================================================================

def cmd_status(args, entries: List[POEntry]):
    """Show translation status."""
    status = get_status(entries)
    lang_name = LANGUAGE_NAMES.get(args.lang, args.lang)

    print(f"\n=== {lang_name} ({args.lang}) ===")
    print(f"Total: {status['total']} | Verified: {status['verified']} | "
          f"Fuzzy: {status['fuzzy']} | Empty: {status['empty']}")

    # Show percentages
    if status['total'] > 0:
        verified_pct = status['verified'] * 100 // status['total']
        fuzzy_pct = status['fuzzy'] * 100 // status['total']
        empty_pct = status['empty'] * 100 // status['total']
        print(f"         ({verified_pct}% verified, {fuzzy_pct}% fuzzy, {empty_pct}% empty)")

    # Show next steps
    empty_count = len(filter_entries(entries, 'empty'))
    fuzzy_count = len(filter_entries(entries, 'fuzzy'))

    if empty_count > 0 or fuzzy_count > 0:
        print(f"\nNext steps:")
        if empty_count > 0:
            print(f"  translate.py {args.lang} export      # Export {empty_count} empty strings")
            print(f"  translate.py {args.lang} run         # Translate via API")
        if fuzzy_count > 0:
            print(f"  translate.py {args.lang} run --redo-fuzzy  # Re-translate {fuzzy_count} fuzzy")


def cmd_check(args, entries: List[POEntry]):
    """Validate existing translations."""
    result = validate_language(entries)
    status = get_status(entries)
    lang_name = LANGUAGE_NAMES.get(args.lang, args.lang)

    print(f"\n=== {lang_name} ({args.lang}) ===")
    print(f"Total: {status['total']} strings")
    print(f"  Verified: {status['verified']} ({status['verified']*100//status['total']}%)" if status['total'] > 0 else "")
    print(f"  Fuzzy: {status['fuzzy']} ({status['fuzzy']*100//status['total']}%)" if status['total'] > 0 else "")
    print(f"  Empty: {status['empty']} ({status['empty']*100//status['total']}%)" if status['total'] > 0 else "")

    print(f"\nErrors: {len(result.errors)}")
    if result.errors and not args.summary:
        for err in result.errors[:10]:
            print(f"  - {err}")
        if len(result.errors) > 10:
            print(f"  ... and {len(result.errors) - 10} more")

    print(f"Warnings: {len(result.warnings)}")
    if result.warnings and not args.summary and not args.errors_only:
        for warn in result.warnings[:10]:
            print(f"  - {warn}")
        if len(result.warnings) > 10:
            print(f"  ... and {len(result.warnings) - 10} more")

    # Quality assessment
    translated = status['total'] - status['empty']
    if translated > 0:
        clean_pct = (translated - len(result.errors)) * 100 // translated
        quality = "EXCELLENT" if clean_pct >= 98 else "GOOD" if clean_pct >= 90 else "NEEDS WORK"
        print(f"\nQuality: {quality} ({clean_pct}% clean)")

    return 0 if result.passed else 1


def get_exports_dir(script_dir: Path) -> Path:
    """Get exports directory, creating if needed."""
    exports_dir = script_dir / "exports"
    exports_dir.mkdir(exist_ok=True)
    return exports_dir


def cmd_export(args, entries: List[POEntry], script_dir: Path):
    """Export strings for manual translation."""
    # Determine mode
    if args.fuzzy:
        mode = 'fuzzy'
    elif args.all:
        mode = 'all'
    else:
        mode = 'empty'

    to_export = filter_entries(entries, mode)

    if not to_export:
        print(f"Nothing to export (no {mode} strings).")
        return 0

    mode_desc = {'empty': 'empty', 'fuzzy': 'fuzzy', 'all': 'all non-verified'}

    # Use exports/ directory
    exports_dir = get_exports_dir(script_dir)
    export_path = exports_dir / f"{args.lang}.txt"
    mapping_path = exports_dir / f"{args.lang}_mapping.json"

    # Generate and write output
    output = export_grouped_format(args.lang, to_export, mapping_path)
    with open(export_path, 'w', encoding='utf-8') as f:
        f.write(output)

    print(f"Exported {len(to_export)} {mode_desc[mode]} strings to {export_path}")
    print(f"Translate the file, then run: translate.py {args.lang} import")

    return 0


def cmd_import(args, entries: List[POEntry], po_path: Path, script_dir: Path):
    """Import translations from file."""
    exports_dir = get_exports_dir(script_dir)

    # Default to exports/{lang}.txt if no file specified
    if args.file:
        import_path = Path(args.file)
    else:
        import_path = exports_dir / f"{args.lang}.txt"

    if not import_path.exists():
        print(f"Error: File not found: {import_path}")
        return 1

    mapping_path = exports_dir / f"{args.lang}_mapping.json"

    print(f"Importing from {import_path}...")
    translations, errors, skipped = import_translations(import_path, mapping_path, entries)

    if errors:
        print(f"\nValidation errors ({len(errors)}):")
        for err in errors[:10]:
            print(f"  - {err}")
        if len(errors) > 10:
            print(f"  ... and {len(errors) - 10} more")

    if skipped > 0:
        print(f"Skipped {skipped} verified translations (protected)")

    if not translations:
        print("No valid translations to apply.")
        return 1

    print(f"\nValid translations: {len(translations)}")

    # Confirm
    if not args.yes:
        response = input("Proceed? [y/N] ").strip().lower()
        if response != 'y':
            print("Cancelled.")
            return 0

    # Apply translations
    for entry in entries:
        if entry.msgid in translations:
            entry.msgstr = translations[entry.msgid]

    # Write with fuzzy markers (unless --verified)
    if args.verified:
        remove_fuzzy = set(translations.keys())
        add_fuzzy = set()
        marker = "human-verified"
    else:
        remove_fuzzy = set()
        add_fuzzy = set(translations.keys())
        marker = "fuzzy (AI-translated)"

    write_po_file(entries, po_path, remove_fuzzy_for=remove_fuzzy, add_fuzzy_for=add_fuzzy)
    print(f"Applied {len(translations)} translations ({marker})")
    print(f"Updated: {po_path}")

    # Clean up mapping file
    if mapping_path.exists():
        mapping_path.unlink()
        print(f"Cleaned up: {mapping_path}")

    return 0


def cmd_plan(args, entries: List[POEntry]):
    """Show what would be translated and cost estimate."""
    # Determine what would be translated
    if args.redo_fuzzy:
        mode = 'fuzzy'
    elif args.new_lang:
        mode = 'all'
    else:
        mode = 'empty'

    to_translate = filter_entries(entries, mode)
    lang_name = LANGUAGE_NAMES.get(args.lang, args.lang)

    mode_desc = {
        'empty': 'empty strings',
        'fuzzy': 'fuzzy strings (re-translation)',
        'all': 'all non-verified (new language)'
    }

    print(f"\n=== Translation Plan for {lang_name} ({args.lang}) ===")
    print(f"Strings to translate: {len(to_translate)} ({mode_desc[mode]})")

    if not to_translate:
        print("Nothing to translate!")
        return 0

    # Estimate tokens (rough: ~4 chars per token, source + target)
    total_chars = sum(len(e.msgid) for e in to_translate)
    input_tokens = total_chars // 4 + len(to_translate) * 50  # +overhead
    output_tokens = input_tokens  # Assume similar size

    print(f"Estimated tokens: ~{input_tokens:,} input, ~{output_tokens:,} output")

    # Cost estimates
    print(f"\nCost by model:")
    # Haiku: $0.25/$1.25 per 1M tokens
    haiku_cost = (input_tokens * 0.25 + output_tokens * 1.25) / 1_000_000
    # Sonnet: $3/$15 per 1M tokens
    sonnet_cost = (input_tokens * 3 + output_tokens * 15) / 1_000_000
    # Opus: $15/$75 per 1M tokens
    opus_cost = (input_tokens * 15 + output_tokens * 75) / 1_000_000

    print(f"  claude-haiku-4-5:  ${haiku_cost:.2f}")
    print(f"  claude-sonnet-4-5: ${sonnet_cost:.2f}")
    print(f"  claude-opus-4-5:   ${opus_cost:.2f}")

    # Show command to run
    run_cmd = f"translate.py {args.lang} run"
    if mode == 'fuzzy':
        run_cmd += " --redo-fuzzy"
    elif mode == 'all':
        run_cmd += " --new-lang"

    print(f"\nRun with: {run_cmd}")

    return 0


def cmd_run(args, entries: List[POEntry], po_path: Path, script_dir: Path):
    """Translate strings via API."""
    # This is a placeholder - API integration will be added in Step 3
    print("API translation not yet implemented.")
    print("Use export/import workflow for now:")
    print(f"  translate.py {args.lang} export > {args.lang}_to_translate.txt")
    print(f"  # Translate with Claude Code, ChatGPT, etc.")
    print(f"  translate.py {args.lang} import {args.lang}_translated.txt")
    return 1


# ============================================================================
# Main
# ============================================================================

def cmd_all_status(script_dir: Path, locale_dir: Path):
    """Show compact validation for all languages."""
    print("\n=== All Languages Validation ===")
    print(f"{'Lang':<7} {'Status':<6} {'Total':>5} {'Verif':>6} {'Fuzzy':>6} {'Empty':>6} {'Err':>4} {'Warn':>5}")
    print("-" * 65)

    all_passed = True
    sum_total = 0
    sum_verified = 0
    sum_fuzzy = 0
    sum_empty = 0
    sum_errors = 0
    sum_warnings = 0

    for lang_code in sorted(LANGUAGE_NAMES.keys()):
        po_path = locale_dir / lang_code / "LC_MESSAGES" / "koassistant.po"
        if not po_path.exists():
            print(f"{lang_code:<7} {'MISS':<6}")
            continue

        entries = parse_po_file(po_path)
        status_info = get_status(entries)
        result = validate_language(entries)

        sum_total += status_info['total']
        sum_verified += status_info['verified']
        sum_fuzzy += status_info['fuzzy']
        sum_empty += status_info['empty']
        sum_errors += len(result.errors)
        sum_warnings += len(result.warnings)

        status = "OK" if result.passed else "FAIL"
        if not result.passed:
            all_passed = False

        print(f"{lang_code:<7} {status:<6} {status_info['total']:>5} {status_info['verified']:>6} "
              f"{status_info['fuzzy']:>6} {status_info['empty']:>6} {len(result.errors):>4} {len(result.warnings):>5}")

    print("-" * 65)
    print(f"{'TOTAL':<7} {'':<6} {sum_total:>5} {sum_verified:>6} {sum_fuzzy:>6} {sum_empty:>6} {sum_errors:>4} {sum_warnings:>5}")

    return 0 if all_passed else 1


def cmd_all_export(args, script_dir: Path, locale_dir: Path):
    """Export all languages that need translation."""
    exports_dir = get_exports_dir(script_dir)
    exported = []

    # Determine mode
    if args.fuzzy:
        mode = 'fuzzy'
    elif args.all:
        mode = 'all'
    else:
        mode = 'empty'

    mode_desc = {'empty': 'empty', 'fuzzy': 'fuzzy', 'all': 'all non-verified'}

    for lang_code in sorted(LANGUAGE_NAMES.keys()):
        po_path = locale_dir / lang_code / "LC_MESSAGES" / "koassistant.po"
        if not po_path.exists():
            continue

        entries = parse_po_file(po_path)
        to_export = filter_entries(entries, mode)

        if not to_export:
            continue

        export_path = exports_dir / f"{lang_code}.txt"
        mapping_path = exports_dir / f"{lang_code}_mapping.json"
        output = export_grouped_format(lang_code, to_export, mapping_path)

        with open(export_path, 'w', encoding='utf-8') as f:
            f.write(output)

        exported.append((lang_code, len(to_export)))

    if exported:
        print(f"Exported {len(exported)} languages to {exports_dir}/")
        for lang, count in exported:
            print(f"  {lang}: {count} {mode_desc[mode]} strings")
        print(f"\nTranslate the files, then run: translate.py all import")
    else:
        print(f"Nothing to export (no {mode} strings in any language).")

    return 0


def cmd_all_import(args, script_dir: Path, locale_dir: Path):
    """Import all translations from exports folder."""
    exports_dir = get_exports_dir(script_dir)
    results = []

    for lang_code in sorted(LANGUAGE_NAMES.keys()):
        export_path = exports_dir / f"{lang_code}.txt"
        mapping_path = exports_dir / f"{lang_code}_mapping.json"

        if not export_path.exists() or not mapping_path.exists():
            continue

        po_path = locale_dir / lang_code / "LC_MESSAGES" / "koassistant.po"
        if not po_path.exists():
            continue

        entries = parse_po_file(po_path)
        translations, errors, skipped = import_translations(export_path, mapping_path, entries)

        if translations:
            results.append((lang_code, len(translations), len(errors), skipped))

    if not results:
        print("No translations found to import.")
        return 0

    print(f"Found translations for {len(results)} languages:")
    total_trans = 0
    total_err = 0
    for lang, count, errs, skipped in results:
        status = f"{count} translations"
        if errs:
            status += f", {errs} errors"
        if skipped:
            status += f", {skipped} skipped"
        print(f"  {lang}: {status}")
        total_trans += count
        total_err += errs

    if total_err > 0:
        print(f"\nTotal: {total_trans} translations, {total_err} errors")

    # Confirm
    if not args.yes:
        response = input("\nProceed with import? [y/N] ").strip().lower()
        if response != 'y':
            print("Cancelled.")
            return 0

    # Apply all translations
    for lang_code in sorted(LANGUAGE_NAMES.keys()):
        export_path = exports_dir / f"{lang_code}.txt"
        mapping_path = exports_dir / f"{lang_code}_mapping.json"

        if not export_path.exists() or not mapping_path.exists():
            continue

        po_path = locale_dir / lang_code / "LC_MESSAGES" / "koassistant.po"
        if not po_path.exists():
            continue

        entries = parse_po_file(po_path)
        translations, errors, skipped = import_translations(export_path, mapping_path, entries)

        if not translations:
            continue

        # Apply
        for entry in entries:
            if entry.msgid in translations:
                entry.msgstr = translations[entry.msgid]

        # Write with fuzzy markers (unless --verified)
        if args.verified:
            remove_fuzzy = set(translations.keys())
            add_fuzzy = set()
        else:
            remove_fuzzy = set()
            add_fuzzy = set(translations.keys())

        write_po_file(entries, po_path, remove_fuzzy_for=remove_fuzzy, add_fuzzy_for=add_fuzzy)

        # Clean up mapping
        if mapping_path.exists():
            mapping_path.unlink()

        print(f"  {lang_code}: Applied {len(translations)} translations")

    marker = "human-verified" if args.verified else "fuzzy (AI-translated)"
    print(f"\nDone. All translations marked as {marker}.")
    return 0


def cmd_clean(script_dir: Path):
    """Clean exports folder."""
    exports_dir = script_dir / "exports"
    if not exports_dir.exists():
        print("Nothing to clean.")
        return 0

    count = 0
    for f in exports_dir.iterdir():
        if f.suffix in ('.txt', '.json'):
            f.unlink()
            count += 1

    print(f"Cleaned {count} files from {exports_dir}/")
    return 0


def main():
    parser = argparse.ArgumentParser(
        description="KOAssistant Translation Tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Commands:
  translate.py all                 Show status for all 20 languages
  translate.py clean               Clear exports/ folder
  translate.py LANG                Show status (verified/fuzzy/empty counts)
  translate.py LANG check          Validate translations

Use cases:

  FULL RETRANSLATION (all languages):
    translate.py clean
    translate.py all export --all
    # Translate each exports/*.txt file
    translate.py all import

  FULL RETRANSLATION (single language):
    translate.py LANG export --all
    # Translate exports/LANG.txt
    translate.py LANG import

  INCREMENTAL UPDATE (after code changes add new strings):
    ./scripts/update_translations.sh
    translate.py all export            # Exports only empty/new strings
    # Translate exports/*.txt
    translate.py all import

  QUALITY FIX (improve fuzzy translations):
    translate.py LANG export --fuzzy
    # Translate exports/LANG.txt
    translate.py LANG import

Export modes:
  (default)     Empty strings only - new strings after code changes
  --all         ALL non-verified - complete retranslation
  --fuzzy       Fuzzy only - improve existing AI translations

Import options:
  --verified    Mark as human-verified (removes fuzzy flag)
  -y, --yes     Skip confirmation prompt

Languages: ar, cs, de, es, fr, hi, id, it, ja, ko_KR, nl_NL, pl, pt, pt_BR, ru, th, tr, uk, vi, zh
        """
    )

    parser.add_argument("lang", help="Language code (ar, es, zh, etc.), 'all', or 'clean'")
    parser.add_argument("command", nargs="?", default="status",
                        choices=["status", "check", "plan", "export", "import", "run"],
                        help="Command (default: status)")
    parser.add_argument("file", nargs="?", help="Optional file for import")

    # Export/run options
    parser.add_argument("--all", action="store_true", help="Include all non-verified strings")
    parser.add_argument("--fuzzy", action="store_true", help="Include only fuzzy strings")

    # Import options
    parser.add_argument("--verified", action="store_true", help="Mark as human-verified")
    parser.add_argument("--yes", "-y", action="store_true", help="Skip confirmation")

    # Run options
    parser.add_argument("--redo-fuzzy", action="store_true", help="Re-translate fuzzy strings")
    parser.add_argument("--new-lang", action="store_true", help="Translate all (new language)")
    parser.add_argument("--model", help="Override model (e.g., claude-sonnet-4-5)")

    # Check options
    parser.add_argument("--summary", action="store_true", help="Summary output only")
    parser.add_argument("--errors-only", action="store_true", help="Show only errors")

    args = parser.parse_args()

    # Find paths
    script_dir = Path(__file__).parent
    locale_dir = script_dir.parent / "locale"

    # Handle 'clean' command
    if args.lang == "clean":
        sys.exit(cmd_clean(script_dir))

    # Handle 'all' language code
    if args.lang == "all":
        if args.command in ("status", "check"):
            sys.exit(cmd_all_status(script_dir, locale_dir))
        elif args.command == "export":
            sys.exit(cmd_all_export(args, script_dir, locale_dir))
        elif args.command == "import":
            sys.exit(cmd_all_import(args, script_dir, locale_dir))
        else:
            print(f"Error: 'all' supports status/export/import commands")
            sys.exit(1)

    # Validate language
    if args.lang not in LANGUAGE_NAMES:
        print(f"Warning: Unknown language code '{args.lang}'")

    # Find PO file
    po_path = locale_dir / args.lang / "LC_MESSAGES" / "koassistant.po"

    if not po_path.exists():
        print(f"Error: PO file not found: {po_path}")
        sys.exit(1)

    # Parse PO file
    entries = parse_po_file(po_path)

    # Dispatch command
    if args.command == "status":
        cmd_status(args, entries)
    elif args.command == "check":
        sys.exit(cmd_check(args, entries))
    elif args.command == "export":
        sys.exit(cmd_export(args, entries, script_dir))
    elif args.command == "import":
        sys.exit(cmd_import(args, entries, po_path, script_dir))
    elif args.command == "plan":
        sys.exit(cmd_plan(args, entries))
    elif args.command == "run":
        sys.exit(cmd_run(args, entries, po_path, script_dir))


if __name__ == "__main__":
    main()

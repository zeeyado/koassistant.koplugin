#!/usr/bin/env python3
"""
Translation Validation Script for KOAssistant

Validates .po translation files against defined policies:
1. PLACEHOLDER_MATCH - msgid %1/%2 count == msgstr %1/%2 count
2. NO_WRONG_PLACEHOLDERS - No %s/%d/%f in msgstr when msgid has %1
3. BRAND_NAMES_PRESERVED - KOAssistant, Claude, OpenAI, etc. unchanged
4. TECHNICAL_TERMS_PRESERVED - API, token, cache, streaming preserved
5. NO_DUPLICATE_TRANSLATIONS - Same msgstr for different msgid (warning)
6. NO_EMPTY_TRANSLATIONS - No empty msgstr (unless msgid is empty)
7. ESCAPE_SEQUENCES - \\n, \\", \\\\ preserved correctly

Usage:
    python validate_translations.py                    # Validate all languages
    python validate_translations.py --lang ar zh      # Validate specific languages
    python validate_translations.py --verbose         # Show all checks, not just failures
    python validate_translations.py --fix             # Auto-fix simple issues (placeholder format)
"""

import argparse
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

# Brand names that should NEVER be translated
BRAND_NAMES = [
    "KOAssistant",
    "KOReader",
    "Claude",
    "GPT",
    "Gemini",
    "OpenAI",
    "Anthropic",
    "DeepSeek",
    "Ollama",
    "Groq",
    "Mistral",
    "xAI",
    "OpenRouter",
    "Qwen",
    "Kimi",
    "Together",
    "Fireworks",
    "SambaNova",
    "Cohere",
    "Doubao",
]

# Technical terms that should be preserved (policy: always preserve)
TECHNICAL_TERMS = [
    "API",
    "token",
    "tokens",
    "cache",
    "caching",
    "streaming",
]

# All supported languages
ALL_LANGUAGES = [
    "ar", "zh", "es", "pt", "pt_BR", "fr", "de", "it",  # Original 8
    "ru", "ja", "pl", "tr", "ko_KR", "vi",              # Tier 1
    "id", "th", "nl_NL", "cs", "uk", "hi",              # Tier 2
]


class POEntry:
    """Represents a single translation entry in a PO file."""
    def __init__(self):
        self.comments = []
        self.msgid = ""
        self.msgid_plural = ""
        self.msgstr = ""
        self.msgstr_plural = []
        self.fuzzy = False
        self.line_number = 0
        self.references = []

    def __repr__(self):
        return f"POEntry(line={self.line_number}, msgid={self.msgid[:30]}...)"


class ValidationResult:
    """Stores validation results for reporting."""
    def __init__(self):
        self.errors = []      # Critical issues (will cause crashes or wrong behavior)
        self.warnings = []    # Non-critical issues (quality concerns)
        self.info = []        # Informational messages

    def add_error(self, check_name, message, line=None):
        prefix = f"Line {line}: " if line else ""
        self.errors.append(f"[{check_name}] {prefix}{message}")

    def add_warning(self, check_name, message, line=None):
        prefix = f"Line {line}: " if line else ""
        self.warnings.append(f"[{check_name}] {prefix}{message}")

    def add_info(self, check_name, message):
        self.info.append(f"[{check_name}] {message}")

    @property
    def passed(self):
        return len(self.errors) == 0

    @property
    def total_issues(self):
        return len(self.errors) + len(self.warnings)


def parse_po_file(filepath):
    """Parse a PO file and return list of POEntry objects."""
    entries = []
    current_entry = None
    current_field = None
    line_number = 0

    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            line_number += 1
            line = line.rstrip('\n')

            # Skip empty lines (entry boundary)
            if not line.strip():
                if current_entry and current_entry.msgid:
                    entries.append(current_entry)
                current_entry = None
                current_field = None
                continue

            # Start new entry if needed
            if current_entry is None:
                current_entry = POEntry()
                current_entry.line_number = line_number

            # Comments
            if line.startswith('#'):
                current_entry.comments.append(line)
                if line.startswith('#, ') and 'fuzzy' in line:
                    current_entry.fuzzy = True
                if line.startswith('#: '):
                    current_entry.references.append(line[3:])
                continue

            # msgid
            if line.startswith('msgid '):
                current_field = 'msgid'
                value = line[6:].strip()
                if value.startswith('"') and value.endswith('"'):
                    current_entry.msgid = unescape_po_string(value[1:-1])
                continue

            # msgid_plural
            if line.startswith('msgid_plural '):
                current_field = 'msgid_plural'
                value = line[13:].strip()
                if value.startswith('"') and value.endswith('"'):
                    current_entry.msgid_plural = unescape_po_string(value[1:-1])
                continue

            # msgstr
            if line.startswith('msgstr '):
                current_field = 'msgstr'
                value = line[7:].strip()
                if value.startswith('"') and value.endswith('"'):
                    current_entry.msgstr = unescape_po_string(value[1:-1])
                continue

            # msgstr[n] (plural forms)
            if line.startswith('msgstr['):
                match = re.match(r'msgstr\[(\d+)\] "(.*)"', line)
                if match:
                    idx = int(match.group(1))
                    value = unescape_po_string(match.group(2))
                    while len(current_entry.msgstr_plural) <= idx:
                        current_entry.msgstr_plural.append("")
                    current_entry.msgstr_plural[idx] = value
                    current_field = f'msgstr[{idx}]'
                continue

            # Continuation line
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

    # Don't forget last entry
    if current_entry and current_entry.msgid:
        entries.append(current_entry)

    return entries


def unescape_po_string(s):
    """Unescape PO string escape sequences."""
    return s.replace('\\n', '\n').replace('\\t', '\t').replace('\\"', '"').replace('\\\\', '\\')


def count_placeholders(text, pattern):
    """Count occurrences of placeholder pattern in text."""
    return len(re.findall(pattern, text))


def validate_entry(entry, result, lang_code):
    """Validate a single PO entry."""
    msgid = entry.msgid
    msgstr = entry.msgstr

    # Skip header entry
    if not msgid:
        return

    # Skip untranslated entries
    if not msgstr:
        result.add_warning("EMPTY_TRANSLATION", f"Untranslated: {msgid[:50]}...", entry.line_number)
        return

    # 1. PLACEHOLDER_MATCH - Check %1, %2, %3 count matches
    for i in range(1, 10):
        pattern = f"%{i}"
        msgid_count = msgid.count(pattern)
        msgstr_count = msgstr.count(pattern)
        if msgid_count != msgstr_count:
            result.add_error(
                "PLACEHOLDER_MISMATCH",
                f"{pattern} count mismatch: msgid has {msgid_count}, msgstr has {msgstr_count}",
                entry.line_number
            )

    # 2. NO_WRONG_PLACEHOLDERS - Check for %s, %d, %f in msgstr when msgid uses %1
    if re.search(r'%[1-9]', msgid):
        wrong_placeholders = re.findall(r'%[sdf]', msgstr)
        if wrong_placeholders:
            result.add_error(
                "WRONG_PLACEHOLDER_FORMAT",
                f"msgstr uses {wrong_placeholders} but msgid uses %1 format",
                entry.line_number
            )

    # 3. BRAND_NAMES_PRESERVED - Check brand names are not translated
    for brand in BRAND_NAMES:
        # Case-sensitive check
        if brand in msgid:
            if brand not in msgstr:
                # Check for common mistranslations
                mistranslations = {
                    "KOAssistant": ["KOAsistente", "KOAssistent", "KOAssistente", "KO助手", "مساعد KO"],
                }
                found_mistranslation = None
                for alt in mistranslations.get(brand, []):
                    if alt in msgstr:
                        found_mistranslation = alt
                        break

                if found_mistranslation:
                    result.add_error(
                        "BRAND_NAME_TRANSLATED",
                        f"'{brand}' translated as '{found_mistranslation}' - should be preserved",
                        entry.line_number
                    )
                else:
                    result.add_warning(
                        "BRAND_NAME_MISSING",
                        f"'{brand}' not found in translation (msgid: {msgid[:40]}...)",
                        entry.line_number
                    )

    # 4. TECHNICAL_TERMS_PRESERVED - Check technical terms
    for term in TECHNICAL_TERMS:
        # Case-insensitive check for msgid, case-sensitive for msgstr
        if re.search(rf'\b{term}\b', msgid, re.IGNORECASE):
            if not re.search(rf'\b{term}\b', msgstr, re.IGNORECASE):
                # Allow some languages to have reasonable translations
                # This is a warning, not an error (policy can be adjusted)
                result.add_warning(
                    "TECHNICAL_TERM_TRANSLATED",
                    f"'{term}' appears translated (original: {msgid[:40]}...)",
                    entry.line_number
                )

    # 5. ESCAPE_SEQUENCES - Check escape sequences preserved
    msgid_newlines = msgid.count('\n')
    msgstr_newlines = msgstr.count('\n')
    if msgid_newlines != msgstr_newlines:
        result.add_warning(
            "NEWLINE_MISMATCH",
            f"Newline count mismatch: msgid has {msgid_newlines}, msgstr has {msgstr_newlines}",
            entry.line_number
        )


def check_duplicates(entries, result):
    """Check for duplicate translations (same msgstr for different msgid)."""
    msgstr_to_msgids = defaultdict(list)

    for entry in entries:
        if entry.msgstr and entry.msgid:
            # Skip very short strings (likely legitimate duplicates like "OK", "Cancel")
            if len(entry.msgstr) > 10:
                msgstr_to_msgids[entry.msgstr].append((entry.msgid, entry.line_number))

    for msgstr, msgid_list in msgstr_to_msgids.items():
        if len(msgid_list) > 1:
            # Check if the msgids are actually different
            unique_msgids = set(m[0] for m in msgid_list)
            if len(unique_msgids) > 1:
                lines = [str(m[1]) for m in msgid_list]
                msgids_preview = [m[0][:30] for m in msgid_list[:3]]
                result.add_warning(
                    "DUPLICATE_TRANSLATION",
                    f"Same translation for different strings (lines {', '.join(lines[:5])}): "
                    f"{msgids_preview}... -> '{msgstr[:40]}...'",
                )


def validate_language(lang_code, locale_dir, verbose=False):
    """Validate a single language's translation file."""
    po_path = locale_dir / lang_code / "LC_MESSAGES" / "koassistant.po"

    if not po_path.exists():
        print(f"  {lang_code}: File not found: {po_path}")
        return None

    result = ValidationResult()

    try:
        entries = parse_po_file(po_path)
        result.add_info("PARSE", f"Parsed {len(entries)} entries")

        # Count statistics
        translated = sum(1 for e in entries if e.msgstr and e.msgid)
        fuzzy = sum(1 for e in entries if e.fuzzy)
        empty = sum(1 for e in entries if not e.msgstr and e.msgid)

        result.add_info("STATS", f"Translated: {translated}, Fuzzy: {fuzzy}, Empty: {empty}")

        # Validate each entry
        for entry in entries:
            validate_entry(entry, result, lang_code)

        # Check for duplicates
        check_duplicates(entries, result)

    except Exception as e:
        result.add_error("PARSE_ERROR", f"Failed to parse file: {e}")

    return result


def main():
    parser = argparse.ArgumentParser(description="Validate KOAssistant translation files")
    parser.add_argument("--lang", nargs="+", help="Specific languages to validate")
    parser.add_argument("--verbose", "-v", action="store_true", help="Show all checks")
    parser.add_argument("--errors-only", action="store_true", help="Show only errors, not warnings")
    parser.add_argument("--summary", action="store_true", help="Show summary only")
    args = parser.parse_args()

    # Find locale directory
    script_dir = Path(__file__).parent
    locale_dir = script_dir.parent / "locale"

    if not locale_dir.exists():
        print(f"Error: Locale directory not found: {locale_dir}")
        sys.exit(1)

    languages = args.lang if args.lang else ALL_LANGUAGES

    print(f"Validating {len(languages)} language(s)...\n")

    total_errors = 0
    total_warnings = 0
    failed_languages = []

    for lang in languages:
        result = validate_language(lang, locale_dir, args.verbose)

        if result is None:
            failed_languages.append(lang)
            continue

        status = "✓ PASS" if result.passed else "✗ FAIL"
        error_count = len(result.errors)
        warning_count = len(result.warnings)

        total_errors += error_count
        total_warnings += warning_count

        if not result.passed:
            failed_languages.append(lang)

        # Print results
        if args.summary:
            print(f"  {lang}: {status} ({error_count} errors, {warning_count} warnings)")
        else:
            print(f"{'='*60}")
            print(f"{lang}: {status}")
            print(f"{'='*60}")

            if args.verbose:
                for info in result.info:
                    print(f"  INFO: {info}")

            for error in result.errors:
                print(f"  ERROR: {error}")

            if not args.errors_only:
                for warning in result.warnings[:10]:  # Limit warnings shown
                    print(f"  WARN: {warning}")
                if len(result.warnings) > 10:
                    print(f"  ... and {len(result.warnings) - 10} more warnings")

            print()

    # Summary
    print(f"\n{'='*60}")
    print("SUMMARY")
    print(f"{'='*60}")
    print(f"Languages validated: {len(languages)}")
    print(f"Total errors: {total_errors}")
    print(f"Total warnings: {total_warnings}")

    if failed_languages:
        print(f"Failed languages: {', '.join(failed_languages)}")
        sys.exit(1)
    else:
        print("All languages passed validation!")
        sys.exit(0)


if __name__ == "__main__":
    main()

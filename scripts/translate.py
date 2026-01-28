#!/usr/bin/env python3
"""
Translation Tool for KOAssistant

Usage:
    translate.py LANG                    # Show status (default)
    translate.py LANG extract            # Extract empty strings to JSON
    translate.py LANG extract --all      # Extract all (new language)
    translate.py LANG apply FILE...      # Apply translations from JSON

Key behaviors:
- AI translations always get fuzzy markers
- Verified translations are NEVER extracted or overwritten
- Use --verified only for human-reviewed translations

See docs/translation_guidelines.md for full documentation.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple


# Language names for display and prompts
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

# Translation guidelines embedded in export
TRANSLATION_GUIDELINES = """## Translation Guidelines (CRITICAL)

### Terms to NEVER Translate (keep in English):
- Plugin/App names: KOAssistant, KOReader
- Provider names: Claude, GPT, Gemini, OpenAI, Anthropic, DeepSeek, Ollama, Groq, Mistral, xAI, OpenRouter, Qwen, Kimi, Together, Fireworks, SambaNova, Cohere, Doubao
- Model names: claude-opus-4-5, gpt-4, gemini-3-pro, etc.
- Technical terms: API, token, tokens, cache, caching, streaming, prompt

### Placeholder Format (CRITICAL - wrong format causes crashes):
- ALWAYS use: %1, %2, %3 (KOReader T() template style)
- NEVER use: %s, %d, %f (Lua string.format style)
- Placeholder count in translation MUST match the source exactly

### Preserve Exactly:
- Escape sequences: \\n (newline), \\t (tab), \\" (quote)
- Markdown formatting: **bold**, - lists, ## headers
- Leading/trailing whitespace

### Context Awareness:
- Strings in "similar_strings" should have DIFFERENT translations
- Source file references show where the string appears in UI
- "gesture" context = KOReader gesture settings
- "menu" context = plugin menu items
"""

DEFAULT_BATCH_SIZE = 100


class POEntry:
    """Represents a single translation entry in a PO file."""
    def __init__(self):
        self.comments: List[str] = []  # All comment lines
        self.references: List[str] = []  # #: file:line references
        self.flags: List[str] = []  # #, flags (fuzzy, etc.)
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

    def add_fuzzy(self):
        """Add fuzzy flag if not already present."""
        if "fuzzy" not in self.flags:
            self.flags.append("fuzzy")
            # Update comments to include #, fuzzy
            has_flag_comment = any(c.startswith('#,') for c in self.comments)
            if has_flag_comment:
                # Add fuzzy to existing flag line
                self.comments = [
                    c if not c.startswith('#,') else f"{c}, fuzzy"
                    for c in self.comments
                ]
            else:
                # Add new flag line (after references, before msgid)
                ref_idx = -1
                for i, c in enumerate(self.comments):
                    if c.startswith('#:'):
                        ref_idx = i
                self.comments.insert(ref_idx + 1, '#, fuzzy')

    def get_context_summary(self) -> str:
        """Generate a human-readable context summary from references."""
        if not self.references:
            return "Unknown context"

        # Parse first reference for context
        ref = self.references[0]
        parts = ref.split(":")
        if len(parts) >= 1:
            filename = parts[0]
            # Determine context type
            if "gesture" in filename.lower():
                return f"Gesture setting ({filename})"
            elif "dialog" in filename.lower():
                return f"Dialog UI ({filename})"
            elif "settings" in filename.lower():
                return f"Settings menu ({filename})"
            elif "main.lua" in filename:
                return f"Main menu ({filename})"
            else:
                return f"UI element ({filename})"
        return "Unknown context"


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

            # Empty line = entry boundary
            if not line.strip():
                if current_entry and (current_entry.msgid or current_entry.is_header):
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
                if line.startswith('#:'):
                    # Source references
                    refs = line[2:].strip().split()
                    current_entry.references.extend(refs)
                elif line.startswith('#,'):
                    # Flags
                    flags = line[2:].strip().split(',')
                    current_entry.flags.extend([f.strip() for f in flags])
                continue

            # msgid
            if line.startswith('msgid '):
                current_field = 'msgid'
                value = line[6:].strip()
                if value.startswith('"') and value.endswith('"'):
                    current_entry.msgid = unescape_po_string(value[1:-1])
                    if not current_entry.msgid and entries == []:
                        current_entry.is_header = True
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

    # Check if string contains newlines
    if '\n' in msgstr:
        # Multi-line format
        lines = ['msgstr ""']
        parts = msgstr.split('\n')
        for i, part in enumerate(parts):
            if i < len(parts) - 1:
                # Not the last part - add \n
                lines.append(f'"{escape_po_string(part)}\\n"')
            else:
                # Last part - no \n unless original had trailing newline
                if part:  # Only add if not empty
                    lines.append(f'"{escape_po_string(part)}"')
        return lines
    else:
        # Single line
        return [f'msgstr "{escape_po_string(msgstr)}"']


def write_po_file(entries: List[POEntry], filepath: Path,
                  remove_fuzzy_for: Optional[Set[str]] = None,
                  add_fuzzy_for: Optional[Set[str]] = None):
    """Write entries back to a PO file with proper formatting.

    Args:
        entries: List of POEntry objects
        filepath: Path to write to
        remove_fuzzy_for: Set of msgids to remove fuzzy from (human verified)
        add_fuzzy_for: Set of msgids to add fuzzy to (AI translated)
    """
    remove_fuzzy_for = remove_fuzzy_for or set()
    add_fuzzy_for = add_fuzzy_for or set()

    with open(filepath, 'w', encoding='utf-8') as f:
        for i, entry in enumerate(entries):
            # Determine if we need to modify fuzzy status
            should_remove_fuzzy = entry.msgid in remove_fuzzy_for
            should_add_fuzzy = entry.msgid in add_fuzzy_for and not entry.is_verified

            # Write comments
            wrote_fuzzy_line = False
            for comment in entry.comments:
                if comment.startswith('#,'):
                    # Handle flag line
                    flags = [fl.strip() for fl in comment[2:].split(',')]

                    # Remove fuzzy if requested
                    if should_remove_fuzzy:
                        flags = [fl for fl in flags if fl != 'fuzzy']

                    # Add fuzzy if requested
                    if should_add_fuzzy and 'fuzzy' not in flags:
                        flags.append('fuzzy')

                    if flags:
                        f.write(f"#, {', '.join(flags)}\n")
                    wrote_fuzzy_line = True
                else:
                    f.write(comment + '\n')

            # If we need to add fuzzy but there was no flag line
            if should_add_fuzzy and not wrote_fuzzy_line:
                f.write('#, fuzzy\n')

            # Write msgid
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

            # Write msgid_plural if present
            if entry.msgid_plural:
                f.write(f'msgid_plural "{escape_po_string(entry.msgid_plural)}"\n')

            # Write msgstr
            for line in format_msgstr_for_po(entry.msgstr):
                f.write(line + '\n')

            # Write msgstr_plural if present
            for idx, plural in enumerate(entry.msgstr_plural):
                f.write(f'msgstr[{idx}] "{escape_po_string(plural)}"\n')

            # Empty line between entries (except after last)
            if i < len(entries) - 1:
                f.write('\n')


def find_similar_strings(entries: List[POEntry]) -> Dict[str, List[str]]:
    """Group strings that should have different translations."""
    similar_groups = defaultdict(list)

    # Group by common prefixes
    for entry in entries:
        if entry.is_header or not entry.msgid:
            continue

        msgid = entry.msgid

        # KOAssistant: prefixed strings (gesture names)
        if msgid.startswith("KOAssistant:"):
            similar_groups["KOAssistant: gestures"].append(msgid)

        # Menu-related strings
        elif "Menu" in msgid and ("Remove" in msgid or "Add" in msgid):
            similar_groups["Menu actions"].append(msgid)

        # Popup-related strings
        elif "Popup" in msgid and ("Remove" in msgid or "Add" in msgid):
            similar_groups["Popup actions"].append(msgid)

        # Settings-related strings
        elif msgid.endswith("Settings") or msgid.endswith("Settings..."):
            similar_groups["Settings items"].append(msgid)

        # Reset-related strings
        elif "Reset" in msgid or "Restore" in msgid:
            similar_groups["Reset/Restore actions"].append(msgid)

    return dict(similar_groups)


def filter_entries(entries: List[POEntry], mode: str) -> List[POEntry]:
    """Filter entries based on extraction mode.

    Modes:
        'empty': Only empty strings (no translation yet) - DEFAULT
        'fuzzy': Only fuzzy strings (need quality improvement)
        'all': All strings EXCEPT verified (new language or full re-translation)

    IMPORTANT: Verified translations are NEVER included in any mode.
    """
    result = []
    for entry in entries:
        if entry.is_header or not entry.msgid:
            continue

        # NEVER extract verified translations
        if entry.is_verified:
            continue

        if mode == 'empty':
            if entry.is_empty:
                result.append(entry)
        elif mode == 'fuzzy':
            if entry.is_fuzzy:
                result.append(entry)
        elif mode == 'all':
            # All non-verified entries (empty + fuzzy)
            result.append(entry)

    return result


def extract_batch(entries: List[POEntry], batch_num: int, batch_size: int,
                  similar_map: Dict[str, List[str]], mode: str = 'all') -> Tuple[List[dict], int]:
    """Extract a batch of entries for translation.

    Args:
        entries: All entries from PO file
        batch_num: 1-indexed batch number
        batch_size: Entries per batch
        similar_map: Map of similar string groups
        mode: Filter mode ('empty', 'fuzzy', 'all')

    Returns:
        Tuple of (batch entries as dicts, total number of batches)
    """
    # Filter entries based on mode
    translatable = filter_entries(entries, mode)

    total_batches = (len(translatable) + batch_size - 1) // batch_size if translatable else 0

    if batch_num < 1 or batch_num > total_batches:
        return [], total_batches

    start = (batch_num - 1) * batch_size
    end = min(start + batch_size, len(translatable))
    batch_entries = translatable[start:end]

    # Build reverse map: msgid -> group name
    msgid_to_group = {}
    for group_name, msgids in similar_map.items():
        for msgid in msgids:
            msgid_to_group[msgid] = group_name

    result = []
    for i, entry in enumerate(batch_entries):
        # Find similar strings for this entry
        group = msgid_to_group.get(entry.msgid)
        similar = []
        if group:
            similar = [m for m in similar_map[group] if m != entry.msgid][:5]  # Limit to 5

        result.append({
            "id": start + i + 1,  # 1-indexed for human readability
            "msgid": entry.msgid,
            "context": entry.get_context_summary(),
            "references": entry.references[:3],  # Limit references
            "current_msgstr": entry.msgstr,
            "is_fuzzy": entry.is_fuzzy,
            "similar_strings": similar,
        })

    return result, total_batches


def export_json(lang_code: str, batch_num: int, entries: List[dict],
                total_batches: int, output_path: Path, mode: str):
    """Export batch to JSON file for translation."""
    lang_name = LANGUAGE_NAMES.get(lang_code, lang_code)

    mode_desc = {
        'empty': 'untranslated strings',
        'fuzzy': 'fuzzy strings (need quality improvement)',
        'all': 'all non-verified strings'
    }

    export_data = {
        "metadata": {
            "language_code": lang_code,
            "language_name": lang_name,
            "batch": batch_num,
            "total_batches": total_batches,
            "entry_count": len(entries),
            "mode": mode,
            "mode_description": mode_desc.get(mode, mode),
            "export_format_version": "1.1",
        },
        "guidelines": TRANSLATION_GUIDELINES,
        "entries": entries,
    }

    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump(export_data, f, ensure_ascii=False, indent=2)


def import_translations(input_path: Path, entries: List[POEntry]) -> Tuple[Dict[str, str], List[str], Set[str]]:
    """Import translations from JSON file.

    Returns:
        Tuple of (translations dict, error list, set of msgids that were verified in source)
    """
    with open(input_path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    # Build msgid lookup
    msgid_to_entry = {e.msgid: e for e in entries if e.msgid}

    translations = {}
    errors = []
    skipped_verified = set()

    # Handle both formats: direct "translations" array or "entries" with msgstr
    items = data.get("translations", data.get("entries", []))

    for item in items:
        msgid = item.get("msgid")
        msgstr = item.get("msgstr")

        if not msgid:
            errors.append(f"Entry missing msgid: {item}")
            continue

        if msgid not in msgid_to_entry:
            errors.append(f"Unknown msgid: {msgid[:50]}...")
            continue

        # NEVER overwrite verified translations
        entry = msgid_to_entry[msgid]
        if entry.is_verified:
            skipped_verified.add(msgid)
            continue

        if msgstr is not None:
            translations[msgid] = msgstr

    return translations, errors, skipped_verified


def apply_translations(entries: List[POEntry], translations: Dict[str, str]) -> int:
    """Apply translations to entries. Returns count of applied translations."""
    applied = 0
    for entry in entries:
        if entry.msgid in translations:
            # Double-check: never overwrite verified
            if entry.is_verified:
                continue
            entry.msgstr = translations[entry.msgid]
            applied += 1
    return applied


def run_validation(lang_code: str, script_dir: Path) -> Tuple[bool, str]:
    """Run validation script on the language."""
    validate_script = script_dir / "validate_translations.py"
    if not validate_script.exists():
        return False, "Validation script not found"

    result = subprocess.run(
        ["python3", str(validate_script), "--lang", lang_code, "--summary"],
        capture_output=True,
        text=True,
        cwd=script_dir.parent
    )

    passed = "PASS" in result.stdout and "error" not in result.stdout.lower()
    return passed, result.stdout + result.stderr


def get_status(entries: List[POEntry]) -> dict:
    """Get translation status for entries."""
    translatable = [e for e in entries if e.msgid and not e.is_header]
    fuzzy = [e for e in translatable if e.is_fuzzy]
    translated = [e for e in translatable if e.msgstr]
    empty = [e for e in translatable if not e.msgstr]
    verified = [e for e in translatable if e.is_verified]

    return {
        "total": len(translatable),
        "translated": len(translated),
        "fuzzy": len(fuzzy),
        "verified": len(verified),
        "empty": len(empty),
    }


def main():
    parser = argparse.ArgumentParser(
        description="KOAssistant Translation Tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  translate.py ar                    # Show translation status
  translate.py ar extract            # Extract empty strings to JSON
  translate.py ar extract --all      # Extract all (new language)
  translate.py ar extract --fuzzy    # Extract fuzzy only (quality fix)
  translate.py ar apply ar_batch*.json   # Apply translations

Key behaviors:
  - AI translations always get fuzzy markers
  - Verified translations are NEVER extracted or overwritten
  - Use --verified only for human-reviewed translations
        """
    )

    # Positional arguments
    parser.add_argument("lang", help="Language code (ar, es, zh, etc.)")
    parser.add_argument("command", nargs="?", default="status",
                        choices=["status", "extract", "apply"],
                        help="Command: status (default), extract, apply")
    parser.add_argument("files", nargs="*", help="JSON files for apply command")

    # Extract options
    extract_group = parser.add_mutually_exclusive_group()
    extract_group.add_argument("--all", action="store_true",
                               help="Extract all non-verified strings")
    extract_group.add_argument("--fuzzy", action="store_true",
                               help="Extract only fuzzy strings")

    # Other options
    parser.add_argument("--batch", type=int, help="Extract specific batch (1-indexed)")
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE,
                        help=f"Entries per batch (default: {DEFAULT_BATCH_SIZE})")
    parser.add_argument("--output", "-o", help="Output path for extract")
    parser.add_argument("--verified", action="store_true",
                        help="Mark as human-verified (removes fuzzy)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would happen without changes")
    parser.add_argument("--no-validate", action="store_true",
                        help="Skip validation after apply")

    args = parser.parse_args()

    # Validate language
    if args.lang not in LANGUAGE_NAMES:
        print(f"Warning: Unknown language code '{args.lang}'")

    # Find paths
    script_dir = Path(__file__).parent
    locale_dir = script_dir.parent / "locale"
    po_path = locale_dir / args.lang / "LC_MESSAGES" / "koassistant.po"

    if not po_path.exists():
        print(f"Error: PO file not found: {po_path}")
        sys.exit(1)

    # Parse PO file
    print(f"Parsing {po_path}...")
    entries = parse_po_file(po_path)
    print(f"Found {len(entries)} entries")

    # Find similar strings for context
    similar_map = find_similar_strings(entries)

    # Determine extraction mode
    if args.all:
        mode = 'all'
    elif args.fuzzy:
        mode = 'fuzzy'
    else:
        mode = 'empty'

    # Handle commands
    if args.command == "status":
        status = get_status(entries)
        print(f"\n=== {LANGUAGE_NAMES.get(args.lang, args.lang)} ({args.lang}) ===")
        print(f"Total: {status['total']} strings")
        print(f"  Verified: {status['verified']}")
        print(f"  Fuzzy: {status['fuzzy']}")
        print(f"  Empty: {status['empty']}")

        # Show what each mode would extract
        empty_count = len(filter_entries(entries, 'empty'))
        fuzzy_count = len(filter_entries(entries, 'fuzzy'))
        all_count = len(filter_entries(entries, 'all'))

        if empty_count > 0 or fuzzy_count > 0:
            print(f"\nNext steps:")
            if empty_count > 0:
                batches = (empty_count + args.batch_size - 1) // args.batch_size
                print(f"  translate.py {args.lang} extract       # {empty_count} empty → {batches} batch(es)")
            if fuzzy_count > 0:
                batches = (fuzzy_count + args.batch_size - 1) // args.batch_size
                print(f"  translate.py {args.lang} extract --fuzzy  # {fuzzy_count} fuzzy → {batches} batch(es)")
            if all_count > 0 and all_count != empty_count:
                batches = (all_count + args.batch_size - 1) // args.batch_size
                print(f"  translate.py {args.lang} extract --all    # {all_count} total → {batches} batch(es)")

    elif args.command == "extract":
        translatable = filter_entries(entries, mode)
        total_batches = (len(translatable) + args.batch_size - 1) // args.batch_size if translatable else 0

        mode_desc = {'empty': 'empty', 'fuzzy': 'fuzzy', 'all': 'all non-verified'}
        print(f"Extracting {mode_desc[mode]} strings: {len(translatable)} entries")

        if len(translatable) == 0:
            print(f"Nothing to extract.")
            sys.exit(0)

        if args.batch:
            # Extract specific batch
            batch_entries, _ = extract_batch(entries, args.batch, args.batch_size, similar_map, mode)
            if not batch_entries:
                print(f"Error: Invalid batch {args.batch}. Valid: 1-{total_batches}")
                sys.exit(1)

            output_path = Path(args.output) if args.output else Path(f"{args.lang}_batch{args.batch}.json")

            if args.dry_run:
                print(f"[DRY-RUN] Would export batch {args.batch}/{total_batches} ({len(batch_entries)} entries)")
            else:
                export_json(args.lang, args.batch, batch_entries, total_batches, output_path, mode)
                print(f"Exported: {output_path} ({len(batch_entries)} entries)")
                print(f"\nNext: translate.py {args.lang} apply {output_path}")
        else:
            # Extract all batches
            output_dir = Path(args.output) if args.output else Path(".")

            if args.dry_run:
                print(f"[DRY-RUN] Would export {total_batches} batches to {output_dir}/")
            else:
                files = []
                for batch_num in range(1, total_batches + 1):
                    batch_entries, _ = extract_batch(entries, batch_num, args.batch_size, similar_map, mode)
                    output_path = output_dir / f"{args.lang}_batch{batch_num}.json"
                    export_json(args.lang, batch_num, batch_entries, total_batches, output_path, mode)
                    files.append(output_path.name)
                    print(f"  {output_path} ({len(batch_entries)} entries)")

                print(f"\nNext: translate.py {args.lang} apply {args.lang}_batch*.json")

    elif args.command == "apply":
        if not args.files:
            print("Error: apply requires at least one JSON file")
            print(f"Usage: translate.py {args.lang} apply FILE [FILE...]")
            sys.exit(1)

        # Process all input files
        all_translations = {}
        all_errors = []
        all_skipped = set()

        for file_arg in args.files:
            input_path = Path(file_arg)
            if not input_path.exists():
                print(f"Warning: File not found, skipping: {input_path}")
                continue

            print(f"Reading {input_path}...")
            translations, errors, skipped = import_translations(input_path, entries)
            all_translations.update(translations)
            all_errors.extend(errors)
            all_skipped.update(skipped)

        if not all_translations:
            print("Error: No translations found in input files")
            sys.exit(1)

        if all_skipped:
            print(f"Protected {len(all_skipped)} verified translations")

        if all_errors:
            print(f"Warnings: {len(all_errors)} (use --dry-run to see details)")

        print(f"Found {len(all_translations)} translations to apply")

        if args.dry_run:
            print(f"\n[DRY-RUN] Would apply {len(all_translations)} translations")
            if args.verified:
                print("  Mode: human-verified (removes fuzzy)")
            else:
                print("  Mode: AI-translated (adds fuzzy)")
            print(f"\nFirst 3:")
            for msgid, msgstr in list(all_translations.items())[:3]:
                print(f"  {msgid[:40]}...")
            if all_errors:
                print(f"\nWarnings:")
                for err in all_errors[:5]:
                    print(f"  - {err}")
        else:
            # Apply translations
            applied = apply_translations(entries, all_translations)
            print(f"Applied {applied} translations")

            # Determine fuzzy handling
            if args.verified:
                remove_fuzzy = set(all_translations.keys())
                add_fuzzy = set()
                print("Marked as verified (fuzzy removed)")
            else:
                remove_fuzzy = set()
                add_fuzzy = set(all_translations.keys())
                print("Marked as fuzzy (needs verification)")

            # Write back to file
            write_po_file(entries, po_path, remove_fuzzy_for=remove_fuzzy, add_fuzzy_for=add_fuzzy)
            print(f"Updated {po_path}")

            # Run validation
            if not args.no_validate:
                print(f"\nValidating...")
                passed, output = run_validation(args.lang, script_dir)
                if passed:
                    print("Validation: PASSED")
                else:
                    print("Validation: FAILED")
                    print(output)


if __name__ == "__main__":
    main()

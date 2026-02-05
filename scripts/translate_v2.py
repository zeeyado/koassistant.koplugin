#!/usr/bin/env python3
"""
KOAssistant Translation Tool v2

Simplified AI interface: AI translates plain text only, script handles all structural complexity.

Usage:
    translate_v2.py LANG                         # Show status
    translate_v2.py LANG export                  # Export empty strings
    translate_v2.py LANG export --all            # Export all unverified
    translate_v2.py LANG export --fuzzy          # Export fuzzy only
    translate_v2.py LANG export --batches=8      # Split into 8 batch files
    translate_v2.py LANG import [FILE]           # Import translations
    translate_v2.py LANG combine                 # Combine batch files
    translate_v2.py LANG run --api anthropic     # Translate via Anthropic API
    translate_v2.py LANG run --api openai        # Translate via OpenAI API

Key behaviors:
- AI only sees plain text with [NL] markers for newlines
- Verified translations are NEVER extracted or overwritten
- ALL AI translations get fuzzy markers (100% programmatic)
- Brand names and placeholders validated before and after translation
"""

import argparse
import json
import os
import re
import sys
import threading
import time
import urllib.request
import urllib.error
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

# ============================================================================
# SINGLE SOURCE OF TRUTH - Edit these lists to add new providers/brands/terms
# ============================================================================

# MUST appear unchanged if in source - ERROR if missing
BRANDS = ["KOAssistant", "KOReader", "(KOA)"]

# Should appear unchanged - WARNING if missing
PROVIDERS = [
    "Claude", "GPT", "OpenAI", "Anthropic", "DeepSeek", "Gemini",
    "Ollama", "Groq", "Mistral", "xAI", "OpenRouter", "Qwen",
    "Kimi", "Together", "Fireworks", "SambaNova", "Cohere", "Doubao"
]

# Keep as technical acronym - typically preserved in translations
TECH_TERMS = ["API"]

# Newline marker for v2 format
NEWLINE_MARKER = "[NL]"

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
# Newline Handler
# ============================================================================

class NewlineHandler:
    """Handle newline encoding/decoding for v2 format."""

    MARKER = NEWLINE_MARKER

    @staticmethod
    def encode(text: str) -> str:
        """Replace actual newlines with marker for export."""
        return text.replace('\n', NewlineHandler.MARKER)

    @staticmethod
    def decode(text: str) -> str:
        """Replace marker with actual newlines on import."""
        return text.replace(NewlineHandler.MARKER, '\n')

    @staticmethod
    def validate_count(source: str, translation: str) -> bool:
        """Verify same number of newline markers."""
        return source.count(NewlineHandler.MARKER) == translation.count(NewlineHandler.MARKER)

# ============================================================================
# Placeholder Validator
# ============================================================================

class PlaceholderValidator:
    """Validate placeholders and brand names in translations."""

    PLACEHOLDER_PATTERN = re.compile(r'%[1-9]')

    @classmethod
    def extract_placeholders(cls, text: str) -> List[str]:
        """Extract all %N placeholders from text."""
        return cls.PLACEHOLDER_PATTERN.findall(text)

    @classmethod
    def validate(cls, source: str, translation: str) -> List[str]:
        """Return list of validation errors."""
        errors = []

        # Check placeholder counts
        source_ph = cls.extract_placeholders(source)
        trans_ph = cls.extract_placeholders(translation)

        for ph in set(source_ph):
            src_count = source_ph.count(ph)
            trans_count = trans_ph.count(ph)
            if src_count != trans_count:
                errors.append(f"Placeholder {ph} count mismatch: source={src_count}, trans={trans_count}")

        # Check for wrong placeholder format
        if source_ph and re.search(r'%[sdf]', translation):
            errors.append("Wrong placeholder format (use %1, %2, not %s, %d)")

        # Check newline marker count
        source_nl = source.count(NEWLINE_MARKER)
        trans_nl = translation.count(NEWLINE_MARKER)
        if source_nl != trans_nl:
            errors.append(f"Newline marker count mismatch: source={source_nl}, trans={trans_nl}")

        # Check brand names (ERROR if missing)
        for brand in BRANDS:
            if brand in source and brand not in translation:
                errors.append(f"Brand '{brand}' must appear in translation")

        return errors

    @classmethod
    def validate_warnings(cls, source: str, translation: str) -> List[str]:
        """Return list of validation warnings (non-critical)."""
        warnings = []

        # Check provider names (WARNING if missing)
        for provider in PROVIDERS:
            if provider in source and provider not in translation:
                warnings.append(f"Provider '{provider}' should be preserved")

        # Check technical terms
        for term in TECH_TERMS:
            if term.upper() in source.upper() and term.upper() not in translation.upper():
                warnings.append(f"Technical term '{term}' should be preserved")

        return warnings

    @classmethod
    def auto_fix(cls, source: str, translation: str) -> Tuple[str, List[str]]:
        """Attempt to auto-fix common issues. Return (fixed, fixes_applied)."""
        fixes = []
        result = translation

        # Fix %s -> %1, %d -> %2 etc
        source_ph = cls.extract_placeholders(source)
        wrong_placeholders = re.findall(r'%[sdf]', result)

        if wrong_placeholders and source_ph:
            for i, old_ph in enumerate(wrong_placeholders):
                if i < len(source_ph):
                    result = result.replace(old_ph, source_ph[i], 1)
                    fixes.append(f"Fixed {old_ph} -> {source_ph[i]}")

        return result, fixes

# ============================================================================
# Batch Manager
# ============================================================================

class BatchManager:
    """Handle automatic batch splitting and combining."""

    def __init__(self, total_strings: int, num_batches: int = 8):
        self.total = total_strings
        self.num_batches = num_batches
        self.batch_size = (total_strings + num_batches - 1) // num_batches if num_batches > 0 else total_strings

    def get_batch_ranges(self) -> List[Tuple[int, int, int]]:
        """Return list of (batch_num, start, end) tuples (1-indexed)."""
        ranges = []
        for i in range(self.num_batches):
            start = i * self.batch_size + 1
            end = min((i + 1) * self.batch_size, self.total)
            if start <= self.total:
                ranges.append((i + 1, start, end))
        return ranges

    def split_to_files(self, strings: Dict[int, str], output_dir: Path,
                       lang_code: str, header: str) -> List[Path]:
        """Split strings into batch files, return paths."""
        paths = []
        ranges = self.get_batch_ranges()

        for batch_num, start, end in ranges:
            batch_path = output_dir / f"{lang_code}_batch_{batch_num}.txt"
            lines = [f"# {LANGUAGE_NAMES.get(lang_code, lang_code)} - Batch {batch_num}/{len(ranges)} (strings {start}-{end})"]
            lines.append(header.split('\n')[1] if '\n' in header else header)  # Keep KEEP: line
            lines.append("")

            for num in range(start, end + 1):
                if num in strings:
                    lines.append(f"{num}. {strings[num]}")

            with open(batch_path, 'w', encoding='utf-8') as f:
                f.write('\n'.join(lines))

            paths.append(batch_path)

        return paths

    @staticmethod
    def combine_from_files(input_dir: Path, lang_code: str) -> Dict[int, str]:
        """Combine batch files back into single dict."""
        combined = {}

        # Find all batch files
        batch_files = sorted(input_dir.glob(f"{lang_code}_batch_*.txt"))

        for batch_file in batch_files:
            with open(batch_file, 'r', encoding='utf-8') as f:
                content = f.read()

            # Parse numbered lines
            for line in content.split('\n'):
                match = re.match(r'^(\d+)\.\s*(.*)$', line)
                if match:
                    num = int(match.group(1))
                    text = match.group(2).strip()
                    combined[num] = text

        return combined

# ============================================================================
# PO File Parsing (from v1)
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
            should_add_fuzzy = entry.msgid in add_fuzzy_for

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

def has_validation_issues(entry: POEntry) -> bool:
    """Check if entry has validation errors or warnings."""
    if not entry.msgstr:
        return False

    source = NewlineHandler.encode(entry.msgid)
    trans = NewlineHandler.encode(entry.msgstr)

    errors = PlaceholderValidator.validate(source, trans)
    warnings = PlaceholderValidator.validate_warnings(source, trans)

    return bool(errors or warnings)


def filter_entries(entries: List[POEntry], mode: str) -> List[POEntry]:
    """Filter entries based on extraction mode.

    Modes:
        'empty': Only empty strings (no translation yet) - DEFAULT
        'fuzzy': Only fuzzy strings (need quality improvement)
        'all': All strings EXCEPT verified (new language)
        'errors': Only strings with validation errors/warnings (fuzzy only)

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
        elif mode == 'errors' and entry.is_fuzzy and has_validation_issues(entry):
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
# V2 Export Format
# ============================================================================

def generate_v2_header(lang_code: str, lang_name: str, count: int) -> str:
    """Generate minimal v2 export header."""
    brands_str = ", ".join(BRANDS)
    terms_str = ", ".join(TECH_TERMS)
    return f"""# {lang_name} - {count} strings
# KEEP: {brands_str}, {terms_str}, %1, %2, {NEWLINE_MARKER}"""


def export_v2_format(lang_code: str, entries: List[POEntry],
                     output_path: Path, mapping_path: Path,
                     num_batches: int = 0) -> int:
    """
    Export entries in simplified v2 format for AI translation.

    Format:
    # German - 925 strings
    # KEEP: KOAssistant, KOReader, API, %1, %2, [NL]

    1. Chat about Book
    2. New General Chat
    3. How often to check.[NL]Lower = snappier.

    Returns: number of strings exported
    """
    lang_name = LANGUAGE_NAMES.get(lang_code, lang_code)
    header = generate_v2_header(lang_code, lang_name, len(entries))

    # Build string list with newline encoding
    mapping = {}
    output_lines = [header, ""]

    for i, entry in enumerate(entries, 1):
        # Encode newlines as [NL]
        text = NewlineHandler.encode(entry.msgid)
        output_lines.append(f"{i}. {text}")
        mapping[i] = entry.msgid

    # Write main file
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(output_lines))

    # Write mapping
    with open(mapping_path, 'w', encoding='utf-8') as f:
        json.dump(mapping, f, ensure_ascii=False, indent=2)

    # Handle batch splitting if requested
    if num_batches > 0:
        batch_mgr = BatchManager(len(entries), num_batches)
        strings = {i: NewlineHandler.encode(e.msgid) for i, e in enumerate(entries, 1)}
        batch_mgr.split_to_files(strings, output_path.parent, lang_code, header)
        print(f"  Created {num_batches} batch files")

    return len(entries)

# ============================================================================
# V2 Import Format
# ============================================================================

def parse_v2_numbered_format(text: str) -> Dict[int, str]:
    """Parse v2 numbered format back to dict."""
    translations = {}

    for line in text.split('\n'):
        # Skip comments and empty lines
        if line.startswith('#') or not line.strip():
            continue

        # Match numbered line
        match = re.match(r'^(\d+)\.\s*(.*)$', line)
        if match:
            num = int(match.group(1))
            trans_text = match.group(2).strip()
            translations[num] = trans_text

    return translations


def import_v2_format(import_path: Path, mapping_path: Path,
                     entries: List[POEntry],
                     auto_fix: bool = True) -> Tuple[Dict[str, str], List[str], List[str], int]:
    """
    Import translations from v2 format.

    Returns: (translations dict, errors list, warnings list, skipped verified count)
    """
    # Load mapping
    with open(mapping_path, 'r', encoding='utf-8') as f:
        mapping = json.load(f)
    mapping = {int(k): v for k, v in mapping.items()}

    # Parse import file
    with open(import_path, 'r', encoding='utf-8') as f:
        content = f.read()

    translations_raw = parse_v2_numbered_format(content)

    # Build msgid lookup
    msgid_to_entry = {e.msgid: e for e in entries if e.msgid}

    translations = {}
    errors = []
    warnings = []
    skipped = 0
    fixed_count = 0

    for num, trans_text in translations_raw.items():
        if num not in mapping:
            errors.append(f"#{num}: Unknown number (not in mapping)")
            continue

        msgid = mapping[num]
        source_encoded = NewlineHandler.encode(msgid)

        if msgid not in msgid_to_entry:
            errors.append(f"#{num}: msgid not found in PO file")
            continue

        entry = msgid_to_entry[msgid]

        # Skip verified
        if entry.is_verified:
            skipped += 1
            continue

        # Auto-fix if enabled
        if auto_fix:
            trans_text, fixes = PlaceholderValidator.auto_fix(source_encoded, trans_text)
            if fixes:
                fixed_count += len(fixes)

        # Validate placeholders and brands
        validation_errors = PlaceholderValidator.validate(source_encoded, trans_text)
        validation_warnings = PlaceholderValidator.validate_warnings(source_encoded, trans_text)

        if validation_errors:
            for err in validation_errors:
                errors.append(f"#{num}: {err}")
            continue

        if validation_warnings:
            for warn in validation_warnings:
                warnings.append(f"#{num}: {warn}")

        # Decode newlines
        final_text = NewlineHandler.decode(trans_text)
        translations[msgid] = final_text

    if fixed_count > 0:
        print(f"  Auto-fixed {fixed_count} placeholder issues")

    return translations, errors, warnings, skipped

# ============================================================================
# API Keys Loader
# ============================================================================

def load_api_keys() -> dict:
    """Parse apikeys.lua to get API credentials."""
    script_dir = Path(__file__).parent
    apikeys_path = script_dir.parent / "apikeys.lua"

    if not apikeys_path.exists():
        return {}

    content = apikeys_path.read_text()
    keys = {}

    # Simple Lua table parser for apikeys format
    for match in re.finditer(r'(\w+)\s*=\s*"([^"]*)"', content):
        keys[match.group(1)] = match.group(2)

    return keys

# ============================================================================
# Spinner for API calls
# ============================================================================

class Spinner:
    """Live spinner with elapsed time for long-running operations."""

    FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    def __init__(self, message: str):
        self.message = message
        self.running = False
        self.thread = None
        self.start_time = None

    def _spin(self):
        """Spinner thread function."""
        idx = 0
        while self.running:
            elapsed = time.time() - self.start_time
            frame = self.FRAMES[idx % len(self.FRAMES)]
            # Clear line and write spinner
            sys.stdout.write(f"\r    → {self.message} {frame} {elapsed:.1f}s ")
            sys.stdout.flush()
            idx += 1
            time.sleep(0.1)

    def start(self):
        """Start the spinner."""
        self.running = True
        self.start_time = time.time()
        self.thread = threading.Thread(target=self._spin, daemon=True)
        self.thread.start()

    def stop(self, success: bool = True):
        """Stop the spinner and show final status."""
        self.running = False
        if self.thread:
            self.thread.join(timeout=0.2)
        elapsed = time.time() - self.start_time
        icon = "✓" if success else "✗"
        # Clear line and write final status
        sys.stdout.write(f"\r    → {self.message} {icon} {elapsed:.1f}s   \n")
        sys.stdout.flush()


# ============================================================================
# API Translator
# ============================================================================

class APITranslator:
    """Direct API translation for Anthropic and OpenAI."""

    # Batch size to avoid token limits
    BATCH_SIZE = 50

    # Retry settings
    MAX_RETRIES = 3
    RETRY_DELAY = 5  # seconds

    def __init__(self, provider: str, model: str, api_key: str):
        self.provider = provider
        self.model = model
        self.api_key = api_key

    def translate_strings(self, strings: Dict[int, str], target_lang: str,
                          progress_callback=None) -> Dict[int, str]:
        """Translate all strings in batches."""
        results = {}
        sorted_nums = sorted(strings.keys())
        total_batches = (len(sorted_nums) + self.BATCH_SIZE - 1) // self.BATCH_SIZE
        total_strings = len(sorted_nums)

        print(f"  {total_strings} strings in {total_batches} batch(es)")

        for batch_idx in range(total_batches):
            start_idx = batch_idx * self.BATCH_SIZE
            end_idx = min(start_idx + self.BATCH_SIZE, len(sorted_nums))
            batch_nums = sorted_nums[start_idx:end_idx]

            batch_strings = [(num, strings[num]) for num in batch_nums]

            # Show batch number
            print(f"  [{batch_idx + 1}/{total_batches}] {len(batch_strings)} strings")

            if progress_callback:
                progress_callback(batch_idx + 1, total_batches)

            # Translate batch with retry (spinner shows live progress)
            batch_results = self._translate_batch_with_retry(batch_strings, target_lang)
            results.update(batch_results)

            # Small delay between batches to avoid rate limits
            if batch_idx < total_batches - 1:
                time.sleep(1)

        return results

    def _translate_batch_with_retry(self, batch: List[Tuple[int, str]],
                                    target_lang: str) -> Dict[int, str]:
        """Translate a batch with retry logic."""
        for attempt in range(self.MAX_RETRIES):
            try:
                return self._translate_batch(batch, target_lang)
            except Exception as e:
                if attempt < self.MAX_RETRIES - 1:
                    print(f"  Retry {attempt + 1}/{self.MAX_RETRIES} after error: {e}")
                    time.sleep(self.RETRY_DELAY * (attempt + 1))
                else:
                    raise
        return {}

    def _translate_batch(self, batch: List[Tuple[int, str]], target_lang: str) -> Dict[int, str]:
        """Translate a single batch via API."""
        prompt = self._build_prompt(batch, target_lang)

        spinner = Spinner(self.provider)
        spinner.start()
        try:
            if self.provider == "anthropic":
                response = self._call_anthropic(prompt)
            elif self.provider == "openai":
                response = self._call_openai(prompt)
            else:
                spinner.stop(success=False)
                raise ValueError(f"Unknown provider: {self.provider}")
            spinner.stop(success=True)
        except Exception:
            spinner.stop(success=False)
            raise

        # Parse response
        return self._parse_response(response, batch)

    def _build_prompt(self, batch: List[Tuple[int, str]], lang: str) -> str:
        """Build translation prompt for API."""
        lang_name = LANGUAGE_NAMES.get(lang, lang)
        brands_str = ", ".join(BRANDS)
        terms_str = ", ".join(TECH_TERMS)

        numbered = "\n".join(f"{num}. {text}" for num, text in batch)

        return f"""Translate these UI strings to {lang_name}.

CRITICAL RULES:
1. Keep EXACTLY as-is: {brands_str}, {terms_str}
2. Keep placeholders EXACTLY: %1, %2, %3
3. Keep newline markers EXACTLY: {NEWLINE_MARKER}
4. Output ONLY numbered translations, no explanations

{numbered}"""

    def _call_anthropic(self, prompt: str) -> str:
        """Call Anthropic Messages API."""
        url = "https://api.anthropic.com/v1/messages"

        headers = {
            "Content-Type": "application/json",
            "x-api-key": self.api_key,
            "anthropic-version": "2023-06-01"
        }

        data = {
            "model": self.model,
            "max_tokens": 4096,
            "messages": [
                {"role": "user", "content": prompt}
            ]
        }

        req = urllib.request.Request(
            url,
            data=json.dumps(data).encode('utf-8'),
            headers=headers,
            method='POST'
        )

        with urllib.request.urlopen(req, timeout=120) as response:
            result = json.loads(response.read().decode('utf-8'))

        return result['content'][0]['text']

    def _call_openai(self, prompt: str) -> str:
        """Call OpenAI Chat Completions API."""
        url = "https://api.openai.com/v1/chat/completions"

        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.api_key}"
        }

        data = {
            "model": self.model,
            "messages": [
                {"role": "user", "content": prompt}
            ],
            "max_tokens": 4096
        }

        req = urllib.request.Request(
            url,
            data=json.dumps(data).encode('utf-8'),
            headers=headers,
            method='POST'
        )

        with urllib.request.urlopen(req, timeout=120) as response:
            result = json.loads(response.read().decode('utf-8'))

        return result['choices'][0]['message']['content']

    def _parse_response(self, response: str, batch: List[Tuple[int, str]]) -> Dict[int, str]:
        """Parse API response to extract translations."""
        results = {}
        expected_nums = {num for num, _ in batch}

        for line in response.split('\n'):
            match = re.match(r'^(\d+)\.\s*(.*)$', line.strip())
            if match:
                num = int(match.group(1))
                text = match.group(2).strip()
                if num in expected_nums:
                    results[num] = text

        return results

# ============================================================================
# Commands
# ============================================================================

def get_exports_dir(script_dir: Path) -> Path:
    """Get exports directory, creating if needed."""
    exports_dir = script_dir / "exports"
    exports_dir.mkdir(exist_ok=True)
    return exports_dir


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
            print(f"  translate_v2.py {args.lang} export             # Export {empty_count} empty strings")
            print(f"  translate_v2.py {args.lang} run --api anthropic # Translate via API")
        if fuzzy_count > 0:
            print(f"  translate_v2.py {args.lang} run --api anthropic --fuzzy  # Re-translate {fuzzy_count} fuzzy")


def cmd_export(args, entries: List[POEntry], script_dir: Path):
    """Export strings for translation in v2 format."""
    # Determine mode
    if args.errors_only:
        mode = 'errors'
    elif args.fuzzy:
        mode = 'fuzzy'
    elif args.all:
        mode = 'all'
    else:
        mode = 'empty'

    to_export = filter_entries(entries, mode)

    if not to_export:
        print(f"Nothing to export (no {mode} strings).")
        return 0

    mode_desc = {'empty': 'empty', 'fuzzy': 'fuzzy', 'all': 'all non-verified', 'errors': 'with validation issues'}

    # Use exports/ directory
    exports_dir = get_exports_dir(script_dir)
    export_path = exports_dir / f"{args.lang}.txt"
    mapping_path = exports_dir / f"{args.lang}_mapping.json"

    # Generate and write output
    count = export_v2_format(args.lang, to_export, export_path, mapping_path,
                             num_batches=args.batches or 0)

    print(f"Exported {count} {mode_desc[mode]} strings to {export_path}")
    print(f"Translate the file, then run: translate_v2.py {args.lang} import")

    return 0


def cmd_import(args, entries: List[POEntry], po_path: Path, script_dir: Path):
    """Import translations from v2 format file."""
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

    if not mapping_path.exists():
        print(f"Error: Mapping file not found: {mapping_path}")
        return 1

    print(f"Importing from {import_path}...")
    translations, errors, warnings, skipped = import_v2_format(
        import_path, mapping_path, entries, auto_fix=not args.no_auto_fix
    )

    if errors:
        print(f"\nValidation errors ({len(errors)}):")
        for err in errors[:10]:
            print(f"  - {err}")
        if len(errors) > 10:
            print(f"  ... and {len(errors) - 10} more")

    if warnings and not args.quiet:
        print(f"\nWarnings ({len(warnings)}):")
        for warn in warnings[:5]:
            print(f"  - {warn}")
        if len(warnings) > 5:
            print(f"  ... and {len(warnings) - 5} more")

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
    if mapping_path.exists() and not args.keep_mapping:
        mapping_path.unlink()
        print(f"Cleaned up: {mapping_path}")

    return 0


def cmd_combine(args, script_dir: Path):
    """Combine batch files into single translated file."""
    exports_dir = get_exports_dir(script_dir)

    # Combine batch files
    combined = BatchManager.combine_from_files(exports_dir, args.lang)

    if not combined:
        print(f"No batch files found for {args.lang}")
        return 1

    # Write combined file
    output_path = exports_dir / f"{args.lang}.txt"

    lang_name = LANGUAGE_NAMES.get(args.lang, args.lang)
    header = generate_v2_header(args.lang, lang_name, len(combined))

    lines = [header, ""]
    for num in sorted(combined.keys()):
        lines.append(f"{num}. {combined[num]}")

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

    print(f"Combined {len(combined)} translations to {output_path}")
    print(f"Now run: translate_v2.py {args.lang} import")

    return 0


def cmd_run(args, entries: List[POEntry], po_path: Path, script_dir: Path):
    """Translate via API."""
    # Check API provider
    if not args.api:
        print("Error: --api required (anthropic or openai)")
        return 1

    provider = args.api.lower()
    if provider not in ('anthropic', 'openai'):
        print(f"Error: Unknown API provider: {provider}")
        print("Supported: anthropic, openai")
        return 1

    # Load API keys
    api_keys = load_api_keys()
    api_key = api_keys.get(provider)

    if not api_key or api_key.startswith("YOUR_"):
        print(f"Error: No valid API key for {provider}")
        print("Set your key in apikeys.lua")
        return 1

    # Determine model
    if args.model:
        model = args.model
    elif provider == 'anthropic':
        model = 'claude-sonnet-4-5-20250929'
    else:
        model = 'gpt-5.2'

    # Determine mode
    if args.errors_only:
        mode = 'errors'
    elif args.fuzzy:
        mode = 'fuzzy'
    elif args.all:
        mode = 'all'
    elif args.new_lang:
        mode = 'all'
    else:
        mode = 'empty'

    to_translate = filter_entries(entries, mode)

    if not to_translate:
        print(f"Nothing to translate (no {mode} strings).")
        return 0

    mode_desc = {'empty': 'empty', 'fuzzy': 'fuzzy', 'all': 'all non-verified', 'errors': 'with validation issues'}
    lang_name = LANGUAGE_NAMES.get(args.lang, args.lang)

    print(f"\n=== Translating {lang_name} ({args.lang}) ===")
    print(f"Strings to translate: {len(to_translate)} ({mode_desc[mode]})")
    print(f"Provider: {provider} ({model})")

    # Confirm
    if not args.yes:
        response = input("\nProceed? [y/N] ").strip().lower()
        if response != 'y':
            print("Cancelled.")
            return 0

    # Build strings dict with newline encoding
    strings = {}
    msgid_by_num = {}
    for i, entry in enumerate(to_translate, 1):
        strings[i] = NewlineHandler.encode(entry.msgid)
        msgid_by_num[i] = entry.msgid

    # Create translator and translate
    translator = APITranslator(provider, model, api_key)

    def progress(batch, total):
        print(f"  Translating batch {batch}/{total}...")

    print()
    results = translator.translate_strings(strings, args.lang, progress_callback=progress)

    # Validate and apply
    translations = {}
    errors = []

    for num, trans_text in results.items():
        source_encoded = strings.get(num, "")
        msgid = msgid_by_num.get(num)

        if not msgid:
            continue

        # Auto-fix
        trans_text, fixes = PlaceholderValidator.auto_fix(source_encoded, trans_text)

        # Validate
        validation_errors = PlaceholderValidator.validate(source_encoded, trans_text)

        if validation_errors:
            for err in validation_errors:
                errors.append(f"#{num}: {err}")
            continue

        # Decode newlines
        final_text = NewlineHandler.decode(trans_text)
        translations[msgid] = final_text

    if errors:
        print(f"\nValidation errors ({len(errors)}):")
        for err in errors[:10]:
            print(f"  - {err}")
        if len(errors) > 10:
            print(f"  ... and {len(errors) - 10} more")

    if not translations:
        print("No valid translations to apply.")
        return 1

    # Apply translations
    for entry in entries:
        if entry.msgid in translations:
            entry.msgstr = translations[entry.msgid]

    # Write with fuzzy markers (ALWAYS for API translations)
    add_fuzzy = set(translations.keys())
    write_po_file(entries, po_path, add_fuzzy_for=add_fuzzy)

    print(f"\nApplied {len(translations)} translations (fuzzy)")
    print(f"Updated: {po_path}")

    return 0


def validate_all_translations(entries: List[POEntry]) -> Tuple[int, int]:
    """Validate all translations in a PO file, return (error_count, warning_count)."""
    errors = 0
    warnings = 0

    for entry in entries:
        if entry.is_header or not entry.msgid or not entry.msgstr:
            continue

        # Encode for validation (same format as export)
        source = NewlineHandler.encode(entry.msgid)
        trans = NewlineHandler.encode(entry.msgstr)

        validation_errors = PlaceholderValidator.validate(source, trans)
        validation_warnings = PlaceholderValidator.validate_warnings(source, trans)

        errors += len(validation_errors)
        warnings += len(validation_warnings)

    return errors, warnings


def cmd_all_status(script_dir: Path, locale_dir: Path):
    """Show compact status for all languages."""
    print("\n=== All Languages Status ===")
    print(f"{'Lang':<7} {'Total':>5} {'Verif':>6} {'Fuzzy':>6} {'Empty':>6} {'Err':>5} {'Warn':>5}")
    print("-" * 49)

    sum_total = 0
    sum_verified = 0
    sum_fuzzy = 0
    sum_empty = 0
    sum_errors = 0
    sum_warnings = 0

    for lang_code in sorted(LANGUAGE_NAMES.keys()):
        po_path = locale_dir / lang_code / "LC_MESSAGES" / "koassistant.po"
        if not po_path.exists():
            print(f"{lang_code:<7} {'MISSING':<5}")
            continue

        entries = parse_po_file(po_path)
        status = get_status(entries)
        errors, warnings = validate_all_translations(entries)

        sum_total += status['total']
        sum_verified += status['verified']
        sum_fuzzy += status['fuzzy']
        sum_empty += status['empty']
        sum_errors += errors
        sum_warnings += warnings

        # Format errors/warnings with color if > 0
        if errors > 0:
            err_str = f"\033[91m{errors:>5}\033[0m"
        else:
            err_str = f"{errors:>5}"
        if warnings > 0:
            warn_str = f"\033[93m{warnings:>5}\033[0m"
        else:
            warn_str = f"{warnings:>5}"

        print(f"{lang_code:<7} {status['total']:>5} {status['verified']:>6} "
              f"{status['fuzzy']:>6} {status['empty']:>6} {err_str} {warn_str}")

    print("-" * 49)
    print(f"{'TOTAL':<7} {sum_total:>5} {sum_verified:>6} {sum_fuzzy:>6} {sum_empty:>6} {sum_errors:>5} {sum_warnings:>5}")

    return 0


def cmd_all_run(args, script_dir: Path, locale_dir: Path):
    """Run translation for all languages."""
    if not args.api:
        print("Error: --api required (anthropic or openai)")
        return 1

    provider = args.api.lower()
    if provider not in ('anthropic', 'openai'):
        print(f"Error: Unknown API provider: {provider}")
        return 1

    # Load API keys
    api_keys = load_api_keys()
    api_key = api_keys.get(provider)

    if not api_key or api_key.startswith("YOUR_"):
        print(f"Error: No valid API key for {provider}")
        print("Set your key in apikeys.lua")
        return 1

    # Determine model
    if args.model:
        model = args.model
    elif provider == 'anthropic':
        model = 'claude-sonnet-4-5-20250929'
    else:
        model = 'gpt-5.2'

    # Determine mode
    if args.errors_only:
        mode = 'errors'
    elif args.fuzzy:
        mode = 'fuzzy'
    elif args.all:
        mode = 'all'
    else:
        mode = 'empty'

    mode_desc = {'empty': 'empty', 'fuzzy': 'fuzzy', 'all': 'all non-verified', 'errors': 'with validation issues'}

    print(f"\n=== Translating All Languages ===")
    print(f"Mode: {mode_desc[mode]}")
    print(f"Provider: {provider} ({model})")

    # Collect languages that need work
    languages_to_process = []
    for lang_code in sorted(LANGUAGE_NAMES.keys()):
        po_path = locale_dir / lang_code / "LC_MESSAGES" / "koassistant.po"
        if not po_path.exists():
            continue

        entries = parse_po_file(po_path)
        to_translate = filter_entries(entries, mode)

        if to_translate:
            languages_to_process.append((lang_code, len(to_translate), po_path, entries))

    if not languages_to_process:
        print(f"\nNo languages have {mode_desc[mode]} strings to translate.")
        return 0

    total_strings = sum(count for _, count, _, _ in languages_to_process)
    print(f"\nLanguages to process: {len(languages_to_process)}")
    print(f"Total strings: {total_strings}")

    # Confirm
    if not args.yes:
        response = input("\nProceed? [y/N] ").strip().lower()
        if response != 'y':
            print("Cancelled.")
            return 0

    # Process each language
    translator = APITranslator(provider, model, api_key)
    success_count = 0
    fail_count = 0

    for lang_code, count, po_path, entries in languages_to_process:
        lang_name = LANGUAGE_NAMES.get(lang_code, lang_code)
        print(f"\n--- {lang_name} ({lang_code}): {count} strings ---")

        to_translate = filter_entries(entries, mode)

        # Build strings dict (same pattern as cmd_run)
        strings = {}
        msgid_by_num = {}
        for i, entry in enumerate(to_translate, 1):
            strings[i] = NewlineHandler.encode(entry.msgid)
            msgid_by_num[i] = entry.msgid

        try:
            results = translator.translate_strings(strings, lang_code)

            # Build translations dict
            translations = {}
            add_fuzzy = set()

            for num, trans_text in results.items():
                source_encoded = strings.get(num, "")
                msgid = msgid_by_num.get(num)
                if not msgid:
                    continue

                # Auto-fix and decode
                trans_text, _ = PlaceholderValidator.auto_fix(source_encoded, trans_text)
                final_text = NewlineHandler.decode(trans_text)
                translations[msgid] = final_text
                add_fuzzy.add(msgid)

            # Apply translations
            for entry in entries:
                if entry.msgid in translations:
                    entry.msgstr = translations[entry.msgid]

            # Write back
            write_po_file(entries, po_path, add_fuzzy_for=add_fuzzy)
            print(f"  Applied {len(translations)} translations")
            success_count += 1

        except Exception as e:
            print(f"  ERROR: {e}")
            fail_count += 1

    print(f"\n=== Complete ===")
    print(f"Success: {success_count} languages")
    if fail_count:
        print(f"Failed: {fail_count} languages")

    return 0 if fail_count == 0 else 1


def cmd_multi_run(args, langs: List[str], script_dir: Path, locale_dir: Path):
    """Run translation for specified languages (comma-separated)."""
    if not args.api:
        print("Error: --api required (anthropic or openai)")
        return 1

    provider = args.api.lower()
    if provider not in ('anthropic', 'openai'):
        print(f"Error: Unknown API provider: {provider}")
        return 1

    # Load API keys
    api_keys = load_api_keys()
    api_key = api_keys.get(provider)

    if not api_key or api_key.startswith("YOUR_"):
        print(f"Error: No valid API key for {provider}")
        print("Set your key in apikeys.lua")
        return 1

    # Determine model
    if args.model:
        model = args.model
    elif provider == 'anthropic':
        model = 'claude-sonnet-4-5-20250929'
    else:
        model = 'gpt-5.2'

    # Determine mode
    if args.errors_only:
        mode = 'errors'
    elif args.fuzzy:
        mode = 'fuzzy'
    elif args.all:
        mode = 'all'
    else:
        mode = 'empty'

    mode_desc = {'empty': 'empty', 'fuzzy': 'fuzzy', 'all': 'all non-verified', 'errors': 'with validation issues'}

    print(f"\n=== Translating {len(langs)} Languages ===")
    print(f"Languages: {', '.join(langs)}")
    print(f"Mode: {mode_desc[mode]}")
    print(f"Provider: {provider} ({model})")

    # Collect languages that need work
    languages_to_process = []
    for lang_code in langs:
        if lang_code not in LANGUAGE_NAMES:
            print(f"Warning: Unknown language code '{lang_code}', skipping")
            continue

        po_path = locale_dir / lang_code / "LC_MESSAGES" / "koassistant.po"
        if not po_path.exists():
            print(f"Warning: PO file not found for '{lang_code}', skipping")
            continue

        entries = parse_po_file(po_path)
        to_translate = filter_entries(entries, mode)

        if to_translate:
            languages_to_process.append((lang_code, len(to_translate), po_path, entries))
        else:
            print(f"  {lang_code}: No {mode_desc[mode]} strings")

    if not languages_to_process:
        print(f"\nNo languages have {mode_desc[mode]} strings to translate.")
        return 0

    total_strings = sum(count for _, count, _, _ in languages_to_process)
    print(f"\nLanguages to process: {len(languages_to_process)}")
    print(f"Total strings: {total_strings}")

    # Confirm
    if not args.yes:
        response = input("\nProceed? [y/N] ").strip().lower()
        if response != 'y':
            print("Cancelled.")
            return 0

    # Process each language
    translator = APITranslator(provider, model, api_key)
    success_count = 0
    fail_count = 0

    for lang_code, count, po_path, entries in languages_to_process:
        lang_name = LANGUAGE_NAMES.get(lang_code, lang_code)
        print(f"\n--- {lang_name} ({lang_code}): {count} strings ---")

        to_translate = filter_entries(entries, mode)

        # Build strings dict (same pattern as cmd_run)
        strings = {}
        msgid_by_num = {}
        for i, entry in enumerate(to_translate, 1):
            strings[i] = NewlineHandler.encode(entry.msgid)
            msgid_by_num[i] = entry.msgid

        try:
            results = translator.translate_strings(strings, lang_code)

            # Build translations dict
            translations = {}
            add_fuzzy = set()

            for num, trans_text in results.items():
                source_encoded = strings.get(num, "")
                msgid = msgid_by_num.get(num)
                if not msgid:
                    continue

                # Auto-fix and decode
                trans_text, _ = PlaceholderValidator.auto_fix(source_encoded, trans_text)
                final_text = NewlineHandler.decode(trans_text)
                translations[msgid] = final_text
                add_fuzzy.add(msgid)

            # Apply translations
            for entry in entries:
                if entry.msgid in translations:
                    entry.msgstr = translations[entry.msgid]

            # Write back
            write_po_file(entries, po_path, add_fuzzy_for=add_fuzzy)
            print(f"  Applied {len(translations)} translations")
            success_count += 1

        except Exception as e:
            print(f"  ERROR: {e}")
            fail_count += 1

    print(f"\n=== Complete ===")
    print(f"Success: {success_count} languages")
    if fail_count:
        print(f"Failed: {fail_count} languages")

    return 0 if fail_count == 0 else 1


def cmd_clean(args, script_dir: Path):
    """Clean up export files."""
    exports_dir = script_dir / "exports"

    if not exports_dir.exists():
        print("Exports directory doesn't exist.")
        return 0

    # Find files to delete
    if args.lang == "all":
        # Delete all files
        files = list(exports_dir.glob("*.txt")) + list(exports_dir.glob("*.json"))
    else:
        # Delete only files for this language
        files = list(exports_dir.glob(f"{args.lang}*.txt")) + list(exports_dir.glob(f"{args.lang}*.json"))

    if not files:
        print("No export files to clean.")
        return 0

    print(f"Files to delete ({len(files)}):")
    for f in sorted(files)[:10]:
        print(f"  {f.name}")
    if len(files) > 10:
        print(f"  ... and {len(files) - 10} more")

    # Confirm
    if not args.yes:
        response = input("\nDelete these files? [y/N] ").strip().lower()
        if response != 'y':
            print("Cancelled.")
            return 0

    # Delete
    for f in files:
        f.unlink()

    print(f"Deleted {len(files)} files.")
    return 0

# ============================================================================
# Main
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="KOAssistant Translation Tool v2 (Simplified AI Interface)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  translate_v2.py de                    # Status for German
  translate_v2.py all                   # Status for all languages
  translate_v2.py de export             # Export empty strings
  translate_v2.py de export --all       # Export all unverified
  translate_v2.py de export --batches=8 # Split into 8 batch files
  translate_v2.py de import             # Import translations
  translate_v2.py de combine            # Combine batch files
  translate_v2.py de run --api anthropic             # Translate German via API
  translate_v2.py ar,zh,ja run --api anthropic       # Translate multiple languages
  translate_v2.py all run --api anthropic --errors-only  # Fix errors in all languages
  translate_v2.py de clean              # Clean export files for German
  translate_v2.py all clean             # Clean all export files

Translation modes:
  (default)     Empty strings only - incremental update
  --fuzzy       Fuzzy only - quality improvement
  --all         All non-verified - full re-translation
  --errors-only Only strings with validation errors/warnings - targeted fix
  --new-lang    All strings - new language (creates directory)

ALL AI translations are marked fuzzy. Verified translations are never touched.
        """
    )

    parser.add_argument("lang", help="Language code (de, fr, etc.) or 'all'")
    parser.add_argument("command", nargs="?", default="status",
                        choices=["status", "export", "import", "combine", "run", "clean"],
                        help="Command (default: status)")
    parser.add_argument("file", nargs="?", help="Optional file for import")

    # Export options
    parser.add_argument("--all", action="store_true", help="Include all non-verified strings")
    parser.add_argument("--fuzzy", action="store_true", help="Include only fuzzy strings")
    parser.add_argument("--errors-only", action="store_true", help="Only strings with validation errors/warnings")
    parser.add_argument("--batches", type=int, help="Split into N batch files")
    parser.add_argument("--new-lang", action="store_true", help="New language (translate all)")

    # Import options
    parser.add_argument("--verified", action="store_true", help="Mark as human-verified")
    parser.add_argument("--yes", "-y", action="store_true", help="Skip confirmation")
    parser.add_argument("--no-auto-fix", action="store_true", help="Disable placeholder auto-fix")
    parser.add_argument("--keep-mapping", action="store_true", help="Keep mapping file after import")
    parser.add_argument("--quiet", "-q", action="store_true", help="Suppress warnings")

    # API options
    parser.add_argument("--api", help="API provider (anthropic or openai)")
    parser.add_argument("--model", help="Model name (e.g., claude-sonnet-4-5, gpt-4o)")

    args = parser.parse_args()

    # Find paths
    script_dir = Path(__file__).parent
    locale_dir = script_dir.parent / "locale"

    # Handle 'all' language code
    if args.lang == "all":
        if args.command == "status":
            sys.exit(cmd_all_status(script_dir, locale_dir))
        elif args.command == "clean":
            sys.exit(cmd_clean(args, script_dir))
        elif args.command == "run":
            sys.exit(cmd_all_run(args, script_dir, locale_dir))
        else:
            print(f"Error: 'all' only supports status, clean, and run commands")
            sys.exit(1)

    # Handle comma-separated language codes (e.g., "ar,zh,ja")
    if ',' in args.lang:
        langs = [l.strip() for l in args.lang.split(',')]
        if args.command == "run":
            # Filter to just the specified languages
            args.lang = "all"  # Reuse all_run logic
            sys.exit(cmd_multi_run(args, langs, script_dir, locale_dir))
        else:
            print(f"Error: Multiple languages only supported for 'run' command")
            sys.exit(1)

    # Validate language
    if args.lang not in LANGUAGE_NAMES:
        print(f"Warning: Unknown language code '{args.lang}'")

    # Find PO file
    po_path = locale_dir / args.lang / "LC_MESSAGES" / "koassistant.po"

    # Handle new language
    if args.new_lang and not po_path.exists():
        print(f"Creating new language directory for {args.lang}...")
        po_path.parent.mkdir(parents=True, exist_ok=True)

        # Copy from template
        pot_path = locale_dir / "koassistant.pot"
        if pot_path.exists():
            import shutil
            shutil.copy(pot_path, po_path)
            print(f"Created {po_path} from template")
        else:
            print(f"Error: Template not found: {pot_path}")
            sys.exit(1)

    if not po_path.exists():
        print(f"Error: PO file not found: {po_path}")
        print(f"Use --new-lang to create a new language")
        sys.exit(1)

    # Parse PO file
    entries = parse_po_file(po_path)

    # Dispatch command
    if args.command == "status":
        cmd_status(args, entries)
    elif args.command == "export":
        sys.exit(cmd_export(args, entries, script_dir))
    elif args.command == "import":
        sys.exit(cmd_import(args, entries, po_path, script_dir))
    elif args.command == "combine":
        sys.exit(cmd_combine(args, script_dir))
    elif args.command == "run":
        sys.exit(cmd_run(args, entries, po_path, script_dir))
    elif args.command == "clean":
        sys.exit(cmd_clean(args, script_dir))


if __name__ == "__main__":
    main()

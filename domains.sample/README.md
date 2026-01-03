# Creating Custom Domains

Domains provide background knowledge context for AI conversations. When you select a domain, its context is included in every message, helping the AI understand the subject area and respond appropriately.

## Setup

1. Create a `domains/` folder in your plugin directory (next to this `domains.sample/` folder)
2. Add `.md` or `.txt` files to define your domains
3. Restart KOReader to load new domains

## File Format

Each domain is a single file:

- **Filename** = Domain ID (e.g., `research.md` creates domain ID `research`)
- **First line** = Optional `# Heading` for display name
- **Rest of file** = Context text sent to the AI

### Example: `research.md`

```markdown
# Research

This conversation relates to academic research and analysis.
Focus on critical thinking, source evaluation, and evidence-based reasoning.
When discussing claims, consider the strength of evidence and potential biases.
```

### Without a Heading

If you don't include a `# Heading`, the display name is derived from the filename:
- `islamic_studies.md` → "Islamic Studies"
- `language_learning.md` → "Language Learning"

## Tips

- **Keep it concise**: Domain context is added to every message, which increases API costs. Aim for 200-500 tokens.
- **Focus on key concepts**: Tell the AI what subject area this is, what to focus on, and any special considerations.
- **Be specific**: Vague instructions like "be helpful" don't add value. Instead, specify what kind of help is needed.

## Sample Files

Copy files from this folder to `domains/` and customize them:
- `research.md` → `domains/research.md`
- `literature.md` → `domains/literature.md`

## Note

The `domains/` folder is gitignored to keep your custom domains private and separate from the plugin code.

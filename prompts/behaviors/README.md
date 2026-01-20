# Built-in Behaviors

This folder contains built-in behavior definitions shipped with KOAssistant.

## Current Built-ins

- **mini.md** (~220 tokens) - Concise guidance for e-reader conversations
- **standard.md** (~420 tokens) - Balanced guidance for quality responses (default)
- **full.md** (~1150 tokens) - Comprehensive Claude-style guidance
- **research_standard.md** (~470 tokens) - Research-focused with source transparency
- **translator_direct.md** (~80 tokens) - Direct translation without commentary

## Adding Built-in Behaviors

Create `.md` or `.txt` files in this folder:

```markdown
# Behavior Name
<!--
Source: Based on / Adapted from / Custom
Tokens: ~300
Notes: Description of the behavior's purpose
-->

Behavior text that will be sent to the AI as system prompt...
```

- **Filename** becomes the behavior ID (e.g., `concise.md` → ID `concise`)
- **First line** `# Name` sets the display name (optional, defaults to filename)
- **Metadata comments** `<!-- ... -->` are stripped before sending to AI
- **Rest of file** is the behavior text

## Priority

User behaviors in `behaviors/` folder override built-in behaviors with the same ID.

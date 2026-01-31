# Built-in Domains

This folder contains built-in domain definitions shipped with KOAssistant.

## Current Built-in Domain

**Interdisciplinary Synthesis** ([synthesis.md](synthesis.md))
Comprehensive knowledge framework spanning philosophy (ancient through contemporary), depth psychology (Jungian focus), contemplative traditions (Islamic Sufism, Buddhism, Christian mysticism, Taoism, Hindu Vedanta), natural sciences and cosmology, arts and symbolism. Provides methodological principles for cross-traditional dialogue, conceptual bridges between frameworks, and integration protocols.

This serves as a demonstration of what a substantial domain looks like—providing specialized knowledge, frameworks, and terminology rather than just instructions about communication style.

## Adding Built-in Domains

Create `.md` or `.txt` files in this folder:

```markdown
# Domain Name
<!--
Tokens: ~300
Notes: Description of the domain's purpose
-->

Domain context text that will be sent to the AI...
```

- **Filename** becomes the domain ID (e.g., `research.md` → ID `research`)
- **First line** `# Name` sets the display name (optional, defaults to filename)
- **Metadata comments** `<!-- ... -->` are stripped before sending to AI
- **Rest of file** is the domain context

## Priority

User domains in `domains/` folder override built-in domains with the same ID.

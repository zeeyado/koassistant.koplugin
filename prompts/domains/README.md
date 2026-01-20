# Built-in Domains

This folder contains built-in domain definitions shipped with KOAssistant.

## Adding Built-in Domains

Create `.md` or `.txt` files in this folder:

```markdown
# Domain Name
<!--
Source: Built-in
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

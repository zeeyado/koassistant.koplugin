# Creating Custom Behaviors

Behaviors define the AI's personality and communication style. When you select a behavior, it guides how the AI responds to your questions.

## Setup

1. Create a `behaviors/` folder in your plugin directory (next to this `behaviors.sample/` folder)
2. Add `.md` or `.txt` files to define your behaviors
3. Restart KOReader to load new behaviors

## File Format

Each behavior is a single file:

- **Filename** = Behavior ID (e.g., `concise.md` creates behavior ID `concise`)
- **First line** = Optional `# Heading` for display name
- **Rest of file** = Behavior instructions sent to the AI

### Example: `concise.md`

```markdown
# Concise Expert

You are a knowledgeable assistant who values brevity.
Give direct, precise answers without unnecessary elaboration.
Use technical terms when appropriate but explain them if asked.
Avoid filler phrases and get straight to the point.
```

### Without a Heading

If you don't include a `# Heading`, the display name is derived from the filename:
- `concise_expert.md` -> "Concise Expert"
- `creative_writer.md` -> "Creative Writer"

## Tips

- **Keep it focused**: Behavior text is added to every message, increasing API costs. Aim for 100-300 tokens.
- **Be specific**: Instead of "be helpful", specify how to be helpful (concise? detailed? formal?).
- **Define personality**: Include tone (warm, professional, casual) and communication style.
- **Set boundaries**: Mention what the AI should avoid (e.g., "avoid excessive formatting").

## Built-in Behaviors

The plugin includes two built-in behaviors:
- **Minimal** (~100 tokens): Conversational, natural responses with minimal formatting
- **Full** (~500 tokens): Comprehensive guidelines for academic and literary discussions

Your custom behaviors appear alongside these in the settings menu.

## Sample Files

Copy files from this folder to `behaviors/` and customize them:
- `concise.md` -> `behaviors/concise.md`
- `creative.md` -> `behaviors/creative.md`

## Note

The `behaviors/` folder is gitignored to keep your custom behaviors private and separate from the plugin code.

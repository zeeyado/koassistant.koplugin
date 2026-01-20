# AI Behaviors for KOAssistant

Behaviors define the AI's personality and communication style. This folder contains a comprehensive collection of sample behaviors you can use or customize.

## Quick Start

1. Create a `behaviors/` folder in your plugin directory (next to `behaviors.sample/`)
2. Copy behaviors you want to use: `cp behaviors.sample/claude_style_standard.md behaviors/`
3. Restart KOReader to load new behaviors
4. Select your behavior in Settings > AI Behavior

## Size Tiers

Behaviors come in different sizes to balance quality vs. token cost:

| Size | Tokens | Best For |
|------|--------|----------|
| `_mini` | ~100-150 | Quick interactions, cost-sensitive |
| `_standard` | ~300-500 | Good balance of guidance and efficiency |
| `_extended` | ~1000-2000 | Richer guidance for complex discussions |
| `_complete` | ~2000+ | Full experience with comprehensive guidelines |

**Recommendation**: Start with `_standard` versions. Move to `_mini` if costs are a concern, or `_complete` for best quality.

## Provider-Inspired Styles

These behaviors capture the communication style of popular AI providers, adapted to be **provider-agnostic** (they work with any AI model).

| Style | Character | Best For |
|-------|-----------|----------|
| `claude_style_*` | Thoughtful, balanced, prose-focused | Deep analysis, nuanced discussions |
| `gpt_style_*` | Helpful, warm, comprehensive | General help, structured explanations |
| `gemini_style_*` | Professional, neutral, informative | Factual queries, practical tasks |
| `grok_style_*` | Direct, witty, unfiltered | Straight answers, technical topics |
| `perplexity_style_*` | Research-focused, citation-aware | Research, fact-checking |
| `deepseek_style_*` | Analytical, step-by-step | Complex reasoning, analysis |

### Size Variants Available

Each provider style has three sizes:
- `{provider}_style_mini.md` - Core principles only
- `{provider}_style_standard.md` - Balanced guidance
- `{provider}_style_complete.md` - Comprehensive experience

## Reading-Specialized Behaviors

Designed specifically for book reading and literary analysis:

| Behavior | Sizes | Best For |
|----------|-------|----------|
| `scholarly_*` | mini, standard, extended | Academic texts, literary analysis, serious study |
| `translator_*` | standard | Literary translation with nuance preservation |
| `religious_*` | standard, extended | Sacred texts, classical works, philosophy |
| `creative_*` | standard | Fiction analysis, narrative craft discussion |

## Built-in Behaviors

The plugin includes four built-in behaviors (always available without copying):

- **Minimal** (~100 tokens) - Conversational, natural, minimal formatting
- **Full** (~500 tokens) - Comprehensive Claude-style guidelines
- **Concise** (~50 tokens) - Brief, direct answers
- **Scholarly** (~400 tokens) - Rigorous textual analysis

## Recommendations by Use Case

**General Reading & Chat**
- Start with `claude_style_standard.md` or built-in "Full"
- For lower token cost: `claude_style_mini.md` or built-in "Minimal"

**Research & Information**
- `perplexity_style_standard.md` - Emphasizes sources and thoroughness
- `gemini_style_standard.md` - Balanced, neutral information

**Academic/Literary Study**
- `scholarly_standard.md` or `scholarly_extended.md`
- Built-in "Scholarly" for quick access

**Quick Lookups**
- Built-in "Concise" (fastest)
- `grok_style_mini.md` - Direct, no hedging

**Translation Work**
- `translator_standard.md` - Nuance-preserving translation

**Religious/Classical Texts**
- `religious_standard.md` or `religious_extended.md`

**Fiction Discussion**
- `creative_standard.md` - Focuses on narrative craft

**Direct, Honest Responses**
- `grok_style_standard.md` - Witty and unfiltered

## File Format

Each behavior file:
- **Filename** = Behavior ID (e.g., `scholarly_standard.md` = ID `scholarly_standard`)
- **First line** = `# Display Name` (optional heading)
- **Rest of file** = Instructions sent to the AI

### Creating Custom Behaviors

```markdown
# My Custom Style

You are a helpful assistant who...

[Your instructions here]
```

### Tips

- **Keep it focused**: Behavior text is sent with every message
- **Be specific**: Define exactly how you want the AI to communicate
- **Include negatives**: What to avoid is as important as what to do
- **Test and iterate**: Try different approaches to find what works

## Reference Folder

The `reference/` subfolder contains documentation about original provider system prompts - where to find them, key characteristics, and links to sources. Use these if you want to understand the basis for the adapted styles.

## Note

The `behaviors/` folder is gitignored to keep your customizations private and separate from plugin updates.

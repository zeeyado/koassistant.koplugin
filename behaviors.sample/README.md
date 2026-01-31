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
| `_mini` | ~160-190 | Quick interactions, cost-sensitive |
| `_standard` | ~380-500 | Good balance of guidance and efficiency |
| `_extended` | ~990-1200 | Richer guidance for complex discussions |
| `_full` | ~1150-1325 | Most comprehensive guidelines |

**Recommendation**: Start with `_standard` versions. Move to `_mini` if costs are a concern, or `_full` for richer guidance.

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
- `{provider}_style_mini.md` - Core principles only (~160-190 tokens)
- `{provider}_style_standard.md` - Balanced guidance (~430-470 tokens)
- `{provider}_style_full.md` - Comprehensive guidelines (~1150-1325 tokens)

## Reading-Specialized Behaviors

Designed specifically for book reading and literary analysis:

| Behavior | Sizes | Best For |
|----------|-------|----------|
| `scholarly_*` | mini, standard, extended | Academic texts, literary analysis, serious study |
| `translator_*` | standard | Literary translation with nuance preservation |
| `religious_*` | standard, extended | Sacred texts, classical works, philosophy |
| `creative_*` | standard | Fiction analysis, narrative craft discussion |

## Built-in Behaviors

Five built-in behaviors are always available (based on [Anthropic Claude guidelines](https://docs.anthropic.com/en/release-notes/system-prompts)):

- **Mini** (~220 tokens) - Concise guidance for e-reader conversations
- **Standard** (~420 tokens) - Balanced guidance for quality responses
- **Full** (~1150 tokens) - Comprehensive guidance for best quality responses
- **Research Standard** (~470 tokens) - Research-focused with source transparency
- **Translator Direct** (~80 tokens) - Direct translation without commentary

The samples in this folder offer alternative styles (GPT, Gemini, Grok, etc.) and specialized behaviors (scholarly, religious, creative).

## Recommendations by Use Case

**General Reading & Chat**
- Start with built-in "Standard" or `claude_style_standard.md`
- For lower token cost: built-in "Mini" or `claude_style_mini.md`

**Research & Information**
- `perplexity_style_standard.md` - Emphasizes sources and thoroughness
- `gemini_style_standard.md` - Balanced, neutral information

**Academic/Literary Study**
- `scholarly_standard.md` or `scholarly_extended.md`

**Quick Lookups**
- Built-in "Mini" or `grok_style_mini.md` - Direct, no hedging

**Translation Work**
- Built-in "Translator Direct" for simple translations
- `translator_standard.md` for literary translation with context

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

## Combining Behaviors with Domains

Behaviors and domains work together:
- **Behavior** = HOW the AI communicates (tone, style, formatting)
- **Domain** = WHAT context it has (subject matter expertise)

**Example combinations:**
- `scholarly_standard` + Islamic Studies domain → Rigorous academic analysis of religious texts
- `creative_standard` + your fiction project domain → Craft-focused discussion of your novel
- `perplexity_style_standard` + Research domain → Source-focused research assistance

**Pro tip:** Create domain-specific behaviors for specialized needs. If you have a Philosophy domain, consider a `philosophy_analytical.md` behavior that emphasizes logical argumentation, or if you're doing language learning, a behavior that explains grammar patterns.

The system prompt sent to the AI is: **Behavior + Domain + Language instruction**. Experiment with different combinations to find what works best for your reading.

## Reference Folder

The `reference/` subfolder contains documentation about original provider system prompts - where to find them, key characteristics, and links to sources.

**Why reference files instead of full prompts?**
1. **Prompts change frequently** - Providers update regularly; static copies become outdated
2. **Length** - Full prompts are often 20,000+ tokens, impractical for e-reader use
3. **Provider-specific** - Original prompts reference tools/features that don't apply here

**For KOAssistant**, use the adapted provider-style behaviors (e.g., `claude_style_standard.md`) instead. These extract essential communication style, are provider-agnostic, appropriately sized, and focused on reading/conversation rather than tool usage.

**Finding current prompts:**
- Anthropic: https://docs.anthropic.com/en/release-notes/system-prompts
- Community collections: [CL4R1T4S](https://github.com/elder-plinius/CL4R1T4S), [leaked-system-prompts](https://github.com/jujumilk3/leaked-system-prompts)

Each reference file describes the provider's style, where to find current prompts, and key characteristics extracted for adapted versions.

## Note

The `behaviors/` folder is gitignored to keep your customizations private and separate from plugin updates.

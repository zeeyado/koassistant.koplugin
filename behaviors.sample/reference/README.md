# Original Provider System Prompts - Reference

This folder contains information about the original system prompts used by various AI providers. These are provided for **documentation and reference only**.

## Why Reference Files Instead of Full Prompts?

1. **Prompts change frequently** - Providers update their prompts regularly. Static copies become outdated.
2. **Length** - Full prompts are often 20,000+ tokens, impractical for e-reader use.
3. **Provider-specific** - Original prompts reference specific tools and features that don't apply here.

## Recommended Approach

For KOAssistant, use the **adapted provider-style behaviors** (e.g., `claude_style_standard.md`) instead of original prompts. These:
- Extract the essential communication style and principles
- Are provider-agnostic (work with any AI model)
- Are appropriately sized for efficient token usage
- Focus on reading/conversation behaviors, not tool usage

## Finding Original Prompts

If you want to see the actual current prompts:

### Official Sources
- **Anthropic**: https://docs.anthropic.com/en/release-notes/system-prompts

### Community Collections
- **CL4R1T4S**: https://github.com/elder-plinius/CL4R1T4S
- **leaked-system-prompts**: https://github.com/jujumilk3/leaked-system-prompts

### What's Available
Each reference file below describes:
- What the provider's style is like
- Where to find current prompts
- Key characteristics extracted for the adapted versions

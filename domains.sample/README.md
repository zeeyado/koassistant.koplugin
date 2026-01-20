# Sample Domains

Example domain files showing different approaches and sizes.

These are all relatively small in size. I personally use gigantic interdisciplinary ones (thousands of lines), but they cost more.

Focused ones are good for very specific reading contexts (for instance help reading a classical text).

## About Domains

Domains provide **context** for AI conversations—background knowledge, interpretive frameworks, or methodological orientations. Unlike behaviors (which set *how* the AI communicates), domains set *what* the AI understands about your reading context.

**Key difference from behaviors:**
- **Behavior** = Communication style (tone, formatting, personality)
- **Domain** = Subject matter expertise and interpretive approach

## Built-in Domain

One domain is built-in and always available:

**Critical Reader** (~250 tokens)
Analytical stance for evaluating arguments and evidence. Focuses on argument structure, evidence quality, rhetorical moves, source assessment. Not cynicism—calibrated epistemic confidence.

This built-in serves as an example. Copy it to `domains/` and customize, or explore the samples below for different approaches.

## Included Samples

### Language & Text Support

**`classical_arabic.md`** (~350 tokens)
Reading assistance for Classical Arabic texts (Quranic, literary, scholarly). Provides grammatical parsing (إعراب), morphological analysis (صرف), vocabulary support, and rhetorical features (بلاغة). For students working through Arabic with support.

**`classical_chinese.md`** (~350 tokens)
Reading assistance for Literary Chinese (文言文). Covers character analysis, classical grammar and function words (虛詞), parallelism, and contextual framing for philosophical, poetic, and historical texts.

### Interpretive Frameworks

**`synthesis.md`** (~450 tokens)
Interdisciplinary reading drawing on depth psychology (Jung), contemplative traditions (Sufism, Taoism, Buddhism, Christian mysticism), philosophy (Western and Islamic), and scientific cosmology. For exploring connections across traditions without forcing false equivalences.

**`depth_reading.md`** (~350 tokens)
Psychological approach to fiction—character as psyche, symbolic patterns, narrative structure, what the text can't say about itself. Draws on psychoanalytic criticism and close reading.

**`contemplative_reading.md`** (~300 tokens)
Slow, meditative approach to wisdom literature and philosophical texts. Reading for transformation rather than information. Appropriate for spiritual texts, philosophy, poetry.

**`history_of_ideas.md`** (~350 tokens)
Historical reading of scientific and philosophical texts. Situates ideas in their conceptual world—what problems they were solving, what resources were available, what paths weren't taken.

### Critical Approaches

**`critical_reader.md`** (~250 tokens)
Analytical stance for evaluating arguments and evidence. Same as the built-in version—included here as a template to customize.

### Meta

**`mediated_mind.md`** (~400 tokens)
Reflection on the strangeness of using AI for understanding. Acknowledges the epistemic situation—an AI trained on textual residue discussing consciousness, experience, wisdom. Makes the mediated nature of the conversation explicit.

## Choosing Domain Size

**Small domains** (~100-200 tokens): Quick orientation, minimal cost overhead, good for casual use.

**Medium domains** (~300-500 tokens): Detailed guidance, good balance of context and cost.

**Large domains** (~500-1000+ tokens): Comprehensive frameworks, best for sustained work in a specific area. Anthropic's prompt caching makes these cost-effective for extended conversations.

## Creating Your Own

### Quick Start

1. Copy a sample to `domains/your_domain.md`
2. Edit to fit your reading interests
3. Be specific—"be helpful" adds nothing; "parse Arabic grammar with attention to i'rab" adds value

### File Format

```markdown
# Domain Name
<!--
Tokens: ~300
Notes: Brief description of what this domain does
-->

Your domain content here. This text is sent to the AI
as context for every message in the conversation.
```

**Required:**
- First line: `# Domain Name` (becomes display name)
- Content: The actual context/instructions

**Optional metadata** (in HTML comment, stripped before sending to AI):
- `Tokens`: Approximate token count (helps you track costs)
- `Notes`: Brief description (shown in domain details view)

### Tips

- **Be specific**: Vague instructions waste tokens; specific ones guide the AI
- **Set expectations**: Tell the AI what kind of text you'll share and what you want from it
- **Include examples**: "When I share a passage, analyze X, Y, Z" is clearer than "analyze passages"
- **Domain content is sent with every message**: Keep it focused on what's consistently relevant

## Combining Domains with Behaviors

Domains and behaviors work together:
- A `scholarly_standard` behavior + a Philosophy domain = Rigorous academic analysis of philosophical texts
- A `grok_style_mini` behavior + Critical Reader domain = Direct, no-hedging evaluation of arguments

The system prompt sent to the AI is: **Behavior + Domain + Language instruction**. Experiment with different combinations.

## Note

The `domains/` folder is gitignored to keep your customizations private and separate from plugin updates.

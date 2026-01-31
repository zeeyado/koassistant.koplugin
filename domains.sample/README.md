# Sample Domains

Example domain files demonstrating what domains should be: **specialized knowledge contexts** that provide the AI with domain expertise, terminology, frameworks, and methodological approaches.

## What Are Domains?

Domains provide **context** for AI conversations—background knowledge, interpretive frameworks, specialized terminology, or methodological orientations. Unlike behaviors (which set *how* the AI communicates), domains set *what* the AI knows about your reading context.

**Key difference from behaviors:**
- **Behavior** = Communication style (tone, formatting, personality, reading stance)
- **Domain** = Subject matter expertise, specialized knowledge, and interpretive frameworks

Think of domains like the "Projects" feature in Claude.ai—persistent context about what you're working on. When you activate a domain, you're essentially saying: "I'm working in this area of knowledge, and I need expertise in these frameworks and terminology."

## Domain Philosophy

**Domains are knowledge contexts, not reading attitudes.**

Good domains provide:
- ✅ Specialized vocabulary and terminology
- ✅ Methodological frameworks and analytical tools
- ✅ Domain-specific knowledge the AI wouldn't otherwise emphasize
- ✅ Interpretive traditions and scholarly sources
- ✅ Technical precision in a specific field

Domains are NOT (only, but can include):
- ❌ Merely instructions about how to read (critical, contemplative, slow, etc.)
- ❌ Communication style preferences (those are behaviors)
- ❌ Meta-reflection on the reading experience
- ❌ General advice about being helpful or thorough

**Test:** Does this provide specialized knowledge, or does it just tell the AI to adopt a certain stance? If the latter, it may be better as a behavior, not a domain.

## Built-in Domain

One domain is built-in and always available:

**Synthesis** (~1100 tokens)
Comprehensive knowledge framework spanning philosophy (ancient through contemporary), depth psychology (Jungian focus), contemplative traditions (Islamic Sufism, Buddhism, Christian mysticism, Taoism, Hindu Vedanta), natural sciences and cosmology, arts and symbolism. Provides methodological principles for cross-traditional dialogue, conceptual bridges between frameworks, and integration protocols. Demonstrates what a substantial domain looks like.

This built-in serves as a reference example. You can override it by creating `synthesis.md` in your `domains/` folder, or explore the samples below for different approaches.

## Included Samples

### Language Support Domains

**`classical_arabic.md`** (~350 tokens)
Reading assistance for Classical Arabic texts (Quranic, literary, scholarly). Provides grammatical parsing (إعراب), morphological analysis (صرف), vocabulary support with root meanings, and rhetorical features (بلاغة). For students working through Arabic texts with linguistic support.

**`classical_chinese.md`** (~350 tokens)
Reading assistance for Literary Chinese (文言文). Covers character analysis and etymology, classical grammar and function words (虛詞), parallelism and rhythmic patterns, and contextual framing for philosophical, poetic, and historical texts.

### Interdisciplinary Frameworks

**`synthesis.md`** (~1100 tokens)
Identical to the built-in synthesis domain. Included as a sample to demonstrate a comprehensive interdisciplinary framework and as a starting point for customization. You can copy this to your `domains/` folder and modify it to emphasize different traditions or add your own frameworks.

## Domain Sizes and Token Economy

**Small domains** (~100-300 tokens)
Quick orientation, minimal cost overhead, good for focused assistance in a single area (like language support).

**Medium domains** (~300-800 tokens)
Balanced approach with detailed guidance. Good for specialized knowledge areas that need methodological frameworks.

**Large domains** (~800-1500+ tokens)
Comprehensive frameworks for sustained work. Best when you're deeply engaged in a field and need extensive terminological and methodological support. Anthropic's prompt caching makes these cost-effective for extended conversations.

**Very large domains** (~1500+ tokens)
For serious scholarly work requiring detailed protocols, extensive source references, and mode-based workflows. See the user-created domains like the Islamic sciences example (6000+ tokens with detailed tafseer, tajweed, fiqh, and hadith methodologies).

## Creating Your Own Domains

### Quick Start

1. Copy a sample to `domains/your_domain.md`
2. Customize to fit your knowledge area or reading interests
3. Be specific—"be helpful" adds nothing; "parse Sanskrit grammar with attention to sandhi rules" adds value

### File Format

```markdown
# Domain Name
<!--
Tokens: ~300
Notes: Brief description of what this domain provides
-->

Your domain content here. This text is sent to the AI
as context for every message in the conversation.

Focus on:
- Specialized terminology and concepts
- Methodological frameworks
- Analytical tools and approaches
- Source traditions and references
- Technical precision in your field
```

**Required:**
- First line: `# Domain Name` (becomes display name)
- Content: The actual knowledge context/expertise

**Optional metadata** (in HTML comment, stripped before sending to AI):
- `Tokens`: Approximate token count (helps you track costs)
- `Notes`: Brief description (shown in domain details view)

### Domain Design Principles

**1. Provide Knowledge, Not Instructions**
- Good: "When analyzing Classical Arabic, consider root-pattern morphology (جذر/وزن), case endings (إعراب), and rhetorical devices (بلاغة)"
- Bad: "Please be thorough and helpful when explaining things"

**2. Be Specific and Technical**
- Vague instructions waste tokens
- Precise terminology and frameworks guide the AI effectively
- Include domain-specific vocabulary that wouldn't be emphasized otherwise

**3. Set Expertise Context**
- What kind of texts will you share?
- What analytical frameworks should be applied?
- What traditions or methodologies are relevant?
- What technical precision is expected?

**4. Domain Content Persists**
- Everything in the domain is sent with every message
- Keep it focused on consistently relevant knowledge
- Don't include one-off instructions—those belong in prompts

**5. Think "Specialized Knowledge Area"**
Good domain topics:
- Language support (Classical Arabic, Sanskrit, Classical Chinese, etc.)
- Academic fields (linguistics, psychology, religious studies, physics, etc.)
- Interdisciplinary frameworks (comparative religion, history of ideas, etc.)
- Professional domains (legal analysis, medical terminology, etc.)
- Research methodologies (historical-critical, phenomenological, etc.)

**6. Consider Combining with Behaviors**
Domains and behaviors work together:
- A `scholarly_standard` behavior + a Philosophy domain = Rigorous academic analysis of philosophical texts
- A `concise` behavior + Classical Arabic domain = Efficient language parsing without verbose explanations
- A `grok_style_mini` behavior + Synthesis domain = Direct interdisciplinary connections

The system prompt sent to the AI is: **Behavior + Domain + Language instruction**. Experiment with combinations.

## Example Domain Ideas

### Language & Linguistics
- Classical languages (Greek, Latin, Hebrew, Sanskrit)
- Modern language support with grammatical frameworks
- Linguistic analysis (phonology, morphology, syntax, semantics)

### Academic Fields
- Philosophy (Western, Eastern, Islamic, comparative)
- Psychology (depth psychology, cognitive science, clinical)
- Religious studies (specific traditions or comparative)
- History (period-specific or methodological)
- Sciences (physics, biology, mathematics with appropriate depth)

### Professional Domains
- Legal analysis and terminology
- Medical/clinical terminology and frameworks
- Technical writing in specific fields
- Business or economic analysis

### Interdisciplinary Frameworks
- Comparative religion and mysticism
- History of ideas (science, philosophy, theology)
- Cultural studies and critical theory
- Environmental humanities
- Digital humanities methodologies

### Specialized Interests
- Manuscript studies and textual criticism
- Art history and aesthetic theory
- Music theory and analysis
- Film studies and narrative analysis

## Tips for Effective Domains

**Start Small, Expand as Needed**
Begin with focused domains. Expand when you find yourself repeatedly needing certain frameworks or terminology.

**Test and Iterate**
Use your domain in actual conversations. Adjust based on what's helpful vs. what's ignored.

**Combine Strategically**
You might have:
- A general synthesis domain for broad interdisciplinary work
- Specialized language domains for text study
- Field-specific domains for research projects

Switch domains based on what you're reading.

**Don't Duplicate Behaviors**
If it's about communication style, tone, or reading stance—that's a behavior. Keep domains focused on knowledge context.

**Think "Expert Consultant"**
Your domain should be like having a subject matter expert joining the conversation who brings specialized knowledge, not someone who tells you how to talk.

## Note

The `domains/` folder is gitignored to keep your customizations private and separate from plugin updates. Sample domains here serve as starting points—copy and customize them to build your personal knowledge contexts.

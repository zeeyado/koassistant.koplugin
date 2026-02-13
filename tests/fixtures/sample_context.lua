--[[--
Sample book context for testing X-Ray, Recap, and Analyze My Notes actions.

This fixture provides realistic test data for the web inspector when
ui.document is unavailable (running outside KOReader).

All content is original and fictional.
]]

return {
    -- Book metadata
    title = "The Cartographer's Daughter",
    author = "Elena Vasquez",

    -- Reading progress (42% through)
    reading_progress = "42%",
    progress_decimal = "0.42",

    -- Reading stats
    chapter_title = "Chapter 14: The Unmarked Territory",
    chapters_read = "14",
    time_since_last_read = "3 days ago",

    -- Highlights (text only, formatted as extractor outputs)
    highlights = [[- "Maps are not truth, child. They are stories we tell about the world." (Chapter 1)
- "The border between Kestria and the Wildlands had been redrawn seventeen times in her grandmother's lifetime." (Chapter 3)
- "Commander Thorne's eyes held the particular weariness of a man who had seen too many young soldiers become old ones overnight." (Chapter 7)
- "She traced the river's path with her finger, noting how it curved away from the mountains like a creature avoiding a predator." (Chapter 9)
- "In the margins of her father's final map, written in his cramped hand: 'The true boundary lies not in the land but in what we choose to see.'" (Chapter 11)
- "The archives smelled of dust and secrets, both equally ancient." (Chapter 12)
- "Three keys, three doors, three truths that could not coexist." (Chapter 14)]],

    -- Annotations (highlights with user notes)
    annotations = [[- "Maps are not truth, child. They are stories we tell about the world."
  [Note: Central theme - subjective nature of cartography/history]
  (Chapter 1)

- "Commander Thorne's eyes held the particular weariness of a man who had seen too many young soldiers become old ones overnight."
  [Note: First real hint that Thorne knows more than he lets on. Revisit after the revelation in Ch 11]
  (Chapter 7)

- "In the margins of her father's final map, written in his cramped hand: 'The true boundary lies not in the land but in what we choose to see.'"
  [Note: This changes everything. Father knew about the deception. Did he create it or discover it?]
  (Chapter 11)

- "The archives smelled of dust and secrets, both equally ancient."
  [Note: Beautiful line. The whole archive scene is atmospheric perfection]
  (Chapter 12)

- "Three keys, three doors, three truths that could not coexist."
  [Note: Prophecy? Or literal? The Keeper mentioned "doors" in Ch 8...]
  (Chapter 14)]],

    -- Sample book text (realistic excerpt, ~3000 chars)
    book_text = [[Chapter 13: The Weight of Ink

Sera spread her father's maps across the archive table, anchoring the corners with whatever she could find—a brass compass, two leather-bound volumes, a stone paperweight carved into the shape of a sleeping fox.

"You're certain these are his original surveys?" Commander Thorne stood at the window, his back to her, watching the courtyard below.

"I'd know his linework anywhere." She traced the delicate crosshatching that marked the Thornwood Forest. "See how he indicates elevation? Three parallel lines for gentle slopes, converging to points for steep terrain. No one else mapped it quite this way."

Thorne turned. In the afternoon light, the scar along his jaw looked like another cartographic symbol—a boundary marker, perhaps, between the man he had been and whatever he was now.

"The Council won't care about linework, Sera. They want to know why the eastern boundary in his final survey differs from every official map since."

She had noticed it too. A discrepancy of perhaps eight kilometers, running the length of the Kestrian border. On her father's map, the territory was clearly marked as disputed. On every subsequent map, it appeared solidly within Kestrian control.

"Someone altered the records."

"Or your father was wrong."

"My father was never wrong about measurements." The words came out sharper than she intended. "He may have been absent, distracted, married to his work more than to us—but his surveys were immaculate. If his map shows a different boundary, then the boundary was different."

Thorne was quiet for a long moment. When he spoke, his voice had lost its official edge.

"I knew your father, you know. Before. When I was just a lieutenant and he was already the Crown's Master Cartographer. He told me once that the most dangerous thing about a map is that people believe it."

"What do you mean?"

"A map is not the territory. It's a representation—shaped by whoever holds the pen, serving whatever purpose they need it to serve. Your father understood this better than anyone. And I think..." He paused, seeming to weigh his next words carefully. "I think he discovered that someone was using maps not to record truth, but to create it."

Chapter 14: The Unmarked Territory

The Keeper of the Archives was older than Sera had expected—a woman whose face was a map of its own, lined and weathered by decades of dust and lamplight.

"The restricted collection is exactly that, young surveyor. Restricted."

"I'm the daughter of Marcus Valdren."

Something shifted in the Keeper's expression. Recognition, certainly. But also something else—fear? Respect? Both?

"Follow me."

The deeper archives were a labyrinth. Shelves towered toward distant ceilings, laden with scrolls and bound volumes and strange devices whose purposes Sera could only guess at. The air grew colder as they descended.

"Your father came here often, in his final months." The Keeper's voice echoed strangely in the narrow passages. "He was researching something. I never asked what. In my experience, it's better not to know the questions others are asking."

They stopped before a door of black iron, unmarked and ancient.

"Three keys open this door. I possess one. The Crown holds another. And the third..." She smiled, thin and knowing. "The third was buried with your father. Or so the official records claim."

Sera felt the cold metal in her pocket—the key she had found hidden in her father's study, tucked inside a false compartment in his favorite compass case.]],

    -- Notebook entries (user's personal notes about the book)
    notebook_content = [[Entry 1: Chapter 5 - The theme of subjective truth
The idea that maps represent stories rather than facts reminds me of "The Map Is Not the Territory" concept from Korzybski. Elena Vasquez is playing with this idea throughout.

Entry 2: Chapter 11 - Father's margin notes
The revelation that Marcus knew about the deception changes everything. Was he complicit or trying to expose it? Need to watch for more hints.

Entry 3: Chapter 13 - The Thorne interview
Commander Thorne's quote about maps creating truth rather than recording it feels like the book's central thesis. This connects to current debates about how we construct narratives about history.]],
}

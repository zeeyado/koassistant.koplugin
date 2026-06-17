--[[--
Quiz instruction builder (pure, no dependencies).

Turns a resolved quiz config (the table from BookSettings.resolveQuiz — count,
difficulty, mc/sa/essay, ...) into the dynamic instruction block appended to the
prompt for interactive-quiz actions. Extracted from koassistant_dialogs.lua so the
per-book-override → emitted-instructions path is unit-testable.
]]

local QuizPrompt = {}

--- Build the quiz instruction string from a resolved quiz config.
-- @param quiz table  { count, difficulty, mc, sa, essay } (from BookSettings.resolveQuiz)
-- @return string
function QuizPrompt.build(quiz)
    quiz = quiz or {}
    local parts = {}
    local count = quiz.count or 8
    table.insert(parts, "Generate exactly " .. count .. " questions total.")

    -- Difficulty
    local difficulty = quiz.difficulty or "medium"
    if difficulty == "easy" then
        table.insert(parts, "Difficulty: Easy — focus on straightforward recall and recognition.")
    elseif difficulty == "hard" then
        table.insert(parts, "Difficulty: Hard — focus on nuanced analysis, synthesis, and evaluation.")
    else
        table.insert(parts, "Difficulty: Medium — balance recall with comprehension and application.")
    end

    -- Question types
    local mc = quiz.mc
    local sa = quiz.sa
    local essay = quiz.essay
    if not mc and not sa and not essay then mc = true end -- fallback

    -- Build JSON example with only enabled types
    local json_examples = {}
    local rules = {}
    local type_list = {}

    if mc then
        table.insert(type_list, "multiple_choice")
        table.insert(json_examples, [[    {
      "type": "multiple_choice",
      "question": "What is the main theme explored in this section?",
      "options": {"A": "Option text", "B": "Option text", "C": "Option text", "D": "Option text"},
      "correct": "B",
      "explanation": "Brief explanation of why B is correct."
    }]])
        table.insert(rules, '- Multiple choice: always 4 options (A-D), "correct" is the letter, include "explanation"')
    end
    if sa then
        table.insert(type_list, "short_answer")
        table.insert(json_examples, [[    {
      "type": "short_answer",
      "question": "Explain the significance of...",
      "model_answer": "A good answer would mention...",
      "key_points": ["Key point 1", "Key point 2"]
    }]])
        table.insert(rules, '- Short answer: include "model_answer" (2-3 sentences) and "key_points" array')
    end
    if essay then
        table.insert(type_list, "essay")
        table.insert(json_examples, [[    {
      "type": "essay",
      "question": "Discuss how the author...",
      "key_points": ["Point about X", "Point about Y", "Connection to Z"]
    }]])
        table.insert(rules, '- Discussion/essay: include "key_points" array (3-5 points a good answer should cover)')
    end

    -- Distribution instruction
    if #type_list == 1 then
        table.insert(parts, "All " .. count .. ' questions must be type "' .. type_list[1] .. '".')
    else
        table.insert(parts, "Distribute questions across these types: " .. table.concat(type_list, ", ") .. ".")
        table.insert(parts, "Do NOT include any other question types.")
    end

    -- JSON schema
    table.insert(parts, "")
    table.insert(parts, "CRITICAL: Respond with ONLY a JSON object. Use this exact structure:")
    table.insert(parts, "")
    table.insert(parts, '```json')
    table.insert(parts, '{')
    table.insert(parts, '  "questions": [')
    table.insert(parts, table.concat(json_examples, ",\n"))
    table.insert(parts, '  ]')
    table.insert(parts, '}')
    table.insert(parts, '```')
    table.insert(parts, "")
    table.insert(parts, "Rules:")
    table.insert(parts, '- "type" must be exactly one of: ' .. table.concat(type_list, ", "))
    for _idx, rule in ipairs(rules) do
        table.insert(parts, rule)
    end
    table.insert(parts, "- Adapt to content type (fiction: plot/characters/themes, non-fiction: arguments/evidence/concepts, academic: methodology/findings)")
    table.insert(parts, "- Use key terms in the work's original language where applicable")
    table.insert(parts, "- CRITICAL for valid JSON: inside any question, option, or explanation, use single quotes for quotations (e.g. 'like this'). Never put a raw double quote inside a string value — if you must, escape it as \\\". Unescaped double quotes break the JSON.")

    return table.concat(parts, "\n")
end

return QuizPrompt

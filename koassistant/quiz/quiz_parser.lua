--- Quiz response parser
--- Extracts structured quiz data from AI responses.
--- Supports JSON (fenced or raw) with markdown fallback.

local json = require("json")
local logger = require("koassistant.core.logger")

local QuizParser = {}

--- Valid question types
local VALID_TYPES = {
    multiple_choice = true,
    short_answer = true,
    essay = true,
}

--- Option letters, in display order. The viewer renders exactly these.
local LETTERS = { "A", "B", "C", "D" }
local IS_LETTER = {}
for _idx, letter in ipairs(LETTERS) do IS_LETTER[letter] = true end

--- Validate a single parsed question
--- @param q table
--- @return boolean
local function isValidQuestion(q)
    if type(q) ~= "table" then return false end
    if not VALID_TYPES[q.type] then return false end
    if type(q.question) ~= "string" or q.question == "" then return false end

    if q.type == "multiple_choice" then
        if type(q.options) ~= "table" then return false end
        -- Need at least 2 options
        local count = 0
        for _ in pairs(q.options) do count = count + 1 end
        if count < 2 then return false end
        if type(q.correct) ~= "string" or q.correct == "" then return false end
    end

    return true
end

--- Validate parsed quiz data structure
--- @param data table
--- @return boolean
local function isValidQuizData(data)
    if type(data) ~= "table" then return false end
    if type(data.questions) ~= "table" then return false end
    if #data.questions == 0 then return false end

    for _idx, q in ipairs(data.questions) do
        if not isValidQuestion(q) then return false end
    end

    return true
end

--- Normalize a multiple-choice "correct" field down to a bare option letter.
--- Models return "b", "B)", "(B)", "B) Rome", "Option B", "Answer: B" — the
--- viewer compares it letter-for-letter, so anything but "B" scores every answer
--- wrong. Only rewrites when the extracted letter is a real option key; values
--- that resolve to nothing (e.g. localized letters) are left untouched.
--- @param q table A multiple_choice question
local function normalizeCorrect(q)
    if type(q.options) ~= "table" or type(q.correct) ~= "string" then return end
    local s = q.correct:match("^%s*(.-)%s*$"):upper()
    local letter = s:match("^%(?([A-Z])%)?[%.%):%s]*$")   -- "B", "b", "(B)", "B."
        or s:match("^%(?([A-Z])[%.%):]")                   -- "B) Rome"
        or s:match("[^%a]([A-Z])[%.%):%s]*$")              -- "Option B", "Answer: B"
    if letter and q.options[letter] ~= nil then
        q.correct = letter
    end
end

--- Repair pass applied to every successfully parsed quiz.
--- @param data table
--- @return table The same table
-- A field the model sends as JSON null decodes to a function sentinel in
-- KOReader's json: the viewer took the length of key_points and the export
-- printed a model answer, so a null crashed the quiz window on reveal
-- (sweep 2026-11-06). Keep strings only, and only string key points and
-- options.
local function normalizeQuestionFields(q)
    if type(q.explanation) ~= "string" then q.explanation = nil end
    if type(q.model_answer) ~= "string" then q.model_answer = nil end
    if q.key_points ~= nil then
        local kept = {}
        if type(q.key_points) == "table" then
            for _j, kp in ipairs(q.key_points) do
                if type(kp) == "string" then table.insert(kept, kp) end
            end
        end
        q.key_points = kept
    end
    if type(q.options) == "table" then
        if #q.options > 0 then
            local kept = {}
            for _j, opt in ipairs(q.options) do
                if type(opt) == "string" then table.insert(kept, opt) end
            end
            q.options = kept
        else
            for k, v in pairs(q.options) do
                if type(v) ~= "string" then q.options[k] = nil end
            end
        end
    end
end

QuizParser._normalizeQuestionFields = normalizeQuestionFields  -- test seam

local function normalizeQuiz(data)
    for _idx, q in ipairs(data.questions or {}) do
        normalizeQuestionFields(q)
        if q.type == "multiple_choice" then normalizeCorrect(q) end
    end
    return data
end

--- Try to decode JSON from text, return parsed data if valid quiz
--- @param text string
--- @return table|nil
local function tryDecode(text)
    local ok, data = pcall(json.decode, text)
    if ok and isValidQuizData(data) then
        return normalizeQuiz(data)
    end
    return nil
end

--- Extract JSON from code fences (```json ... ``` or ``` ... ```)
--- @param text string
--- @return string|nil extracted JSON string
local function extractFromFences(text)
    local fence_open = text:find("```json%s*\n") or text:find("```%s*\n")
    if not fence_open then return nil end

    local content_start = text:find("\n", fence_open) + 1

    -- Find the LAST ``` after the opening fence
    local fence_close
    local search_pos = content_start
    while true do
        local pos = text:find("\n%s*```", search_pos)
        if pos then
            fence_close = pos
            search_pos = pos + 4
        else
            break
        end
    end

    if fence_close then
        return text:sub(content_start, fence_close - 1), content_start
    end
    return nil, content_start
end

--- Extract from first { to last } (brace matching)
--- @param text string
--- @param start_pos number|nil Position to start searching from
--- @return string|nil
local function extractFromBraces(text, start_pos)
    local first_brace = text:find("{", start_pos or 1)
    if not first_brace then return nil end

    -- Scan backwards for last }
    local last_brace
    for i = #text, 1, -1 do
        if text:byte(i) == 125 then -- }
            last_brace = i
            break
        end
    end

    if last_brace and last_brace > first_brace then
        return text:sub(first_brace, last_brace)
    end
    return nil
end

local JsonRepair = require("koassistant.core.json_repair")

--- Parse a markdown-formatted quiz response as fallback.
--- Looks for numbered questions, A)/B)/C)/D) options, and answer key sections.
--- @param text string
--- @return table|nil Parsed quiz data, or nil if parsing fails
local function parseMarkdown(text)
    local questions = {}

    -- Split into questions section and answer key section
    local answer_key_start = text:find("\n##%s*Answer Key") or text:find("\n##%s*Answers")
    local questions_text = answer_key_start and text:sub(1, answer_key_start - 1) or text
    local answers_text = answer_key_start and text:sub(answer_key_start) or ""

    -- Detect section headers for question types
    local mc_start = questions_text:find("###%s*Multiple Choice")
    local sa_start = questions_text:find("###%s*Short Answer")
    local essay_start = questions_text:find("###%s*Discussion") or questions_text:find("###%s*Essay")

    -- Extract numbered questions with pattern: digit(s) followed by . or )
    -- Track which section each question falls in
    local question_positions = {}
    for pos, num, q_text in questions_text:gmatch("()\n%s*(%d+)[%.%)]+%s*([^\n]+)") do
        table.insert(question_positions, {
            pos = pos,
            num = tonumber(num),
            text = q_text,
        })
    end
    -- Also check start of text (no leading newline)
    local first_num, first_text = questions_text:match("^%s*(%d+)[%.%)]+%s*([^\n]+)")
    if first_num then
        table.insert(question_positions, 1, {
            pos = 1,
            num = tonumber(first_num),
            text = first_text,
        })
    end

    if #question_positions == 0 then return nil end

    -- Parse answer key into a lookup: question_number -> answer text
    local answer_lookup = {}
    for num, answer in answers_text:gmatch("(%d+)[%.%)]+%s*([^\n]+)") do
        answer_lookup[tonumber(num)] = answer
    end

    -- Classify each question and extract options/answers
    for _idx, qp in ipairs(question_positions) do
        local q_type = "short_answer" -- default

        -- Determine type by section position
        if mc_start and (not sa_start or qp.pos < sa_start) and (not essay_start or qp.pos < essay_start) and qp.pos > (mc_start or 0) then
            q_type = "multiple_choice"
        elseif essay_start and qp.pos > essay_start then
            q_type = "essay"
        elseif sa_start and qp.pos > sa_start then
            q_type = "short_answer"
        end

        -- For MC: look for A)/B)/C)/D) options after the question
        if q_type == "multiple_choice" then
            -- Get text between this question and the next
            local next_q = question_positions[_idx + 1]
            local section_end = next_q and next_q.pos or #questions_text
            local section = questions_text:sub(qp.pos, section_end)

            local options = {}
            for letter, opt_text in section:gmatch("[%-*]?%s*([A-D])[%.%):]%s*([^\n]+)") do
                options[letter] = opt_text
            end

            -- Extract correct answer from answer key
            local correct = nil
            local answer_text = answer_lookup[qp.num] or ""
            local letter_match = answer_text:match("^%s*([A-D])")
            if letter_match then correct = letter_match end

            if next(options) then
                table.insert(questions, {
                    type = "multiple_choice",
                    question = qp.text,
                    options = options,
                    correct = correct or "A", -- fallback
                    explanation = answer_text,
                })
            else
                -- No options found, demote to short answer
                table.insert(questions, {
                    type = "short_answer",
                    question = qp.text,
                    model_answer = answer_lookup[qp.num] or "",
                    key_points = {},
                })
            end
        elseif q_type == "essay" then
            table.insert(questions, {
                type = "essay",
                question = qp.text,
                key_points = answer_lookup[qp.num] and { answer_lookup[qp.num] } or {},
            })
        else
            table.insert(questions, {
                type = "short_answer",
                question = qp.text,
                model_answer = answer_lookup[qp.num] or "",
                key_points = {},
            })
        end
    end

    if #questions == 0 then return nil end
    return { questions = questions }
end

--- Parse AI response into structured quiz data.
--- Tries JSON extraction first, falls back to markdown parsing.
--- @param text string AI response text
--- @return table|nil Parsed quiz data with .questions array, or nil
--- @return string|nil Error message if all attempts failed
function QuizParser.parse(text)
    if type(text) ~= "string" or text == "" then
        return nil, "empty input"
    end

    -- Attempt 1: direct JSON decode
    local data = tryDecode(text)
    if data then
        logger.dbg("QuizParser: parsed via direct JSON decode")
        return data, nil
    end

    -- Attempt 2: extract from code fences
    local fenced, content_start = extractFromFences(text)
    if fenced then
        data = tryDecode(fenced)
        if data then
            logger.dbg("QuizParser: parsed via code fence extraction")
            return data, nil
        end
    end

    -- Attempt 3: extract from first { to last }
    local braced = extractFromBraces(text, content_start)
    if braced then
        data = tryDecode(braced)
        if data then
            logger.dbg("QuizParser: parsed via brace extraction")
            return data, nil
        end
    end

    -- Attempt 3.5: repair unescaped inner double quotes, then retry the best JSON candidate
    -- (fenced > braced > whole text). Common LLM error that otherwise breaks json.decode.
    local candidate = fenced or braced or text
    data = tryDecode(JsonRepair.escapeInnerQuotes(candidate))
    if data then
        logger.dbg("QuizParser: parsed via unescaped-quote repair")
        return data, nil
    end

    -- Attempt 3.6: drop stray closing braces/brackets — the other LLM defect
    -- class (2026-08-18, root-caused on the X-Ray path, same bundled decoder):
    -- one extra `}`/`]` crashes LuaJSON with the state.lua:81 'active' error
    -- instead of a syntax message. Same layering as the X-Ray parser's
    -- Attempt 5: only after strict parsing fails, quote repair on top.
    local rebalanced = JsonRepair.dropExtraClosers(candidate)
    if rebalanced == candidate then
        rebalanced = JsonRepair.closeUnclosed(candidate)
    end
    if rebalanced ~= candidate then
        data = tryDecode(rebalanced) or tryDecode(JsonRepair.escapeInnerQuotes(rebalanced))
        if data then
            logger.dbg("QuizParser: parsed via bracket-balance repair")
            return data, nil
        end
    end

    -- Attempt 4: markdown fallback
    data = parseMarkdown(text)
    if data then
        logger.dbg("QuizParser: parsed via markdown fallback, found", #data.questions, "questions")
        return normalizeQuiz(data), nil
    end

    return nil, "failed to parse quiz from response"
end

-- Answer placement (issue #99) ----------------------------------------------
--
-- Models put the correct option in the middle far above chance, and cannot be
-- prompted out of it: "distribute the letters evenly" asks for a running count
-- they do not keep, and the JSON example has to name some letter, which just
-- becomes the next anchor (moving the example from B to C produced quizzes
-- clustered on B and C). So the model no longer gets a vote — it marks whichever
-- option it likes and we move that option to a letter of our choosing before the
-- reader sees the question.
--
-- The draw must be REPEATABLE, not merely random. The artifact cache stores the
-- raw response text and re-parses it on every open, while quiz_state persists the
-- reader's answer as a LETTER — so a fresh roll on reopen would silently re-point
-- saved answers at different option text. Seeding from the quiz's own content
-- gives a layout that is unpredictable to the reader but identical on every
-- parse, device and restart.

--- djb2-style string hash, kept under 2^31 so LuaJIT doubles stay exact.
--- The multiplier is a parameter so the three PRNG streams get genuinely
--- independent seeds: sharing one multiplier and varying only the starting
--- constant leaves the three hashes a fixed multiple apart.
local function hashInto(h, s, mul)
    for i = 1, #s do
        h = (h * mul + s:byte(i)) % 2147483648
    end
    return h
end

--- Wichmann-Hill PRNG: three small Lehmer streams combined. Its own generator,
--- never math.random — a global stream that other code also draws from would
--- break repeatability.
--- A single Park-Miller stream was tried first and rejected: quizzes seeded from
--- near-identical content share its low-dimensional lattice, which showed up as a
--- measurable skew (29/21/29/21) at one fixed question position while every other
--- position sat at 25%. Combining three streams removes it, and every
--- intermediate here stays far inside double-exact range.
--- @param s1 number
--- @param s2 number
--- @param s3 number
--- @return function rng(n) -> integer in [1, n]
local function makeRng(s1, s2, s3)
    s1, s2, s3 = s1 % 30269 + 1, s2 % 30307 + 1, s3 % 30323 + 1
    return function(n)
        s1 = (s1 * 171) % 30269
        s2 = (s2 * 172) % 30307
        s3 = (s3 * 170) % 30323
        local r = s1 / 30269 + s2 / 30307 + s3 / 30323
        return math.floor((r - math.floor(r)) * n) + 1
    end
end

--- Option letters actually present on a question, in display order.
local function presentLetters(options)
    local present = {}
    for _idx, letter in ipairs(LETTERS) do
        if options[letter] ~= nil then table.insert(present, letter) end
    end
    return present
end

--- Reassign which letter holds the correct option, deterministically.
--- Multiple choice only — short answer and essay have no letters to move.
--- Mutates quiz_data in place; safe to call twice (the second call is a no-op,
--- since reseeding from already-moved text would yield a different layout).
--- @param quiz_data table Parsed quiz data
--- @return table The same table
function QuizParser.balanceAnswers(quiz_data)
    if type(quiz_data) ~= "table" or type(quiz_data.questions) ~= "table" then
        return quiz_data
    end
    if quiz_data._answers_balanced then return quiz_data end
    quiz_data._answers_balanced = true

    -- Seed from the whole quiz, walking a FIXED letter order: pairs() over the
    -- options table is not order-stable, which would hand the same quiz a
    -- different layout on a later run. Three independent starting constants give
    -- the three Wichmann-Hill streams well-separated seeds.
    local s1, s2, s3 = 5381, 52711, 1000003
    for _idx, q in ipairs(quiz_data.questions) do
        local text = tostring(q.question or "")
        if type(q.options) == "table" then
            for _li, letter in ipairs(LETTERS) do
                local opt = q.options[letter]
                if type(opt) == "string" then text = text .. letter .. opt end
            end
        end
        s1, s2, s3 = hashInto(s1, text, 33), hashInto(s2, text, 31), hashInto(s3, text, 37)
    end

    local rng = makeRng(s1, s2, s3)
    for _idx, q in ipairs(quiz_data.questions) do
        -- IS_LETTER guard: a "correct" that survived normalization unresolved
        -- (localized letter, option text) has no slot to move, so leave it be.
        if q.type == "multiple_choice" and type(q.options) == "table"
            and type(q.correct) == "string" and IS_LETTER[q.correct]
            and q.options[q.correct] ~= nil then
            local present = presentLetters(q.options)
            if #present >= 2 then
                local target = present[rng(#present)]
                -- Captured before mutating: the correct option moves to `target`
                -- and the rest close ranks in their original order.
                local correct_text = q.options[q.correct]
                local others = {}
                for _li, letter in ipairs(present) do
                    if letter ~= q.correct then table.insert(others, q.options[letter]) end
                end
                local oi = 1
                for _li, letter in ipairs(present) do
                    if letter == target then
                        q.options[letter] = correct_text
                    else
                        q.options[letter] = others[oi]
                        oi = oi + 1
                    end
                end
                q.correct = target
            end
        end
    end

    return quiz_data
end

--- Get counts of each question type
--- @param quiz_data table Parsed quiz data
--- @return table Counts: {multiple_choice=N, short_answer=N, essay=N}
function QuizParser.getTypeCounts(quiz_data)
    local counts = { multiple_choice = 0, short_answer = 0, essay = 0 }
    if not quiz_data or not quiz_data.questions then return counts end
    for _idx, q in ipairs(quiz_data.questions) do
        if counts[q.type] then
            counts[q.type] = counts[q.type] + 1
        end
    end
    return counts
end

return QuizParser

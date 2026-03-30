--- Quiz response parser
--- Extracts structured quiz data from AI responses.
--- Supports JSON (fenced or raw) with markdown fallback.

local json = require("json")
local logger = require("logger")

local QuizParser = {}

--- Valid question types
local VALID_TYPES = {
    multiple_choice = true,
    short_answer = true,
    essay = true,
}

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

--- Try to decode JSON from text, return parsed data if valid quiz
--- @param text string
--- @return table|nil
local function tryDecode(text)
    local ok, data = pcall(json.decode, text)
    if ok and isValidQuizData(data) then
        return data
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

    -- Attempt 4: markdown fallback
    data = parseMarkdown(text)
    if data then
        logger.dbg("QuizParser: parsed via markdown fallback, found", #data.questions, "questions")
        return data, nil
    end

    return nil, "failed to parse quiz from response"
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

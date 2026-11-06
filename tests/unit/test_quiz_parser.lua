-- Unit tests for koassistant/quiz/quiz_parser.lua (JSON extraction + unescaped-quote repair).

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")

local QP = require("koassistant.quiz.quiz_parser")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:eq(a, b, msg)
    if a ~= b then error(string.format("%s: expected %q, got %q", msg or "eq", tostring(b), tostring(a))) end
end
function TestRunner:ok(v, msg) if not v then error(msg or "expected truthy") end end
function TestRunner:nilv(v, msg) if v ~= nil then error((msg or "expected nil") .. ", got " .. tostring(v)) end end

TestRunner:suite("QuizParser.parse — well-formed")

TestRunner:test("raw JSON", function()
    local d = QP.parse('{"questions":[{"type":"short_answer","question":"Q?","model_answer":"a","key_points":["x"]}]}')
    TestRunner:ok(d); TestRunner:eq(#d.questions, 1)
end)
TestRunner:test("fenced ```json block", function()
    local d = QP.parse('```json\n{"questions":[{"type":"essay","question":"Discuss.","key_points":["a","b"]}]}\n```')
    TestRunner:ok(d); TestRunner:eq(d.questions[1].type, "essay")
end)
TestRunner:test("multiple_choice intact", function()
    local d = QP.parse('{"questions":[{"type":"multiple_choice","question":"Q?","options":{"A":"a","B":"b","C":"c","D":"d"},"correct":"C","explanation":"because"}]}')
    TestRunner:ok(d); TestRunner:eq(d.questions[1].correct, "C")
end)
TestRunner:test("properly escaped inner quotes parse normally", function()
    local d = QP.parse('{"questions":[{"type":"short_answer","question":"Define \\"x\\".","model_answer":"y","key_points":["z"]}]}')
    TestRunner:ok(d)
end)

TestRunner:suite("QuizParser.parse — unescaped inner double quotes (repair)")

TestRunner:test("the reported failure: an \"I,\" inside an explanation", function()
    local txt = '```json\n{"questions":[{"type":"multiple_choice","question":"What is significant about writing?",'
        .. '"options":{"A":"x","B":"the precondition for an "I"","C":"z","D":"w"},"correct":"B",'
        .. '"explanation":"Rotman claims the existence of an "I," a self-aware self, is possible only through writing."}]}\n```'
    local d, e = QP.parse(txt)
    TestRunner:ok(d, "should recover via repair: " .. tostring(e))
    TestRunner:eq(#d.questions, 1)
    TestRunner:eq(d.questions[1].correct, "B")
    TestRunner:ok(d.questions[1].explanation:find("self%-aware self"), "explanation content preserved")
end)
TestRunner:test("repair does not corrupt already-valid clean JSON", function()
    local clean = '{"questions":[{"type":"essay","question":"Discuss the theme.","key_points":["a","b","c"]}]}'
    local d = QP.parse(clean)
    TestRunner:ok(d); TestRunner:eq(#d.questions[1].key_points, 3)
end)

TestRunner:suite("QuizParser.parse — stray closing braces (repair)")

TestRunner:test("doubled final closer recovers", function()
    local d, e = QP.parse('```json\n{"questions":[{"type":"essay","question":"Q?","key_points":["a"]}]}}\n```')
    TestRunner:ok(d, "should recover via stray-closer repair: " .. tostring(e))
    TestRunner:eq(#d.questions, 1)
end)
TestRunner:test("stray closer mid-document recovers", function()
    local d = QP.parse('{"questions":[{"type":"essay","question":"Q?","key_points":["a"]}]],"extra":[1]}')
    TestRunner:ok(d)
end)
TestRunner:test("under-closed but complete document recovers; mid-string truncation fails", function()
    -- Ends on a completed value: the closeUnclosed mirror repair finishes it.
    local d = QP.parse('{"questions":[{"type":"essay","question":"Q?","key_points":["a"]}')
    TestRunner:ok(d, "complete-but-under-closed recovers")
    -- Genuine truncation (cut mid-string) still fails visibly.
    local t = QP.parse('{"questions":[{"type":"essay","question":"Q?","key_points":["cut mid')
    TestRunner:eq(t, nil, "mid-string truncation is not papered over")
end)

TestRunner:suite("QuizParser.parse — correct-letter normalization")

local function correctOf(raw)
    local d = QP.parse('{"questions":[{"type":"multiple_choice","question":"Q?",'
        .. '"options":{"A":"a","B":"b","C":"c","D":"d"},"correct":"' .. raw .. '"}]}')
    return d and d.questions[1].correct
end

TestRunner:test("lowercase letter", function()
    TestRunner:eq(correctOf("b"), "B")
end)
TestRunner:test("letter carrying its option text", function()
    local d = QP.parse('{"questions":[{"type":"multiple_choice","question":"Q?",'
        .. '"options":{"A":"a","B":"Rome","C":"c","D":"d"},"correct":"B) Rome"}]}')
    TestRunner:eq(d.questions[1].correct, "B")
end)
TestRunner:test("prose forms: Option C / (D) / Answer: A / B.", function()
    TestRunner:eq(correctOf("Option C"), "C")
    TestRunner:eq(correctOf("(D)"), "D")
    TestRunner:eq(correctOf("Answer: A"), "A")
    TestRunner:eq(correctOf("B."), "B")
end)
TestRunner:test("unresolvable value left untouched", function()
    TestRunner:eq(correctOf("none of these"), "none of these")
end)

TestRunner:suite("QuizParser.balanceAnswers — issue #99 answer placement")

local function mcQuiz(n, correct_letter)
    local qs = {}
    for i = 1, n do
        table.insert(qs, {
            type = "multiple_choice",
            question = "Question number " .. i .. "?",
            options = { A = "a" .. i, B = "b" .. i, C = "c" .. i, D = "d" .. i },
            correct = correct_letter,
        })
    end
    return { questions = qs }
end

TestRunner:test("the correct option's TEXT follows the reassigned letter", function()
    local q = mcQuiz(6, "B")
    local before = {}
    for i, question in ipairs(q.questions) do before[i] = question.options.B end
    QP.balanceAnswers(q)
    for i, question in ipairs(q.questions) do
        TestRunner:eq(question.options[question.correct], before[i], "q" .. i)
    end
end)

TestRunner:test("options are permuted, never lost or duplicated", function()
    local q = mcQuiz(6, "C")
    QP.balanceAnswers(q)
    for i, question in ipairs(q.questions) do
        local seen = {}
        for _li, letter in ipairs({ "A", "B", "C", "D" }) do
            local t = question.options[letter]
            TestRunner:ok(t, "letter " .. letter .. " present on q" .. i)
            TestRunner:ok(not seen[t], "no duplicate option text on q" .. i)
            seen[t] = true
        end
        for _li, prefix in ipairs({ "a", "b", "c", "d" }) do
            TestRunner:ok(seen[prefix .. i], prefix .. i .. " survived on q" .. i)
        end
    end
end)

TestRunner:test("a model that always answers B gets spread across letters", function()
    local q = mcQuiz(12, "B")
    QP.balanceAnswers(q)
    local distinct, n = {}, 0
    for _i, question in ipairs(q.questions) do
        if not distinct[question.correct] then distinct[question.correct] = true; n = n + 1 end
    end
    TestRunner:ok(n >= 3, "expected at least 3 distinct correct letters, got " .. n)
end)

TestRunner:test("re-parsing the same response yields an identical layout", function()
    local parts = {}
    for i = 1, 8 do
        table.insert(parts, string.format(
            '{"type":"multiple_choice","question":"Q%d?",'
            .. '"options":{"A":"a%d","B":"b%d","C":"c%d","D":"d%d"},"correct":"B"}',
            i, i, i, i, i))
    end
    local raw = '{"questions":[' .. table.concat(parts, ",") .. ']}'
    local first = QP.balanceAnswers(QP.parse(raw))
    local second = QP.balanceAnswers(QP.parse(raw))
    for i, question in ipairs(first.questions) do
        TestRunner:eq(second.questions[i].correct, question.correct, "correct letter q" .. i)
        for _li, letter in ipairs({ "A", "B", "C", "D" }) do
            TestRunner:eq(second.questions[i].options[letter], question.options[letter],
                "option " .. letter .. " q" .. i)
        end
    end
end)

TestRunner:test("calling twice is a no-op", function()
    local q = mcQuiz(6, "A")
    QP.balanceAnswers(q)
    local snapshot = {}
    for i, question in ipairs(q.questions) do snapshot[i] = question.correct end
    QP.balanceAnswers(q)
    for i, question in ipairs(q.questions) do
        TestRunner:eq(question.correct, snapshot[i], "q" .. i)
    end
end)

TestRunner:test("short answer and essay are untouched", function()
    local q = { questions = {
        { type = "short_answer", question = "Explain.", model_answer = "m", key_points = { "k" } },
        { type = "essay", question = "Discuss.", key_points = { "a", "b" } },
    } }
    QP.balanceAnswers(q)
    TestRunner:eq(q.questions[1].model_answer, "m")
    TestRunner:nilv(q.questions[1].correct)
    TestRunner:eq(#q.questions[2].key_points, 2)
end)

TestRunner:test("partial option sets stay within the letters present", function()
    local q = { questions = { {
        type = "multiple_choice", question = "Only two options?",
        options = { A = "first", C = "second" }, correct = "A",
    } } }
    QP.balanceAnswers(q)
    local c = q.questions[1].correct
    TestRunner:ok(c == "A" or c == "C", "correct stayed within present letters, got " .. tostring(c))
    TestRunner:nilv(q.questions[1].options.B)
    TestRunner:nilv(q.questions[1].options.D)
    TestRunner:eq(q.questions[1].options[c], "first")
end)

TestRunner:test("an unresolvable correct letter is skipped, not corrupted", function()
    local q = { questions = { {
        type = "multiple_choice", question = "Localized letters?",
        options = { ["\216\163"] = "one", ["\216\168"] = "two" }, correct = "\216\163",
    } } }
    QP.balanceAnswers(q)
    TestRunner:eq(q.questions[1].correct, "\216\163")
    TestRunner:eq(q.questions[1].options["\216\163"], "one")
end)

TestRunner:suite("QuizParser.parse — failure")
TestRunner:test("empty input → nil", function()
    local d, e = QP.parse("")
    TestRunner:nilv(d); TestRunner:ok(e)
end)
TestRunner:test("non-quiz prose → nil", function()
    TestRunner:nilv(QP.parse("Here is some text with no questions at all."))
end)

print("")
print(string.rep("-", 50))
TestRunner:suite("null fields (a function sentinel in KOReader's json) never reach the viewer")
TestRunner:test("explanation, model answer, key points and options keep strings only", function()
    local NULL = function() end
    local q = { type = "short_answer", question = "Q?", model_answer = NULL, explanation = NULL,
        key_points = { "a", NULL, "b" }, options = { A = "a", B = NULL, C = "c" } }
    QP._normalizeQuestionFields(q)
    assert(q.model_answer == nil and q.explanation == nil, "nulls dropped")
    assert(#q.key_points == 2 and q.key_points[2] == "b", "key points kept strings only")
    assert(q.options.B == nil and q.options.C == "c", "options kept strings only")
    local q2 = { type = "essay", question = "Q?", key_points = NULL, options = { "x", NULL, "y" } }
    QP._normalizeQuestionFields(q2)
    assert(#q2.key_points == 0, "a null list becomes empty")
    assert(#q2.options == 2 and q2.options[2] == "y", "a null option in a list is dropped")
end)

print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))
return TestRunner.failed == 0

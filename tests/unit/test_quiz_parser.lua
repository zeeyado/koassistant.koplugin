-- Unit tests for koassistant_quiz_parser.lua (JSON extraction + unescaped-quote repair).

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

local QP = require("koassistant_quiz_parser")

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
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))
return TestRunner.failed == 0

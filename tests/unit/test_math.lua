--[[
Unit Tests for koassistant_math.lua (#105 LaTeX math → readable HTML)

Covers:
- symbol/greek/operator mapping, sup/sub, accents, fractions, roots
- big operators with limits, functions, text/bold/blackboard styles
- environments (cases, matrices, align), \left/\right, unknown commands
- delimiter handling: $$, \[ \], \( \), $ (prose guard: prices stay prose)
- code fences and inline code untouched; no-math text returned unchanged
- output never carries raw "_" / "*" / "<" / ">" from the source (luamd safety)

Run: lua tests/run_tests.lua --unit   or   lua tests/unit/test_math.lua
]]

package.path = package.path .. ";./?.lua;./?/init.lua"

local M = require("koassistant_math")

local T = { passed = 0, failed = 0 }

function T:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print("  ✓ " .. name)
    else
        self.failed = self.failed + 1
        print("  ✗ " .. name .. ": " .. tostring(err))
    end
end

local function eq(got, want, label)
    if got ~= want then
        error(string.format("%s\n    want: %s\n    got:  %s", label or "mismatch", want, got), 2)
    end
end

local function has(got, needle, label)
    if not got:find(needle, 1, true) then
        error(string.format("%s: missing %q in %q", label or "expected", needle, got), 2)
    end
end

local function lacks(got, needle, label)
    if got:find(needle, 1, true) then
        error(string.format("%s: unexpected %q in %q", label or "unexpected", needle, got), 2)
    end
end

local R = M.render
local RM = function(src) return M.renderMath(src, false) end

-- ---- inline basics ----------------------------------------------------------

T:test("the issue's formula: vectors, cross product", function()
    eq(R([==[$\vec{F} = q (\vec{v} \times \vec{B})$]==]),
       "<i>F⃗</i> = <i>q</i> (<i>v⃗</i> × <i>B⃗</i>)")
end)

T:test("functions and greek: F = q v B sin θ", function()
    eq(R([==[$F = q v B \sin\theta$]==]), "<i>F</i> = <i>q</i> <i>v</i> <i>B</i> sin θ")
end)

T:test("bare variable spans in prose", function()
    eq(R([==[$q$ is the charge and $\theta$ is the angle]==]),
       "<i>q</i> is the charge and θ is the angle")
end)

T:test("superscripts and subscripts, source order kept", function()
    eq(RM("E = mc^2"), "<i>E</i> = <i>mc</i><sup>2</sup>")
    eq(RM("x_i^2"), "<i>x</i><sub><i>i</i></sub><sup>2</sup>")
    eq(RM("a_{ij}"), "<i>a</i><sub><i>ij</i></sub>")
    eq(RM("x^{-1}"), "<i>x</i><sup>−1</sup>")
end)

T:test("fractions: parens only around multi-token sides", function()
    eq(RM([[\frac{a+b}{2c}]]), "(<i>a</i>+<i>b</i>)/(2<i>c</i>)")
    eq(RM([[\frac{1}{2}]]), "1/2")
    eq(RM([[\frac{dy}{dx}]]), "<i>dy</i>/<i>dx</i>")
    eq(RM([[\frac{mv^2}{r}]]), "<i>mv</i><sup>2</sup>/<i>r</i>")
    eq(RM([[\frac{\rho}{\varepsilon_0}]]), "ρ/ε<sub>0</sub>")
    eq(RM([[\frac{(a+b)^2}{2}]]), "(<i>a</i>+<i>b</i>)<sup>2</sup>/2")
end)

T:test("roots", function()
    eq(RM([[\sqrt{x^2+1}]]), "√(<i>x</i><sup>2</sup>+1)")
    eq(RM([[\sqrt{2}]]), "√2")
    eq(RM([[\sqrt[3]{x}]]), "<sup>3</sup>√<i>x</i>")
end)

T:test("accents: combining marks on single glyphs, bold on longer bases", function()
    eq(RM([[\hat{x}]]), "<i>x\204\130</i>")
    eq(RM([[\bar{y}]]), "<i>y\204\132</i>") -- y + U+0304, not precomposed
    eq(RM([[\dot{z}]]), "<i>z\204\135</i>")
    eq(RM([[\vec{AB}]]), "<b><i>AB</i></b>")
end)

T:test("styles: mathbf, mathbb, text, operatorname", function()
    eq(RM([[\mathbf{v} \cdot \mathbf{w}]]), "<b>v</b> · <b>w</b>") -- bold upright, the physics convention
    eq(RM([[\mathbb{R}^n]]), "ℝ<sup><i>n</i></sup>")
    eq(RM([[x \text{ if } x > 0]]), "<i>x</i> if <i>x</i> &gt; 0")
    eq(RM([[\operatorname{arg\,max}_x f(x)]]), "arg max<sub><i>x</i></sub> <i>f</i>(<i>x</i>)")
end)

T:test("functions: gap only before letters/commands", function()
    eq(RM([[\sin^2\theta + \cos^2\theta = 1]]), "sin<sup>2</sup>θ + cos<sup>2</sup>θ = 1")
    eq(RM([[\log_2 n]]), "log<sub>2</sub> <i>n</i>")
    eq(RM([[\sin(x)]]), "sin(<i>x</i>)")
    eq(RM([[\sin x]]), "sin <i>x</i>")
end)

T:test("big operators with limits; lim", function()
    eq(RM([[\sum_{i=1}^{n} i^2]]), "∑<sub><i>i</i>=1</sub><sup><i>n</i></sup> <i>i</i><sup>2</sup>")
    eq(RM([[\int_0^\infty e^{-x}\,dx]]), "∫<sub>0</sub><sup>∞</sup> <i>e</i><sup>−<i>x</i></sup> <i>dx</i>")
    eq(RM([[\lim_{x \to 0} \frac{\sin x}{x}]]), "lim<sub><i>x</i> → 0</sub> (sin <i>x</i>)/<i>x</i>")
end)

T:test("left/right dropped, delimiters kept, \\right. vanishes", function()
    eq(RM([[\left( \frac{a}{b} \right)]]), "( <i>a</i>/<i>b</i> )")
    eq(RM([[\left. x \right|_0^1]]), "<i>x</i> |<sub>0</sub><sup>1</sup>")
end)

T:test("environments: cases, pmatrix, bmatrix, aligned", function()
    eq(RM([[\begin{cases} x & \text{if } x \geq 0 \\ -x & \text{otherwise} \end{cases}]]),
       "{ <i>x</i> if <i>x</i> ≥ 0; −<i>x</i> otherwise }")
    eq(RM([[\begin{pmatrix} a & b \\ c & d \end{pmatrix}]]), "(<i>a</i>, <i>b</i>; <i>c</i>, <i>d</i>)")
    eq(RM([[\begin{bmatrix} 1 & 0 \\ 0 & 1 \end{bmatrix}]]), "&#91;1, 0; 0, 1&#93;")
    eq(RM([[\begin{aligned} a &= b \\ c &= d \end{aligned}]]), "<i>a</i> = <i>b</i>; <i>c</i> = <i>d</i>")
end)

T:test("unknown commands stay literal; escapes; html-unsafe chars", function()
    eq(RM([[\unknown{x}]]), "\\unknown<i>x</i>")
    eq(RM([[a \& b]]), "<i>a</i> &amp; <i>b</i>")
    eq(RM([[x \% y]]), "<i>x</i> % <i>y</i>")
    eq(RM([[\alpha < \beta]]), "α &lt; β")
    eq(RM([[a \_ b]]), "<i>a</i> &#95; <i>b</i>")
    eq(RM([[x * y]]), "<i>x</i> ∗ <i>y</i>")
end)

T:test("output never leaks luamd-sensitive characters", function()
    local out = RM([[x_1 * y_2 \_ z < w > v]])
    lacks(out, "_"); lacks(out, "*"); lacks(out, " < "); lacks(out, " > ")
end)

-- ---- delimiters and document pass -----------------------------------------

T:test("display math: own centered paragraph, lines split on \\\\", function()
    local out = R([==[Before $$E = mc^2$$ after]==])
    eq(out, 'Before \n\n<p class="koa-math"><i>E</i> = <i>mc</i><sup>2</sup></p>\n\n after')
    out = R([==[$$a = b \\ c = d$$]==])
    has(out, '<p class="koa-math"><i>a</i> = <i>b</i></p>\n<p class="koa-math"><i>c</i> = <i>d</i></p>')
end)

T:test("\\[ \\] display and \\( \\) inline delimiters", function()
    has(R([==[\[ \int_0^1 x\,dx \]]==]), '<p class="koa-math">∫<sub>0</sub><sup>1</sup> <i>x</i> <i>dx</i></p>')
    eq(R([==[\( a^2 + b^2 = c^2 \)]==]),
       "<i>a</i><sup>2</sup> + <i>b</i><sup>2</sup> = <i>c</i><sup>2</sup>")
end)

T:test("multi-line $$ block", function()
    local out = R("$$\n\\sum_{k=0}^{n} k = \\frac{n(n+1)}{2}\n$$")
    has(out, '<p class="koa-math">∑<sub><i>k</i>=0</sub><sup><i>n</i></sup> <i>k</i> = (<i>n</i>(<i>n</i>+1))/2</p>')
end)

T:test("prose guard: prices and plain numbers stay prose", function()
    eq(R("It costs $5 and 10$ dollars"), "It costs $5 and 10$ dollars")
    eq(R("just $5$ here"), "just $5$ here")
    eq(R("between $3 and $5, ok"), "between $3 and $5, ok")
    eq(R("Price is $10 today."), "Price is $10 today.")
    eq(R("$2x$ and $-1$"), "2<i>x</i> and −1")
    eq(R("$ x $ spaced"), "$ x $ spaced")
end)

T:test("code fences and inline code untouched", function()
    local src = "text\n```\n$y_1$ and $$z$$\n```\nafter $w$ and `$x^2$` code"
    eq(R(src), "text\n```\n$y_1$ and $$z$$\n```\nafter <i>w</i> and `$x^2$` code")
end)

T:test("no math: text returned unchanged (identity, incl. nil)", function()
    local s = "plain paragraph\n\nwith **bold** and _under_ scores"
    eq(R(s), s)
    assert(R(nil) == nil)
    assert(M.hasMath("nothing") == false)
    assert(M.hasMath("$x$") == true)
end)

T:test("trailing newline preserved either way", function()
    eq(R("$x$\n"), "<i>x</i>\n")
    eq(R("$x$"), "<i>x</i>")
end)

T:test("brackets in math are entity-escaped (preprocessBrackets runs after)", function()
    eq(RM("[a, b]"), "&#91;<i>a</i>, <i>b</i>&#93;")
end)

print(string.format("\n  Results: %d passed, %d failed", T.passed, T.failed))

if arg and arg[0] and arg[0]:match("test_math%.lua$") then
    os.exit(T.failed == 0 and 0 or 1)
end

return T.failed == 0

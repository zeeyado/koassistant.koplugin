--[[
koassistant_math.lua — LaTeX math → readable HTML for the Markdown viewer (#105).

Pure module, no KOReader dependencies, unit-tested in tests/unit/test_math.lua.

WHY: the chat viewer renders through MuPDF, which has no MathML and no
JavaScript, so LaTeX in responses ("$\vec{F} = q(\vec{v} \times \vec{B})$")
showed as raw source on device. Models are NOT told to avoid LaTeX (the
stored text keeps the original notation, which Obsidian/Typora/GitHub render
perfectly on export); this is a DISPLAY-ONLY view transform, applied at the
markdown pre-pass, never to saves, copies, exports or the plain-text view.

WHAT RENDERS (probed headlessly against the bundled libwrap-mupdf 2026-09-02;
MuPDF ships its own Noto fonts on every platform, so the desktop probe is
representative):
  - Greek, operators, relations, arrows, set/logic symbols → Unicode
  - ^ / _ → <sup> / <sub> (MuPDF renders both well)
  - \vec \hat \bar \dot \tilde → combining marks (render fine on Noto Sans)
  - \frac{a}{b} → a/b with parentheses around multi-token sides (inline
    tables break the line and multi-cell rows collapse under MuPDF's fixed
    table layout, so stacked fractions are a v2 item, see the plan)
  - \sqrt[n]{x} → √x / √(x+1) / ⁿ√(x)
  - \sum_{i=1}^{n} → ∑<sub>i=1</sub><sup>n</sup>; \lim_{x \to 0} → lim<sub>x→0</sub>
  - \text{...} / \mathrm / \operatorname → upright; \mathbf → bold; \mathbb → ℝ ℕ ℤ ℚ ℂ
  - \left / \right dropped, delimiters kept; matrices flattened "(a, b; c, d)"
  - display math ($$, \[ \]) → its own centered paragraph, \\ = new line
  - unknown \commands stay literal, so a bad parse never destroys text

DELIMITERS accepted: $$...$$ / \[...\] (display), \(...\) / $...$ (inline;
the single-$ form needs a LaTeX-looking body so "$5 and 10$" in prose stays
prose). Code fences and inline code are never touched.
]]

local M = {}

-- ---------------------------------------------------------------------------
-- Symbol tables
-- ---------------------------------------------------------------------------

local GREEK = {
    alpha = "α", beta = "β", gamma = "γ", delta = "δ", epsilon = "ϵ", varepsilon = "ε",
    zeta = "ζ", eta = "η", theta = "θ", vartheta = "ϑ", iota = "ι", kappa = "κ",
    lambda = "λ", mu = "μ", nu = "ν", xi = "ξ", omicron = "ο", pi = "π", varpi = "ϖ",
    rho = "ρ", varrho = "ϱ", sigma = "σ", varsigma = "ς", tau = "τ", upsilon = "υ",
    phi = "ϕ", varphi = "φ", chi = "χ", psi = "ψ", omega = "ω",
    Gamma = "Γ", Delta = "Δ", Theta = "Θ", Lambda = "Λ", Xi = "Ξ", Pi = "Π",
    Sigma = "Σ", Upsilon = "Υ", Phi = "Φ", Psi = "Ψ", Omega = "Ω",
}

local SYMBOLS = {
    -- operators
    cdot = "·", times = "×", div = "÷", pm = "±", mp = "∓", ast = "∗", star = "⋆",
    circ = "∘", bullet = "•", oplus = "⊕", ominus = "⊖", otimes = "⊗", odot = "⊙",
    setminus = "∖", wr = "≀", amalg = "⨿",
    -- relations
    leq = "≤", le = "≤", geq = "≥", ge = "≥", neq = "≠", ne = "≠", approx = "≈",
    equiv = "≡", sim = "∼", simeq = "≃", cong = "≅", propto = "∝", ll = "≪", gg = "≫",
    prec = "≺", succ = "≻", perp = "⊥", parallel = "∥", mid = "∣", nmid = "∤",
    doteq = "≐", asymp = "≍", models = "⊨", vdash = "⊢", dashv = "⊣",
    -- arrows
    to = "→", rightarrow = "→", leftarrow = "←", leftrightarrow = "↔",
    Rightarrow = "⇒", Leftarrow = "⇐", Leftrightarrow = "⇔", iff = "⇔", implies = "⇒",
    mapsto = "↦", longrightarrow = "⟶", longleftarrow = "⟵", Longrightarrow = "⟹",
    uparrow = "↑", downarrow = "↓", nearrow = "↗", searrow = "↘", hookrightarrow = "↪",
    -- sets and logic
    ["in"] = "∈", notin = "∉", ni = "∋", subset = "⊂", subseteq = "⊆", supset = "⊃",
    supseteq = "⊇", cup = "∪", cap = "∩", emptyset = "∅", varnothing = "∅",
    forall = "∀", exists = "∃", nexists = "∄", neg = "¬", lnot = "¬", land = "∧",
    wedge = "∧", lor = "∨", vee = "∨", therefore = "∴", because = "∵",
    -- misc
    infty = "∞", partial = "∂", nabla = "∇", hbar = "ℏ", ell = "ℓ", Re = "ℜ", Im = "ℑ",
    aleph = "ℵ", prime = "′", degree = "°", angle = "∠", triangle = "△", square = "□",
    ldots = "…", dots = "…", cdots = "⋯", vdots = "⋮", ddots = "⋱", dotsc = "…",
    dotsb = "⋯", langle = "⟨", rangle = "⟩", lfloor = "⌊", rfloor = "⌋", lceil = "⌈",
    rceil = "⌉", lvert = "|", rvert = "|", lVert = "‖", rVert = "‖", vert = "|",
    Vert = "‖", backslash = "\\", top = "⊤", bot = "⊥", checkmark = "✓", surd = "√",
    -- big operators (limits attach as sub/sup)
    sum = "∑", prod = "∏", coprod = "∐", int = "∫", iint = "∬", iiint = "∭",
    oint = "∮", bigcup = "⋃", bigcap = "⋂", bigoplus = "⨁", bigotimes = "⨂",
    bigvee = "⋁", bigwedge = "⋀",
    -- spacing
    [","] = " ", [";"] = " ", [":"] = " ", ["!"] = "", [" "] = " ", quad = "  ",
    qquad = "    ", enspace = " ", thinspace = " ",
    -- escaped characters
    ["{"] = "{", ["}"] = "}", ["%"] = "%", ["$"] = "$", ["#"] = "#", ["&"] = "&amp;",
    ["_"] = "&#95;", ["|"] = "‖", lbrace = "{", rbrace = "}", lt = "&lt;", gt = "&gt;",
}

-- Function names render upright, followed by a thin gap
local FUNCTIONS = {
    sin = true, cos = true, tan = true, cot = true, sec = true, csc = true,
    arcsin = true, arccos = true, arctan = true, sinh = true, cosh = true, tanh = true,
    coth = true, log = true, ln = true, lg = true, exp = true, lim = true, liminf = true,
    limsup = true, max = true, min = true, sup = true, inf = true, det = true, dim = true,
    ker = true, deg = true, gcd = true, arg = true, hom = true, Pr = true, mod = true,
    bmod = true, pmod = true,
}

-- Combining marks for accents (single-character bases; longer bases go bold)
local ACCENTS = {
    vec = "\226\131\151",   -- U+20D7 combining right arrow above
    hat = "\204\130",       -- U+0302
    widehat = "\204\130",
    bar = "\204\132",       -- U+0304
    overline = "\204\133",  -- U+0305
    dot = "\204\135",       -- U+0307
    ddot = "\204\136",      -- U+0308
    tilde = "\204\131",     -- U+0303
    widetilde = "\204\131",
    breve = "\204\134",     -- U+0306
    check = "\204\140",     -- U+030C
    acute = "\204\129",     -- U+0301
    grave = "\204\128",     -- U+0300
    underline = "\204\178", -- U+0332
}

local BLACKBOARD = {
    R = "ℝ", N = "ℕ", Z = "ℤ", Q = "ℚ", C = "ℂ", P = "ℙ", H = "ℍ",
}

local CALLIGRAPHIC = {
    L = "ℒ", H = "ℋ", F = "ℱ", I = "ℐ", M = "ℳ", R = "ℛ", B = "ℬ", E = "ℰ", g = "ℊ",
    e = "ℯ", o = "ℴ", l = "ℓ",
}

-- Text-style commands: name → {open_tag, close_tag}; characters inside render
-- upright (text_depth > 0), so \text{if } reads as prose
local STYLES = {
    text = { "", "" }, textrm = { "", "" }, textnormal = { "", "" },
    mbox = { "", "" }, mathrm = { "", "" }, operatorname = { "", "" },
    textbf = { "<b>", "</b>" }, mathbf = { "<b>", "</b>" },
    boldsymbol = { "<b>", "</b>" }, bm = { "<b>", "</b>" },
    pmb = { "<b>", "</b>" },
    textit = { "<i>", "</i>" }, mathit = { "<i>", "</i>" },
    emph = { "<i>", "</i>" }, mathsf = { "", "" }, mathtt = { "", "" },
    mathfrak = { "", "" }, mathscr = { "", "" },
    underbrace = { "", "" }, overbrace = { "", "" },
    phantom = { "", "" }, hphantom = { "", "" },
}

-- Commands that swallow one argument we do not render (size/color/spacing)
local DROP_ONE_ARG = {
    label = true, tag = true, color = true, textcolor = true, hspace = true, vspace = true,
    hskip = true, mspace = true, kern = true, mkern = true,
}

-- Zero-argument commands rendered as nothing
local DROP = {
    displaystyle = true, textstyle = true, scriptstyle = true, scriptscriptstyle = true,
    left = true, right = true, big = true, Big = true, bigg = true, Bigg = true, bigl = true,
    bigr = true, Bigl = true, Bigr = true, biggl = true, biggr = true, Biggl = true,
    Biggr = true, nolimits = true, limits = true, notag = true, nonumber = true,
    small = true, large = true, Large = true, tiny = true, rm = true, it = true, bf = true,
    cal = true, mathstrut = true, strut = true, allowbreak = true,
}

-- ---------------------------------------------------------------------------
-- Tokenizer
-- ---------------------------------------------------------------------------

local UTF8_CHAR = "[\1-\127\194-\244][\128-\191]*"

-- Token: { t = "cmd"|"open"|"close"|"sup"|"sub"|"amp"|"nl"|"ws"|"ch", v = string }
local function tokenize(src)
    local toks = {}
    local pos, len = 1, #src
    while pos <= len do
        local c = src:sub(pos, pos)
        if c == "\\" then
            local name = src:match("^%a+", pos + 1)
            if name then
                toks[#toks + 1] = { t = "cmd", v = name }
                pos = pos + 1 + #name
            else
                local nxt = src:sub(pos + 1, pos + 1)
                if nxt == "\\" then
                    toks[#toks + 1] = { t = "nl" }
                elseif nxt == "" then
                    toks[#toks + 1] = { t = "ch", v = "\\" }
                else
                    toks[#toks + 1] = { t = "cmd", v = nxt }
                end
                pos = pos + 2
            end
        elseif c == "{" then
            toks[#toks + 1] = { t = "open" }; pos = pos + 1
        elseif c == "}" then
            toks[#toks + 1] = { t = "close" }; pos = pos + 1
        elseif c == "^" then
            toks[#toks + 1] = { t = "sup" }; pos = pos + 1
        elseif c == "_" then
            toks[#toks + 1] = { t = "sub" }; pos = pos + 1
        elseif c == "&" then
            toks[#toks + 1] = { t = "amp" }; pos = pos + 1
        elseif c:match("%s") then
            local run = src:match("^%s+", pos)
            toks[#toks + 1] = { t = "ws" }
            pos = pos + #run
        else
            local ch = src:match("^" .. UTF8_CHAR, pos) or c
            toks[#toks + 1] = { t = "ch", v = ch }
            pos = pos + #ch
        end
    end
    return toks
end

-- ---------------------------------------------------------------------------
-- Renderer (recursive descent over the token list)
-- ---------------------------------------------------------------------------

local function escapeChar(ch)
    if ch == "<" then return "&lt;" end
    if ch == ">" then return "&gt;" end
    if ch == "&" then return "&amp;" end
    if ch == "*" then return "∗" end
    if ch == "~" then return " " end
    if ch == "[" then return "&#91;" end
    if ch == "]" then return "&#93;" end
    return ch
end

-- Strip tags to judge how many "atoms" a rendered fragment holds.
local function plainOf(html)
    return (html:gsub("<[^>]+>", ""):gsub("&#%d+;", "x"):gsub("&%a+;", "x"))
end

local function isAtom(html)
    -- a base with scripts (x², ε₀, mv²) counts as one atom; so does a single
    -- balanced parenthesised group, so "(a+b)²/2" never grows double parens
    local plain = plainOf((html:gsub("<su[bp]>.-</su[bp]>", "")))
    if plain == "" then return true end
    if plain:match("^%b()$") then return true end
    -- one UTF-8 character, or a bare number, or a bare word
    if plain:match("^" .. UTF8_CHAR .. "$") then return true end
    if plain:match("^%d+%.?%d*$") then return true end
    if plain:match("^%a+$") then return true end
    return false
end

local function paren(html)
    if isAtom(html) then return html end
    return "(" .. html .. ")"
end

local Parser = {}
Parser.__index = Parser

local function newParser(toks, opts)
    return setmetatable({ toks = toks, i = 1, opts = opts or {}, text_depth = 0 }, Parser)
end

function Parser:peek() return self.toks[self.i] end
function Parser:next() local t = self.toks[self.i]; self.i = self.i + 1; return t end

function Parser:skipWs()
    while self:peek() and self:peek().t == "ws" do self.i = self.i + 1 end
end

-- Parse a single argument: a {group} or one token
function Parser:parseArg()
    self:skipWs()
    local t = self:peek()
    if not t then return "" end
    if t.t == "open" then
        self:next()
        return self:parseGroup()
    end
    self:next()
    return self:renderToken(t)
end

-- Optional [arg] (e.g. \sqrt[n]); returns rendered html or nil
function Parser:parseOptArg()
    self:skipWs()
    local t = self:peek()
    if not (t and t.t == "ch" and t.v == "[") then return nil end
    self:next()
    local parts = {}
    while true do
        local u = self:peek()
        if not u then break end
        if u.t == "ch" and u.v == "]" then self:next(); break end
        self:next()
        parts[#parts + 1] = self:renderToken(u)
    end
    return table.concat(parts)
end

-- Skip the argument of \begin{...}/\end{...}; returns the environment name
function Parser:parseEnvName()
    self:skipWs()
    local t = self:peek()
    if not (t and t.t == "open") then return "" end
    self:next()
    local name = {}
    while true do
        local u = self:next()
        if not u or u.t == "close" then break end
        if u.t == "ch" then name[#name + 1] = u.v end
    end
    return table.concat(name)
end

-- Render tokens until the matching close brace (or end); returns html
function Parser:parseGroup()
    local parts = {}
    while true do
        local t = self:peek()
        if not t then break end
        if t.t == "close" then self:next(); break end
        self:next()
        parts[#parts + 1] = self:renderToken(t)
    end
    return table.concat(parts)
end

-- Render an environment body (matrix/cases/align) until \end
function Parser:parseEnv(name)
    -- array/tabular carry a column spec argument
    if name == "array" or name == "tabular" then
        self:parseArg()
    end
    local rows, cells, cur = {}, {}, {}
    local function flushCell()
        cells[#cells + 1] = table.concat(cur)
        cur = {}
    end
    local function flushRow()
        flushCell()
        local nonempty = false
        for _idx, c in ipairs(cells) do
            if c:match("%S") then nonempty = true end
        end
        if nonempty then rows[#rows + 1] = cells end
        cells = {}
    end
    while true do
        local t = self:peek()
        if not t then break end
        if t.t == "cmd" and t.v == "end" then
            self:next()
            self:parseEnvName()
            break
        end
        self:next()
        if t.t == "amp" then
            flushCell()
        elseif t.t == "nl" then
            flushRow()
        elseif t.t == "cmd" and (t.v == "hline" or t.v == "cline") then
            if t.v == "cline" then self:parseArg() end
        else
            cur[#cur + 1] = self:renderToken(t)
        end
    end
    flushRow()
    -- trim cells
    for r = 1, #rows do
        for c = 1, #rows[r] do
            rows[r][c] = rows[r][c]:gsub("^%s+", ""):gsub("%s+$", "")
        end
    end
    local is_align = name:match("^align") or name:match("^eqn") or name == "equation"
        or name == "gather" or name == "gathered" or name == "multline" or name == "split"
    if is_align then
        -- rows are lines; cells join with a space (the & was an alignment point)
        local lines = {}
        for _idx, row in ipairs(rows) do
            lines[#lines + 1] = table.concat(row, " ")
        end
        return table.concat(lines, self.opts.display and "\n" or "; ")
    end
    if name == "cases" then
        local lines = {}
        for _idx, row in ipairs(rows) do
            lines[#lines + 1] = table.concat(row, "  ")
        end
        return "{ " .. table.concat(lines, self.opts.display and " ;\n  " or "; ") .. " }"
    end
    -- matrices: "(a, b; c, d)" with the environment's own fence
    local lines = {}
    for _idx, row in ipairs(rows) do
        lines[#lines + 1] = table.concat(row, ", ")
    end
    local body = table.concat(lines, "; ")
    if name == "pmatrix" then return "(" .. body .. ")" end
    if name == "bmatrix" then return "&#91;" .. body .. "&#93;" end
    if name == "Bmatrix" then return "{" .. body .. "}" end
    if name == "vmatrix" then return "|" .. body .. "|" end
    if name == "Vmatrix" then return "‖" .. body .. "‖" end
    return body
end

function Parser:renderCommand(name)
    if GREEK[name] then return GREEK[name] end
    if SYMBOLS[name] then return SYMBOLS[name] end
    if name == "left" or name == "right" then
        self:skipWs()
        local nxt = self:peek()
        if nxt and nxt.t == "ch" and nxt.v == "." then self:next() end
        return ""
    end
    if DROP[name] then return "" end
    if DROP_ONE_ARG[name] then self:parseArg(); return "" end
    if FUNCTIONS[name] then
        local nxt = self:peek()
        -- "\sin x" needs a gap; "\sin(" / "\sin^2" do not
        local gap = ""
        if nxt and (nxt.t == "ws" or nxt.t == "cmd" or (nxt.t == "ch" and nxt.v:match("^[%a%d]"))) then
            gap = " "
        end
        return name .. gap
    end
    if ACCENTS[name] then
        local base = self:parseArg()
        if isAtom(base) and plainOf(base):match("^" .. UTF8_CHAR .. "$") then
            -- keep the mark INSIDE any italic wrapper so it sits on the glyph
            local inner, tail = base:match("^(.-)(</[ib]>)$")
            if inner then return inner .. ACCENTS[name] .. tail end
            return base .. ACCENTS[name]
        end
        return "<b>" .. base .. "</b>"
    end
    if STYLES[name] then
        local st = STYLES[name]
        self.text_depth = self.text_depth + 1
        local body = self:parseArg()
        self.text_depth = self.text_depth - 1
        return st[1] .. body .. st[2]
    end
    if name == "mathbb" then
        local body = plainOf(self:parseArg())
        local out = {}
        for ch in body:gmatch(UTF8_CHAR) do out[#out + 1] = BLACKBOARD[ch] or ch end
        return table.concat(out)
    end
    if name == "mathcal" then
        local body = plainOf(self:parseArg())
        local out = {}
        for ch in body:gmatch(UTF8_CHAR) do out[#out + 1] = CALLIGRAPHIC[ch] or ch end
        return table.concat(out)
    end
    if name == "frac" or name == "dfrac" or name == "tfrac" or name == "cfrac" then
        local num = self:parseArg()
        local den = self:parseArg()
        return paren(num) .. "/" .. paren(den)
    end
    if name == "binom" then
        local top = self:parseArg()
        local bot = self:parseArg()
        return "(" .. top .. " choose " .. bot .. ")"
    end
    if name == "sqrt" then
        local index = self:parseOptArg()
        local body = self:parseArg()
        local radical = "√"
        if index then radical = "<sup>" .. index .. "</sup>√" end
        if isAtom(body) then return radical .. body end
        return radical .. "(" .. body .. ")"
    end
    if name == "begin" then
        local env = self:parseEnvName()
        return self:parseEnv(env)
    end
    if name == "end" then
        self:parseEnvName()
        return ""
    end
    if name == "stackrel" or name == "overset" then
        local top = self:parseArg()
        local base = self:parseArg()
        return base .. "<sup>" .. top .. "</sup>"
    end
    if name == "underset" then
        local bot = self:parseArg()
        local base = self:parseArg()
        return base .. "<sub>" .. bot .. "</sub>"
    end
    if name == "not" then
        local body = self:parseArg()
        return body .. "\204\184" -- U+0338 combining long solidus overlay
    end
    if name == "newline" or name == "cr" then
        return "\n"
    end
    -- Unknown command: keep it literal so nothing is lost
    return "\\" .. name
end

function Parser:renderToken(t)
    if t.t == "cmd" then
        return self:renderCommand(t.v)
    elseif t.t == "open" then
        return self:parseGroup()
    elseif t.t == "close" then
        return ""
    elseif t.t == "sup" then
        return "<sup>" .. self:parseArg() .. "</sup>"
    elseif t.t == "sub" then
        return "<sub>" .. self:parseArg() .. "</sub>"
    elseif t.t == "amp" then
        return " "
    elseif t.t == "nl" then
        return "\n"
    elseif t.t == "ws" then
        return " "
    else
        local ch = t.v
        if self.text_depth > 0 then
            return escapeChar(ch)
        end
        if ch:match("^%a$") then
            return "<i>" .. ch .. "</i>"
        end
        if ch == "-" then return "−" end -- U+2212 minus, not a hyphen
        return escapeChar(ch)
    end
end

-- Merge adjacent italic runs, drop empty tags, tidy spaces
local function tidy(html)
    html = html:gsub("</i><i>", "")
    html = html:gsub("<i></i>", ""):gsub("<b></b>", ""):gsub("<sup></sup>", ""):gsub("<sub></sub>", "")
    -- "x_i^2" renders sub then sup; keep the source order, only collapse spaces
    html = html:gsub("[ \t]+", " ")
    html = html:gsub("^%s+", ""):gsub("%s+$", "")
    html = html:gsub(" *\n *", "\n")
    return html
end

--- Render one LaTeX math body to HTML (no delimiters).
-- @param src string LaTeX source
-- @param display boolean true for $$ / \[ \] blocks
-- @return string html
function M.renderMath(src, display)
    local p = newParser(tokenize(src), { display = display })
    local parts = {}
    while p:peek() do
        local t = p:next()
        parts[#parts + 1] = p:renderToken(t)
    end
    local html = tidy(table.concat(parts))
    if not display then html = html:gsub("\n", " ") end
    return html
end

-- ---------------------------------------------------------------------------
-- Document pass: find math spans in markdown text, skip code
-- ---------------------------------------------------------------------------

local function wrapDisplay(html)
    local lines = {}
    for line in (html .. "\n"):gmatch("(.-)\n") do
        if line:match("%S") then
            lines[#lines + 1] = '<p class="koa-math">' .. line .. "</p>"
        end
    end
    if #lines == 0 then return "" end
    return "\n\n" .. table.concat(lines, "\n") .. "\n\n"
end

-- A single-$ body is math when it looks like LaTeX, or a bare variable /
-- expression that starts with a letter. "$5 and 10$", "$5$" stay prose.
local function looksLikeMath(body)
    if body:match("[\\^_{}]") then return true end
    if body:match("^%d[%d%.,]*$") then return false end
    if body:match("^%d[%d%.,]*%s") then return false end
    if body:match("^%d+%a") then return true end -- 2x, 3n
    return body:match("^[%a(%-]") ~= nil
end

local function convertSegment(seg)
    -- protect inline code
    local codes, n = {}, 0
    seg = seg:gsub("(`+)(.-)%1", function(ticks, body)
        n = n + 1
        codes[n] = ticks .. body .. ticks
        return "\1KOACODE" .. n .. "\1"
    end)
    -- display: $$...$$ (may span lines)
    seg = seg:gsub("%$%$(.-)%$%$", function(body)
        return wrapDisplay(M.renderMath(body, true))
    end)
    -- display: \[...\]
    seg = seg:gsub("\\%[(.-)\\%]", function(body)
        return wrapDisplay(M.renderMath(body, true))
    end)
    -- inline: \(...\)
    seg = seg:gsub("\\%((.-)\\%)", function(body)
        return M.renderMath(body, false)
    end)
    -- inline: $...$ on one line, non-space next to both delimiters
    seg = seg:gsub("%$(%S[^%$\n]-)%$", function(body)
        if body:match("%s$") then return nil end
        if not looksLikeMath(body) then return nil end
        return M.renderMath(body, false)
    end)
    -- restore inline code
    seg = seg:gsub("\1KOACODE(%d+)\1", function(k) return codes[tonumber(k)] end)
    return seg
end

--- Cheap pre-check: does the text carry any math delimiter at all?
function M.hasMath(text)
    if not text then return false end
    return text:find("$", 1, true) ~= nil or text:find("\\(", 1, true) ~= nil
        or text:find("\\[", 1, true) ~= nil
end

--- Convert every math span in a markdown document to HTML.
-- Code fences (```) and inline code are left untouched.
-- @param text string markdown
-- @return string markdown with math spans replaced by inline HTML
function M.render(text)
    if not text or not M.hasMath(text) then return text end
    local out, buf = {}, {}
    local in_fence = false
    for line in (text .. "\n"):gmatch("(.-)\n") do
        if line:match("^%s*```") then
            if #buf > 0 then
                local seg = table.concat(buf, "\n")
                out[#out + 1] = in_fence and seg or convertSegment(seg)
                buf = {}
            end
            in_fence = not in_fence
            out[#out + 1] = line
        else
            buf[#buf + 1] = line
        end
    end
    if #buf > 0 then
        local rest = table.concat(buf, "\n")
        out[#out + 1] = in_fence and rest or convertSegment(rest)
    end
    local result = table.concat(out, "\n")
    -- the split appended one trailing "\n"; keep the original ending
    if not text:match("\n$") then result = result:gsub("\n$", "") end
    return result
end

return M

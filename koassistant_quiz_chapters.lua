--[[--
Chapter-boundary resolution for the end-of-chapter quiz trigger (pure, no KOReader deps).

The trigger uses a SINGLE TOC level as "the chapters" and a range-based completion model:
a chapter owns the page span from its start to the next chapter's start, so nested
sub-entries are invisible and a parent→first-child move is not a completion. These helpers
turn a TOC entry list ({page, depth, ...}) and a level setting into the ordered list of
chapter boundaries, and locate the chapter containing a page.

"Chapter at level N" = a TOC entry at depth <= N that has no child within depth <= N
(a leaf when the tree is pruned at level N). This is self-clamping: picking a level deeper
than the book just yields every entry, and it handles mixed-depth TOCs (a flat depth-1
chapter and a nested depth-2 subchapter can both be "chapters" at level 2).
]]

local QuizChapters = {}

--- Deepest depth present in the TOC (1-based; 0 for empty).
function QuizChapters.maxDepth(toc)
    local m = 0
    for _i = 1, #toc do
        local d = toc[_i].depth or 1
        if d > m then m = d end
    end
    return m
end

--- Ordered list of TOC indices that are "chapters" at the given level (leaf-at-N).
-- @param toc array of { page, depth }
-- @param level number
-- @return array of toc indices (ascending, i.e. page order)
function QuizChapters.chapterIndices(toc, level)
    local out = {}
    local n = #toc
    for i = 1, n do
        local d = toc[i].depth or 1
        if d <= level then
            local is_chapter
            if d == level then
                -- At the chosen level: any deeper entries are below the cut, so this is a chapter.
                is_chapter = true
            else
                -- Shallower than the level: it's a chapter only if it has no child (the next
                -- entry isn't deeper). A deeper next entry means it's a container at this level.
                local nxt = toc[i + 1]
                is_chapter = not (nxt and (nxt.depth or 1) > d)
            end
            if is_chapter then out[#out + 1] = i end
        end
    end
    return out
end

--- The toc index of the chapter whose range contains pageno (the last chapter starting
-- at or before pageno), or nil when pageno is before the first chapter (front matter).
-- @param toc array of { page, depth }
-- @param indices array from chapterIndices (page-ordered)
-- @param pageno number
-- @return toc index | nil
function QuizChapters.currentChapter(toc, indices, pageno)
    local cur = nil
    for _i = 1, #indices do
        local idx = indices[_i]
        if (toc[idx].page or 1) <= pageno then
            cur = idx
        else
            break
        end
    end
    return cur
end

--- Auto-detect the chapter level: the deepest level whose chapters average at least
-- `min_pages` pages. Falls back to level 1.
-- @param toc array of { page, depth }
-- @param pagecount number  total pages (for the last chapter's span)
-- @param min_pages number
-- @return number level
function QuizChapters.autoLevel(toc, pagecount, min_pages)
    min_pages = min_pages or 1
    local maxd = QuizChapters.maxDepth(toc)
    for level = maxd, 2, -1 do
        local idxs = QuizChapters.chapterIndices(toc, level)
        if #idxs > 0 then
            local total = 0
            for k = 1, #idxs do
                local startp = toc[idxs[k]].page or 1
                local nextp = idxs[k + 1] and (toc[idxs[k + 1]].page or startp) or (pagecount + 1)
                total = total + (nextp - startp)
            end
            if (total / #idxs) >= min_pages then return level end
        end
    end
    return 1
end

return QuizChapters

-- Markdown samples: every shape an answer takes, and the ones whose marks
-- pair across lines (math, code spans, brackets, a list's indented content).
-- The Markdown view of the streaming window converts an answer piece by piece
-- (koassistant/request/stream_markdown.lua, safeCut and convert); each sample
-- is streamed in small steps and compared with the whole conversion at every
-- step (tests/scenarios/s13_stream_pieces.lua on the app's own runtime,
-- tests/unit/test_stream_markdown.lua where the app is installed). A sample
-- per rule of the cut: the scenario takes each rule out in turn and expects a
-- difference.
local samples = {}
local function add(name, text) samples[#samples + 1] = { name = name, text = text } end

add("paragraphs", [[
The **lantern** keeper counted the steps to the harbour and wrote *each* number down.
A second line of the same paragraph, with `code` in it.

A second paragraph. It has a [link](https://example.org/a_(b)) and a bare https://example.org/x.

# A heading

## A second heading with **bold**

Text right after a heading.
### A heading right after text
More text.

---

After a rule.
]])

add("tight and loose lists", [[
Intro line:
- one
- two with *emphasis*
- three

- a loose item

- another loose item

* a star item
* another

1. first
2. second
3. third

1. loose first

2. loose second

3. loose third

Closing paragraph.
]])

add("nested lists", [[
1. First point
   - sub a
   - sub b

2. Second point
   - sub c
     - deeper d

   A paragraph inside the second point.

3. Third point

After the list.

- top
  continued on the next line
  and one more
- next
    - nested with four spaces
- last

Done.
]])

add("list then indented paragraph then item", [[
- item one

  nested paragraph of item one

- item two

text at the margin

  an indented line after a blank

- a list after the indented line
]])

add("code fences", [[
Before the code.

```lua
local x = 1

-- a comment with $$ and [brackets] and `ticks`
if x then
    print("- not a list")
end

# not a heading
```

Between.

```
plain fence

1. not a list
```
Text right after a fence.

- item with code:
  ```
  inside an item

  still inside
  ```
- next item

End.
]])

add("fence with another indent inside", [[
Start.

```
  ```

still code for the library

```

After.
]])

add("block quotes", [[
> A quote line.
> Its second line.
lazy continuation line

After the quote.

> A second quote
>
> with a blank quoted line.

> - a list in a quote
> - second

Plain.

> > nested quote

End.
]])

add("tables", [[
Here is a table:

| Name | Value |
|------|-------|
| a    | 1     |
| b    | 2     |

And a wide one:

| A | B | C | D |
|---|---|---|---|
| 1 | 2 | 3 | 4 |
Text right after the table.

Last.
]])

add("math", [[
Inline $x_1 + y_2$ and \(a^2\) in prose, and $5 and 10$ stays prose.

$$
E = mc^2
$$

A display block with a blank line inside:

\[
a = b

c = d
\]

Between two displays.

$$x_1 = \frac{1}{2}$$ and text after it.

The price is $$ odd here.

A paragraph after an odd pair.

Now $$ closes it.

Final paragraph with $z$.
]])

add("links and brackets", [[
A footnote mark [1] and a [bracketed aside].

[note]: this line looks like a link definition

[Speaker]: and so does this one

A [link](https://example.org) here.

An open [bracket that never closes

and then ](https://example.org/late) later.

A link whose address runs on [text](https://example.org/a

b) after a blank line.

A second one [more](https://example.org/(nested

still) open) here.

Plain end.
]])

add("task lists", [[
To do:

- [ ] first task
- [x] done task
- plain item

1. [ ] numbered task
2. [X] numbered done

After.
]])

add("setext headings and rules", [[
Title
=====

Text under the title.

Subtitle
--------

Text under the subtitle.

***

___

Text
---
More text.
]])

add("arabic", [[
هذا نص عربي في فقرة أولى مع كلمة **غامقة** فيها.

English paragraph in the middle of the answer.

- بند عربي أول
- بند عربي ثان

1. first English item
2. بند مرقم

> اقتباس عربي قصير

## عنوان عربي

Synonyms: كلمة، لفظة، مفردة

نهاية النص.
]])

add("hebrew and emoji", [[
שלום עולם, זו פסקה בעברית.

A paragraph with emoji 🙂 and a flag 🇸🇪 and a check ✓.

✅ Done item
❌ Failed item

- 🔍 search
- 📚 books

סוף.
]])

add("fake bullets and inline html", [[
• first fake bullet
• second fake bullet
• third

A line with <b>inline html</b> and a<br>break.

<>
a comment line above is dropped

&amp; entities &lt;stay&gt;.
]])

add("stray marks", [[
A stray ` backtick in prose.

Then math $x_1$ after it, which the stray tick covers.

Another ` closes the pair.

Now $y_2$ is math again.

A stray ** pair and a *single star.

Three *** stars and __underscores__ and ~~strike~~.

End.
]])

add("indented and tabbed", "Margin paragraph.\n\n    four spaces in\n    second line\n\n\tA tabbed line\n\nBack at the margin.\n\n  two spaces\n\n> quote after indent\n\n- item after quote\n\nEnd.\n")

add("crlf", "First paragraph.\r\n\r\n- item one\r\n- item two\r\n\r\nSecond paragraph.\r\n\r\n```\r\ncode\r\n```\r\n\r\nEnd.\r\n")

add("no trailing blank, long single lines", "One long paragraph on a single line that goes on and on, as models write them, with **bold** and more words until it ends.\n\nA second long paragraph on a single line, again with many words so that a cut before it matters, and *emphasis* near the end.\n\n- a list item that is long enough to wrap on a reader's screen, with `code`\n- a second one\n\nThe last paragraph has no newline at its end")

add("heading list paragraph mix", [[
## Summary

The answer in one line.

## Details

1. **First.** A sentence about the first thing.
2. **Second.** A sentence about the second thing.

   More about the second thing, indented under it.

3. **Third.**

## Code

```python
def f(x):
    return x[0]

print(f([1, 2]))
```

## Table

| Key | Meaning |
|-----|---------|
| a   | alpha   |

## End

That is all.
]])

add("math across blank lines", [[
Inline math \(a +

b\) across a blank line, then text.

\[
a[1] = b

c = d
\]

A paragraph, then `\(` in code and \(x\) outside it.

Next paragraph.

Code with one tick: `\[` and a display \[ y \] after.

Last.
]])

add("emphasis across paragraphs, html blocks", [[
A **bold that does not close

and closes** here, with *one star

and its* partner.

<div>

inside a div

</div>

## Heading with marks ##

Label:
- a list right under a label
- second
Text right under the list.

| A | B |
|---|---|
| 1 | 2 |
- a list right under a table

End.
]])

add("fences in list items", [[
- item

  ```
  code under the item

  more code
  ```

- next

1. numbered
   ```
   code inside
   ```
2. second

   text under second

   - deep item

     deep text

3. third

After.
]])

add("a bracket the math pass uncovers", [[
Code with one tick: `\[` and a display \[ y \] after.

and then ](https://example.org/late) later.

End.
]])

add("dollars in code and in prose", [[
Use `$$` in code, and a $$ open display

paragraph with x_1 and y_2

closes $$ here.

After.
]])

add("dollars in two fences", [[
```
echo $$
```

Some *emphasis* between the two.

* a star item

```
echo $$
```

After, with *emphasis* again.
]])

add("stray ticks around a fence", [[
A stray ` tick before a fence.

```
code
```

Another stray ` tick after it, then $x_1$ math.

A paragraph with $y_2$ math.

A closing ` tick and $z_3$.

End.
]])

-- Numbered lists as answers number them (koassistant/ui/list_numbers.lua): a
-- list with blank lines between its items, a list that goes on after another
-- block, a list that starts past 1, every item written "1."
add("numbered lists that go on", [[
Three steps, with blank lines between them:

1. **Fill** the lantern with oil.

2. **Trim** the wick to a finger's width.

3. **Light** it before the tide turns.

Then the same steps with their reasons under them:

1. **Fill** the lantern

The oil must reach the brass ring, no higher.

2. **Trim** the wick

- a long wick smokes
- a short one gutters

3. **Light** it

> Before the tide turns, the keeper said.

The count goes on from where the last page stopped:

4. Close the shutter.
5. Note the hour in the ledger.

And one written the lazy way:

1. first
1. second
1. third

End of the lists.
]])

-- A right-to-left table is written with its rows in reverse and a table's
-- direction is judged on the whole document (koassistant/ui/bidi.lua, B693):
-- the pieces must give the whole conversion's table, in an Arabic answer and
-- in an English one that holds an Arabic column
add("tables in a right-to-left answer", [[
هذه كلمات الدرس مع معانيها، في جدول من ثلاثة أعمدة:

| الكلمة | المعنى | English |
|--------|:------:|--------:|
| عاصمة | المدينة الرئيسية في البلاد | capital. |
| نهر | مجرى ماء |
| جسر | بناء فوق النهر | bridge |

وهذا جدول أعرض، يظهر كل صف فيه كسطور:

| الكلمة | المعنى | النوع | English |
|--------|--------|-------|---------|
| عاصمة | المدينة الرئيسية | اسم | capital |
| نهر | مجرى ماء | اسم | river |

وهذا آخر سطر في الجواب.
]])

add("an arabic column in an english table", [[
Here are the words of the lesson, with their meanings:

| Word | Meaning | Note |
|------|---------|------|
| عاصمة | capital | the main city of a country |
| نهر | river | a stream of water |

That is the end of the answer.
]])

return samples

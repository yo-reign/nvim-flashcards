describe("parser", function()
  local parser

  before_each(function()
    package.loaded["flashcards.parser"] = nil
    package.loaded["flashcards.utils"] = nil
    parser = require("flashcards.parser")
  end)

  -- ==========================================================================
  -- Inline cards
  -- ==========================================================================

  describe("inline cards", function()
    it("parses basic front ::: back", function()
      local cards, errors = parser.parse("test.md", "What is 2+2? ::: 4", "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("What is 2+2?", cards[1].front)
      assert.equals("4", cards[1].back)
      assert.is_false(cards[1].reversible)
    end)

    it("parses reversible front :?: back", function()
      local cards, errors = parser.parse("test.md", "Term :?: Definition", "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("Term", cards[1].front)
      assert.equals("Definition", cards[1].back)
      assert.is_true(cards[1].reversible)
    end)

    it("parses inline card without spaces around :::", function()
      local cards, errors = parser.parse("test.md", "front:::back", "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("front", cards[1].front)
      assert.equals("back", cards[1].back)
      assert.is_false(cards[1].reversible)
    end)

    it("parses reversible card without spaces around :?:", function()
      local cards, errors = parser.parse("test.md", "term:?:definition", "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("term", cards[1].front)
      assert.equals("definition", cards[1].back)
      assert.is_true(cards[1].reversible)
    end)

    it("parses inline card with mixed spacing around :::", function()
      local cards, errors = parser.parse("test.md", "front::: back", "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("front", cards[1].front)
      assert.equals("back", cards[1].back)
    end)

    it("parses no-space inline card with tags and ID", function()
      local cards, errors = parser.parse("test.md", "Q:::A #math <!-- fc:abc12345 -->", "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("Q", cards[1].front)
      assert.equals("A", cards[1].back)
      assert.equals("abc12345", cards[1].id)
      assert.same({ "math" }, cards[1].tags)
    end)

    it("extracts tags from inline cards", function()
      local cards, errors = parser.parse("test.md", "Q ::: A #math #algebra/linear", "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.same({ "math", "algebra/linear" }, cards[1].tags)
      -- Tags should be stripped from back text
      assert.equals("A", cards[1].back)
    end)

    it("extracts card ID from <!-- fc:id --> comment", function()
      local cards, errors = parser.parse("test.md", "Q ::: A <!-- fc:abc12345 -->", "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("abc12345", cards[1].id)
    end)

    it("detects suspended flag", function()
      local cards, errors = parser.parse("test.md", "Q ::: A <!-- fc:abc12345 !suspended -->", "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("abc12345", cards[1].id)
      assert.is_true(cards[1].suspended)
    end)

    it("extracts note annotation from next line", function()
      local content = table.concat({
        "Q ::: A <!-- fc:abc12345 -->",
        "<!-- note: Serge Lang Ch.1 p.12 -->",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("Serge Lang Ch.1 p.12", cards[1].note)
    end)

    it("ignores lines inside markdown code blocks", function()
      local content = table.concat({
        "```",
        "not a card ::: this is code",
        "```",
        "Real Q ::: Real A",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("Real Q", cards[1].front)
      assert.equals("Real A", cards[1].back)
    end)

    it("parses multiple cards in one file", function()
      local content = table.concat({
        "Q1 ::: A1",
        "Q2 ::: A2",
        "Q3 :?: A3",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(3, #cards)
      assert.equals("Q1", cards[1].front)
      assert.equals("Q2", cards[2].front)
      assert.equals("Q3", cards[3].front)
      assert.is_true(cards[3].reversible)
    end)

    it("sets correct line numbers", function()
      local content = table.concat({
        "# Heading",
        "",
        "Q1 ::: A1",
        "Q2 ::: A2",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(2, #cards)
      assert.equals(3, cards[1].line)
      assert.equals(4, cards[2].line)
    end)

    it("sets file_path from argument", function()
      local cards, errors = parser.parse("math/algebra.md", "Q ::: A", "")
      assert.equals(0, #errors)
      assert.equals("math/algebra.md", cards[1].file_path)
    end)

    it("defaults suspended to false when no flag", function()
      local cards, errors = parser.parse("test.md", "Q ::: A <!-- fc:abc12345 -->", "")
      assert.equals(0, #errors)
      assert.is_false(cards[1].suspended)
    end)

    it("handles tags with card ID together", function()
      local cards, errors = parser.parse("test.md", "Q ::: A #math #calc <!-- fc:abc12345 -->", "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("abc12345", cards[1].id)
      assert.same({ "math", "calc" }, cards[1].tags)
      assert.equals("A", cards[1].back)
    end)

    it("does not pick up note from non-adjacent line", function()
      local content = table.concat({
        "Q ::: A",
        "some text",
        "<!-- note: should not attach -->",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.is_nil(cards[1].note)
    end)

    it("ignores cards inside fenced code blocks with language", function()
      local content = table.concat({
        "```python",
        "Q ::: A",
        "```",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(0, #cards)
    end)

    it("resumes parsing after code block ends", function()
      local content = table.concat({
        "```",
        "fake ::: card",
        "```",
        "real ::: card",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("real", cards[1].front)
    end)

    it("defaults id to nil and note to nil when absent", function()
      local cards, errors = parser.parse("test.md", "Q ::: A", "")
      assert.equals(0, #errors)
      assert.is_nil(cards[1].id)
      assert.is_nil(cards[1].note)
      assert.is_false(cards[1].suspended)
      assert.same({}, cards[1].tags)
    end)
  end)

  -- ==========================================================================
  -- Fenced cards
  -- ==========================================================================

  describe("fenced cards", function()
    it("parses basic :::card ... :-: ... :::end", function()
      local content = table.concat({
        ":::card",
        "What is recursion?",
        ":-:",
        "A function that calls itself.",
        ":::end",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("What is recursion?", cards[1].front)
      assert.equals("A function that calls itself.", cards[1].back)
      assert.is_false(cards[1].reversible)
    end)

    it("parses reversible :?:card ... :-: ... :?:end", function()
      local content = table.concat({
        ":?:card",
        "Term",
        ":-:",
        "Definition",
        ":?:end",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("Term", cards[1].front)
      assert.equals("Definition", cards[1].back)
      assert.is_true(cards[1].reversible)
    end)

    it("extracts tags on closing line", function()
      local content = table.concat({
        ":::card",
        "Q",
        ":-:",
        "A",
        ":::end #math #algebra",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.same({ "math", "algebra" }, cards[1].tags)
    end)

    it("extracts card ID on opening line", function()
      local content = table.concat({
        ":::card <!-- fc:xyz98765 -->",
        "Q",
        ":-:",
        "A",
        ":::end",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("xyz98765", cards[1].id)
    end)

    it("preserves multi-line content with embedded code blocks", function()
      local content = table.concat({
        ":::card",
        "What does this function do?",
        "",
        "```python",
        "def foo():",
        '    return "bar"',
        "```",
        ":-:",
        "It returns the string bar.",
        "",
        "```python",
        "assert foo() == 'bar'",
        "```",
        ":::end",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      -- Front should contain the code block
      assert.truthy(cards[1].front:find("```python"))
      assert.truthy(cards[1].front:find("def foo"))
      -- Back should also preserve code
      assert.truthy(cards[1].back:find("assert foo"))
    end)

    it("does not treat :-: inside code block within fenced card as separator", function()
      local content = table.concat({
        ":::card",
        "Front text",
        "```",
        ":-:",
        "```",
        ":-:",
        "Actual back",
        ":::end",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      -- The front should contain the code block with :-: inside it
      assert.truthy(cards[1].front:find("```\n:-:\n```", 1, true))
      assert.equals("Actual back", cards[1].back)
    end)

    it("does not treat :::end inside code block within fenced card as close", function()
      local content = table.concat({
        ":::card",
        "Front",
        ":-:",
        "```",
        ":::end",
        "```",
        "more back content",
        ":::end",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      -- Back should include the code block with :::end inside it
      assert.truthy(cards[1].back:find("```\n:::end\n```"))
      assert.truthy(cards[1].back:find("more back content"))
    end)

    it("reports error for unclosed fenced card at EOF", function()
      local content = table.concat({
        ":::card",
        "Q",
        ":-:",
        "A",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #cards)
      assert.equals(1, #errors)
      assert.truthy(errors[1].message:lower():find("unclosed"))
      assert.equals(1, errors[1].line)
    end)

    it("reports error for missing :-: separator", function()
      local content = table.concat({
        ":::card",
        "Q",
        "A",
        ":::end",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #cards)
      assert.equals(1, #errors)
      assert.truthy(errors[1].message:lower():find("separator") or errors[1].message:find(":-:"))
    end)

    it("extracts note annotation on line after :::end", function()
      local content = table.concat({
        ":::card <!-- fc:abc12345 -->",
        "Q",
        ":-:",
        "A",
        ":::end #math",
        "<!-- note: From textbook p.42 -->",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("From textbook p.42", cards[1].note)
    end)

    it("sets line number to opening :::card line", function()
      local content = table.concat({
        "# Heading",
        "",
        ":::card",
        "Q",
        ":-:",
        "A",
        ":::end",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals(3, cards[1].line)
    end)

    it("handles suspended flag on fenced card", function()
      local content = table.concat({
        ":::card <!-- fc:abc12345 !suspended -->",
        "Q",
        ":-:",
        "A",
        ":::end",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.is_true(cards[1].suspended)
    end)

    it("handles tags on reversible close :?:end", function()
      local content = table.concat({
        ":?:card",
        "Term",
        ":-:",
        "Definition",
        ":?:end #vocab",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.same({ "vocab" }, cards[1].tags)
      assert.is_true(cards[1].reversible)
    end)

    it("trims leading/trailing blank lines from fenced card front and back", function()
      local content = table.concat({
        ":::card",
        "Front line 1",
        "Front line 2",
        "",
        ":-:",
        "",
        "Back line 1",
        "Back line 2",
        "",
        ":::end",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("Front line 1\nFront line 2", cards[1].front)
      assert.equals("Back line 1\nBack line 2", cards[1].back)
    end)

    it("preserves internal newlines in multi-line content", function()
      local content = table.concat({
        ":::card",
        "line1",
        "line2",
        "line3",
        ":-:",
        "back1",
        "back2",
        ":::end",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals("line1\nline2\nline3", cards[1].front)
      assert.equals("back1\nback2", cards[1].back)
    end)

    it("handles note on line after fenced card with tags", function()
      local content = table.concat({
        ":::card",
        "Q",
        ":-:",
        "A",
        ":::end #tag1",
        "<!-- note: ref -->",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.same({ "tag1" }, cards[1].tags)
      assert.equals("ref", cards[1].note)
    end)

    it("handles multiple fenced cards in sequence", function()
      local content = table.concat({
        ":::card",
        "Q1",
        ":-:",
        "A1",
        ":::end",
        ":::card",
        "Q2",
        ":-:",
        "A2",
        ":::end",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(2, #cards)
      assert.equals("Q1", cards[1].front)
      assert.equals("Q2", cards[2].front)
    end)
  end)

  -- ==========================================================================
  -- Tag scopes
  -- ==========================================================================

  describe("tag scopes", function()
    it("applies scoped tag to enclosed inline cards", function()
      local content = table.concat({
        ":#python:",
        "Q1 ::: A1",
        "Q2 ::: A2",
        ":#/python:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(2, #cards)
      assert.same({ "python" }, cards[1].tags)
      assert.same({ "python" }, cards[2].tags)
    end)

    it("handles nested scopes giving inner card both tags", function()
      local content = table.concat({
        ":#python:",
        ":#decorators:",
        "Q1 ::: A1",
        ":#/decorators:",
        "Q2 ::: A2",
        ":#/python:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(2, #cards)
      -- Q1 gets both python and decorators
      assert.truthy(vim.tbl_contains(cards[1].tags, "python"))
      assert.truthy(vim.tbl_contains(cards[1].tags, "python/decorators"))
      -- Q2 gets only python
      assert.same({ "python" }, cards[2].tags)
    end)

    it("merges scoped and inline tags", function()
      local content = table.concat({
        ":#python:",
        "Q ::: A #explicit",
        ":#/python:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.truthy(vim.tbl_contains(cards[1].tags, "python"))
      assert.truthy(vim.tbl_contains(cards[1].tags, "python/explicit"))
    end)

    it("deduplicates merged tags", function()
      local content = table.concat({
        ":#python:",
        "Q ::: A #python",
        ":#/python:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.same({ "python" }, cards[1].tags)
    end)

    it("reports error for mismatched close tag", function()
      local content = table.concat({
        ":#python:",
        "Q ::: A",
        ":#/javascript:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.truthy(#errors > 0)
      assert.truthy(errors[1].message:find("mismatch") or errors[1].message:find("expected"))
    end)

    it("reports error for close without open", function()
      local content = table.concat({
        "Q ::: A",
        ":#/orphan:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.truthy(#errors > 0)
      assert.truthy(errors[1].message:lower():find("no open") or errors[1].message:lower():find("without"))
    end)

    it("reports error for unclosed scope at EOF", function()
      local content = table.concat({
        ":#python:",
        "Q ::: A",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      -- Cards should still be parsed
      assert.equals(1, #cards)
      assert.truthy(#errors > 0)
      assert.truthy(errors[1].message:lower():find("unclosed"))
    end)

    it("applies scoped tags to fenced cards too", function()
      local content = table.concat({
        ":#python:",
        ":::card",
        "Q",
        ":-:",
        "A",
        ":::end #algo",
        ":#/python:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.truthy(vim.tbl_contains(cards[1].tags, "python"))
      assert.truthy(vim.tbl_contains(cards[1].tags, "python/algo"))
    end)

    it("cards after scope close do not get scope tags", function()
      local content = table.concat({
        ":#python:",
        "Q1 ::: A1",
        ":#/python:",
        "Q2 ::: A2",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(2, #cards)
      assert.same({ "python" }, cards[1].tags)
      assert.same({}, cards[2].tags)
    end)

    it("merges scoped tags with fenced card closing tags", function()
      local content = table.concat({
        ":#math:",
        ":::card",
        "Q",
        ":-:",
        "A",
        ":::end #algebra",
        ":#/math:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.truthy(vim.tbl_contains(cards[1].tags, "math"))
      assert.truthy(vim.tbl_contains(cards[1].tags, "math/algebra"))
    end)

    it("nests inline tags under scope prefix", function()
      local content = table.concat({
        ":#c:",
        "Q ::: A #func",
        ":#/c:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.same({ "c", "c/func" }, cards[1].tags)
    end)

    it("nests inline tags under deep scope prefix", function()
      local content = table.concat({
        ":#c:",
        ":#networking:",
        "Q ::: A #sockets",
        ":#/networking:",
        ":#/c:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.same({ "c", "c/networking", "c/networking/sockets" }, cards[1].tags)
    end)

    it("builds hierarchical tags from nested scopes", function()
      local content = table.concat({
        ":#c:",
        ":#beej-guide-c:",
        "Q ::: A",
        ":#/beej-guide-c:",
        ":#/c:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.same({ "c", "c/beej-guide-c" }, cards[1].tags)
    end)

    it("drops inline tags that duplicate a raw scope name", function()
      local content = table.concat({
        ":#python:",
        ":#decorators:",
        "Q ::: A #python #decorators",
        ":#/decorators:",
        ":#/python:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      -- #python and #decorators match raw scope names, so they're dropped
      -- only scope-provided tags remain
      assert.same({ "python", "python/decorators" }, cards[1].tags)
    end)

    it("drops inline tag matching full hierarchical scope path", function()
      local content = table.concat({
        ":#python:",
        ":#decorators:",
        "Q ::: A #python/decorators",
        ":#/decorators:",
        ":#/python:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      -- #python/decorators matches the full scope path, so it's dropped
      assert.same({ "python", "python/decorators" }, cards[1].tags)
    end)

    it("nests already-hierarchical inline tag under scope prefix", function()
      local content = table.concat({
        ":#c:",
        "Q ::: A #net/tcp",
        ":#/c:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.same({ "c", "c/net/tcp" }, cards[1].tags)
    end)

    it("drops only duplicate inline tags and nests the rest", function()
      local content = table.concat({
        ":#python:",
        "Q ::: A #python #typing",
        ":#/python:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.same({ "python", "python/typing" }, cards[1].tags)
    end)

    it("drops inline tag matching outer scope name in nested scopes", function()
      local content = table.concat({
        ":#python:",
        ":#decorators:",
        "Q ::: A #python #extra",
        ":#/decorators:",
        ":#/python:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      -- #python matches outer scope name, dropped
      -- #extra does not match any scope name, nested under full prefix
      assert.same({ "python", "python/decorators", "python/decorators/extra" }, cards[1].tags)
    end)

    it("nests fenced close tags under deep scope prefix", function()
      local content = table.concat({
        ":#c:",
        ":#networking:",
        ":::card",
        "Q",
        ":-:",
        "A",
        ":::end #sockets",
        ":#/networking:",
        ":#/c:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.same({ "c", "c/networking", "c/networking/sockets" }, cards[1].tags)
    end)

    it("decomposes compound scope tag into parent segments", function()
      local content = table.concat({
        ":#c/networking:",
        "Q ::: A",
        ":#/c/networking:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.same({ "c", "c/networking" }, cards[1].tags)
    end)

    it("nests inline tags under compound scope prefix", function()
      local content = table.concat({
        ":#c/networking:",
        "Q ::: A #sockets",
        ":#/c/networking:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.same({ "c", "c/networking", "c/networking/sockets" }, cards[1].tags)
    end)

    it("drops inline tags redundant with compound scope parent segments", function()
      local content = table.concat({
        ":#c/networking:",
        "Q ::: A #c #networking",
        ":#/c/networking:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      -- #c and #networking are both parent segments, dropped as redundant
      assert.same({ "c", "c/networking" }, cards[1].tags)
    end)

    it("decomposes compound scope nested under simple scope", function()
      local content = table.concat({
        ":#a:",
        ":#b/c:",
        "Q ::: A",
        ":#/b/c:",
        ":#/a:",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.same({ "a", "a/b", "a/b/c" }, cards[1].tags)
    end)

    it("compound and nested scopes produce equivalent tags", function()
      -- :#c/networking: should produce the same tags as :#c: + :#networking:
      local compound = table.concat({
        ":#c/networking:",
        "Q ::: A #sockets",
        ":#/c/networking:",
      }, "\n")
      local nested = table.concat({
        ":#c:",
        ":#networking:",
        "Q ::: A #sockets",
        ":#/networking:",
        ":#/c:",
      }, "\n")
      local cards_c, errors_c = parser.parse("test.md", compound, "")
      local cards_n, errors_n = parser.parse("test.md", nested, "")
      assert.equals(0, #errors_c)
      assert.equals(0, #errors_n)
      assert.same(cards_c[1].tags, cards_n[1].tags)
    end)
  end)

  -- ==========================================================================
  -- Template variables
  -- ==========================================================================

  describe("template variables", function()
    it("expands {{file.dir}}/{{file.name}} in scoped tag names", function()
      local content = table.concat({
        ":#{{file.dir}}/{{file.name}}:",
        "Q ::: A",
        ":#/math/algebra:",
      }, "\n")
      local cards, errors = parser.parse("math/algebra.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      -- Compound expanded tag decomposes into parent segments
      assert.truthy(vim.tbl_contains(cards[1].tags, "math"))
      assert.truthy(vim.tbl_contains(cards[1].tags, "math/algebra"))
    end)

    it("expands {{file.name}} in note annotations", function()
      local content = table.concat({
        "Q ::: A <!-- fc:abc12345 -->",
        "<!-- note: {{file.name}} (1.2.3:5) -->",
      }, "\n")
      local cards, errors = parser.parse("math/algebra.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("algebra (1.2.3:5)", cards[1].note)
    end)

    it("expands template vars in scoped tag close for matching", function()
      local content = table.concat({
        ":#{{file.name}}:",
        "Q ::: A",
        ":#/algebra:",
      }, "\n")
      local cards, errors = parser.parse("math/algebra.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.truthy(vim.tbl_contains(cards[1].tags, "algebra"))
    end)
  end)

  -- ==========================================================================
  -- Edge cases
  -- ==========================================================================

  describe("edge cases", function()
    it("returns 0 cards and 0 errors for empty file", function()
      local cards, errors = parser.parse("test.md", "", "")
      assert.equals(0, #cards)
      assert.equals(0, #errors)
    end)

    it("returns 0 cards for file with only text and headings", function()
      local content = table.concat({
        "# My Notes",
        "",
        "This is just regular text.",
        "",
        "## Another section",
        "",
        "More text here.",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #cards)
      assert.equals(0, #errors)
    end)

    it("does not parse line without ::: or :?: as a card", function()
      local content = "This is a normal line without any separator"
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #cards)
      assert.equals(0, #errors)
    end)

    it("does not treat ::: inside code block inside fenced card as separator", function()
      local content = table.concat({
        ":::card",
        "What does this do?",
        ":-:",
        "It prints hello.",
        "",
        "```lua",
        "-- This ::: is not a separator",
        "print('hello')",
        "```",
        ":::end",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      -- The ::: inside the code block should be part of the back content
      assert.truthy(cards[1].back:find("This ::: is not a separator"))
    end)

    it("handles code block with language specifier in normal state", function()
      local content = table.concat({
        "```python",
        "front ::: back",
        "```",
        "Real Q ::: Real A",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("Real Q", cards[1].front)
    end)

    it("handles inline card with no tags and no id", function()
      local cards, errors = parser.parse("test.md", "Simple Q ::: Simple A", "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("Simple Q", cards[1].front)
      assert.equals("Simple A", cards[1].back)
      assert.is_nil(cards[1].id)
      assert.is_false(cards[1].suspended)
      assert.same({}, cards[1].tags)
      assert.is_nil(cards[1].note)
    end)

    it("note annotation does not carry over to non-adjacent card", function()
      local content = table.concat({
        "Q1 ::: A1",
        "<!-- note: belongs to Q1 -->",
        "Q2 ::: A2",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(2, #cards)
      assert.equals("belongs to Q1", cards[1].note)
      assert.is_nil(cards[2].note)
    end)

    it("trims whitespace from inline card front and back", function()
      local cards, errors = parser.parse("test.md", "  Q  :::  A  ", "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("Q", cards[1].front)
      assert.equals("A", cards[1].back)
    end)

    it("handles mixed inline and fenced cards", function()
      local content = table.concat({
        "Q1 ::: A1",
        "",
        ":::card",
        "Q2 front",
        ":-:",
        "A2 back",
        ":::end",
        "",
        "Q3 :?: A3",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(3, #cards)
      assert.equals("Q1", cards[1].front)
      assert.equals("Q2 front", cards[2].front)
      assert.equals("Q3", cards[3].front)
      assert.is_true(cards[3].reversible)
    end)

    it("scope tags do not bleed between parse calls", function()
      local cards1, errors1 = parser.parse("test1.md", ":#python:\nQ1 ::: A1\n:#/python:", "")
      assert.equals(0, #errors1)
      assert.same({ "python" }, cards1[1].tags)

      local cards2, errors2 = parser.parse("test2.md", "Q2 ::: A2", "")
      assert.equals(0, #errors2)
      assert.same({}, cards2[1].tags)
    end)

    it("handles Windows-style CRLF line endings", function()
      local content = "Q1 ::: A1\r\nQ2 ::: A2\r\n"
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(2, #cards)
      assert.equals("Q1", cards[1].front)
      assert.equals("A1", cards[1].back)
      assert.equals("Q2", cards[2].front)
      assert.equals("A2", cards[2].back)
    end)

    it("bare ::: on a line by itself is not a card", function()
      local cards, errors = parser.parse("test.md", ":::", "")
      assert.equals(0, #cards)
    end)

    it("inline separator ::: requires non-empty front", function()
      -- " ::: back" has empty front after trim - should not be a card
      local cards, errors = parser.parse("test.md", " ::: back", "")
      assert.equals(0, #cards)
    end)

    it("nested backtick code blocks tracked correctly", function()
      local content = table.concat({
        "````",
        "```",
        "Q ::: A",
        "```",
        "````",
        "Real ::: Card",
      }, "\n")
      local cards, errors = parser.parse("test.md", content, "")
      assert.equals(0, #errors)
      assert.equals(1, #cards)
      assert.equals("Real", cards[1].front)
    end)

    it("error objects have line and message fields", function()
      local content = ":::card\nQ\n:-:\nA"
      local _, errors = parser.parse("test.md", content, "")
      assert.truthy(#errors > 0)
      assert.is_number(errors[1].line)
      assert.is_string(errors[1].message)
    end)
  end)
end)

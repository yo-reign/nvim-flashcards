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
      assert.truthy(errors[1].message:lower():find("separator"))
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
      assert.truthy(vim.tbl_contains(cards[1].tags, "decorators"))
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
      assert.truthy(vim.tbl_contains(cards[1].tags, "explicit"))
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
      assert.truthy(vim.tbl_contains(cards[1].tags, "algo"))
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

    it("trims whitespace from front and back", function()
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

    it("trims trailing blank lines from fenced card front and back", function()
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
      -- Should trim leading/trailing blank lines from content
      assert.equals("Front line 1\nFront line 2", cards[1].front)
      assert.equals("Back line 1\nBack line 2", cards[1].back)
    end)
  end)
end)

describe("utils", function()
  local utils

  before_each(function()
    package.loaded["flashcards.utils"] = nil
    utils = require("flashcards.utils")
  end)

  describe("generate_id", function()
    it("returns 8-char alphanumeric string", function()
      local id = utils.generate_id()
      assert.equals(8, #id)
      assert.truthy(id:match("^[a-z0-9]+$"))
    end)

    it("generates unique ids", function()
      local ids = {}
      for _ = 1, 100 do
        local id = utils.generate_id()
        assert.is_nil(ids[id], "duplicate id: " .. id)
        ids[id] = true
      end
    end)
  end)

  describe("extract_card_id", function()
    it("extracts id from comment", function()
      local id = utils.extract_card_id("some text <!-- fc:abc12345 -->")
      assert.equals("abc12345", id)
    end)

    it("returns nil when no id", function()
      assert.is_nil(utils.extract_card_id("no id here"))
    end)

    it("detects suspended flag", function()
      local id, flags = utils.extract_card_id("text <!-- fc:abc12345 !suspended -->")
      assert.equals("abc12345", id)
      assert.truthy(flags.suspended)
    end)
  end)

  describe("format_card_id", function()
    it("formats id as comment", function()
      assert.equals("<!-- fc:abc12345 -->", utils.format_card_id("abc12345"))
    end)

    it("formats with suspended flag", function()
      assert.equals("<!-- fc:abc12345 !suspended -->",
        utils.format_card_id("abc12345", { suspended = true }))
    end)
  end)

  describe("expand_template_vars", function()
    it("expands file.name", function()
      local result = utils.expand_template_vars("{{file.name}}", "math/algebra.md", "notes/")
      assert.equals("algebra", result)
    end)

    it("expands file.dir", function()
      local result = utils.expand_template_vars("{{file.dir}}", "math/algebra.md", "notes/")
      assert.equals("math", result)
    end)

    it("expands file.path", function()
      local result = utils.expand_template_vars("{{file.path}}", "math/sub/algebra.md", "notes/")
      assert.equals("math/sub/algebra", result)
    end)

    it("handles no template vars", function()
      local result = utils.expand_template_vars("plain text", "math/algebra.md", "notes/")
      assert.equals("plain text", result)
    end)
  end)

  describe("parse_tags", function()
    it("extracts tags from text", function()
      local tags = utils.parse_tags("some text #math #algebra/linear")
      assert.same({ "math", "algebra/linear" }, tags)
    end)

    it("returns empty for no tags", function()
      assert.same({}, utils.parse_tags("no tags here"))
    end)
  end)

  describe("strip_tags", function()
    it("removes tags from text", function()
      assert.equals("some text", utils.strip_tags("some text #math #algebra"))
    end)
  end)

  describe("trim", function()
    it("trims whitespace", function()
      assert.equals("hello", utils.trim("  hello  "))
    end)
  end)

  describe("normalize_path", function()
    it("expands tilde", function()
      local home = os.getenv("HOME")
      assert.equals(home .. "/notes", utils.normalize_path("~/notes"))
    end)

    it("removes trailing slash", function()
      assert.equals("/home/user/notes", utils.normalize_path("/home/user/notes/"))
    end)
  end)

  describe("time helpers", function()
    it("now returns unix timestamp", function()
      local t = utils.now()
      assert.is_number(t)
      assert.truthy(t > 1700000000)
    end)

    it("format_interval shows human readable", function()
      assert.equals("< 1m", utils.format_interval(0))
      assert.equals("10m", utils.format_interval(0.007))
      assert.equals("1h", utils.format_interval(0.04))
      assert.equals("1d", utils.format_interval(1))
      assert.equals("7d", utils.format_interval(7))
      assert.equals("1.0mo", utils.format_interval(30))
      assert.equals("1.0y", utils.format_interval(365))
    end)
  end)
end)

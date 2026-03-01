describe("config", function()
  local config

  before_each(function()
    package.loaded["flashcards.config"] = nil
    package.loaded["flashcards.utils"] = nil
    config = require("flashcards.config")
  end)

  describe("setup", function()
    it("populates options with defaults when called with no args", function()
      config.setup()
      assert.is_not_nil(config.options)
      assert.same({}, config.options.directories)
      assert.equals("json", config.options.storage)
      assert.equals(0.85, config.options.fsrs.target_correctness)
      assert.equals(365, config.options.fsrs.maximum_interval)
      assert.equals(20, config.options.session.new_cards_per_day)
      assert.equals(0.7, config.options.ui.width)
      assert.equals(0.6, config.options.ui.height)
      assert.equals("rounded", config.options.ui.border)
      assert.is_true(config.options.auto_sync)
    end)

    it("deep merges user overrides with defaults", function()
      config.setup({
        directories = { "/tmp/test-notes" },
        fsrs = {
          target_correctness = 0.90,
        },
        session = {
          new_cards_per_day = 10,
        },
      })
      -- User overrides applied
      assert.same({ "/tmp/test-notes" }, config.options.directories)
      assert.equals(0.90, config.options.fsrs.target_correctness)
      assert.equals(10, config.options.session.new_cards_per_day)
      -- Non-overridden defaults preserved
      assert.equals(365, config.options.fsrs.maximum_interval)
      assert.is_true(config.options.fsrs.enable_fuzz)
      assert.equals("json", config.options.storage)
      assert.same({ "*.md", "*.markdown" }, config.options.file_patterns)
    end)

    it("normalizes directory paths", function()
      local home = os.getenv("HOME")
      config.setup({ directories = { "~/test-notes/" } })
      assert.equals(home .. "/test-notes", config.options.directories[1])
    end)

    it("normalizes db_path when provided", function()
      local home = os.getenv("HOME")
      config.setup({
        directories = { "/tmp/notes" },
        db_path = "~/custom-db/",
      })
      assert.equals(home .. "/custom-db", config.options.db_path)
    end)
  end)

  describe("validate", function()
    it("returns true with valid config", function()
      config.setup({ directories = { "/tmp/test-notes" } })
      local ok, err = config.validate()
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("returns false when directories is empty", function()
      config.setup({ directories = {} })
      local ok, err = config.validate()
      assert.is_false(ok)
      assert.is_not_nil(err)
      assert.truthy(err:find("directories"))
    end)

    it("returns false when setup has not been called", function()
      config.options = nil
      local ok, err = config.validate()
      assert.is_false(ok)
      assert.truthy(err:find("setup"))
    end)

    it("returns false for invalid storage type", function()
      config.setup({ directories = { "/tmp/test-notes" }, storage = "redis" })
      local ok, err = config.validate()
      assert.is_false(ok)
      assert.truthy(err:find("storage"))
    end)

    it("returns false for out-of-range target_correctness", function()
      config.setup({
        directories = { "/tmp/test-notes" },
        fsrs = { target_correctness = 0.5 },
      })
      local ok, err = config.validate()
      assert.is_false(ok)
      assert.truthy(err:find("target_correctness"))
    end)
  end)

  describe("should_ignore", function()
    before_each(function()
      config.setup({ directories = { "/tmp/notes" } })
    end)

    it("matches ignore patterns", function()
      assert.is_true(config.should_ignore("/tmp/notes/node_modules/foo.md"))
      assert.is_true(config.should_ignore("/tmp/notes/.git/config"))
      assert.is_true(config.should_ignore("/tmp/notes/.obsidian/workspace"))
      assert.is_true(config.should_ignore("/tmp/notes/.trash/old.md"))
    end)

    it("does not match normal files", function()
      assert.is_false(config.should_ignore("/tmp/notes/math/algebra.md"))
      assert.is_false(config.should_ignore("/tmp/notes/flashcards/cs.md"))
      assert.is_false(config.should_ignore("/tmp/notes/readme.md"))
    end)
  end)

  describe("get_storage_path", function()
    it("appends json filename when db_path is a directory", function()
      config.setup({
        directories = { "/tmp/notes" },
        db_path = "/tmp/custom-db/",
      })
      local path = config.get_storage_path()
      assert.equals("/tmp/custom-db/flashcards.json", path)
    end)

    it("uses db_path as-is when it is a file path", function()
      config.setup({
        directories = { "/tmp/notes" },
        db_path = "/tmp/my-data.json",
      })
      local path = config.get_storage_path()
      assert.equals("/tmp/my-data.json", path)
    end)

    it("uses first directory when db_path is nil", function()
      config.setup({
        directories = { "/tmp/notes" },
      })
      local path = config.get_storage_path()
      assert.equals("/tmp/notes/flashcards.json", path)
    end)

    it("appends sqlite filename when storage is sqlite", function()
      config.setup({
        directories = { "/tmp/notes" },
        storage = "sqlite",
        db_path = "/tmp/custom-db/",
      })
      local path = config.get_storage_path()
      assert.equals("/tmp/custom-db/flashcards.db", path)
    end)

    it("errors when no db_path or directories configured", function()
      config.setup({ directories = {} })
      assert.has_error(function()
        config.get_storage_path()
      end)
    end)
  end)
end)

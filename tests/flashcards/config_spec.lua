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
      assert.equals("sqlite", config.options.storage)
      assert.equals(0.85, config.options.fsrs.target_correctness)
      assert.equals(365, config.options.fsrs.maximum_interval)
      assert.equals(3, config.options.fsrs.graduating_interval_days)
      assert.is_false(config.options.session.new_cards_per_day)
      assert.is_true(config.options.media.enabled)
      assert.is_true(config.options.media.images.enabled)
      assert.equals(40, config.options.media.images.max_width)
      assert.equals(12, config.options.media.images.max_height)
      assert.equals("center", config.options.media.images.alignment)
      assert.is_true(config.options.media.audio.enabled)
      assert.is_false(config.options.media.audio.player)
      assert.equals("p", config.options.ui.keymaps.play_audio)
      assert.equals("o", config.options.ui.keymaps.open_media)
      assert.equals(0.7, config.options.ui.width)
      assert.equals(0.6, config.options.ui.height)
      assert.equals("rounded", config.options.ui.border)
      assert.equals(0, config.options.ui.conceallevel)
      assert.equals("", config.options.ui.concealcursor)
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
      assert.equals(3, config.options.fsrs.graduating_interval_days)
      assert.is_true(config.options.fsrs.enable_fuzz)
      assert.equals("sqlite", config.options.storage)
      assert.same({ "*.md", "*.markdown" }, config.options.file_patterns)
    end)

    it("replaces media lists instead of retaining trailing defaults", function()
      config.setup({
        media = {
          roots = { "/tmp/media/" },
          images = { extensions = { "png" } },
          audio = {
            extensions = { "wav" },
            player = { "custom-player", "--audio-only" },
          },
        },
      })

      assert.same({ "/tmp/media" }, config.options.media.roots)
      assert.same({ "png" }, config.options.media.images.extensions)
      assert.same({ "wav" }, config.options.media.audio.extensions)
      assert.same({ "custom-player", "--audio-only" }, config.options.media.audio.player)
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

    it("returns false for json storage", function()
      config.setup({ directories = { "/tmp/test-notes" }, storage = "json" })
      local ok, err = config.validate()
      assert.is_false(ok)
      assert.truthy(err:find("JSON storage is no longer supported"))
    end)

    it("returns false for invalid storage type", function()
      config.setup({ directories = { "/tmp/test-notes" }, storage = "redis" })
      local ok, err = config.validate()
      assert.is_false(ok)
      assert.truthy(err:find("storage"))
    end)

    it("accepts unlimited, zero, and positive integer new-card policies", function()
      for _, value in ipairs({ false, 0, 25 }) do
        config.setup({
          directories = { "/tmp/test-notes" },
          session = { new_cards_per_day = value },
        })
        local ok, err = config.validate()
        assert.is_true(ok, tostring(err))
      end
    end)

    it("rejects malformed new-card policies", function()
      for _, value in ipairs({ true, "20", -1, 1.5, 0 / 0, math.huge, -math.huge }) do
        config.setup({
          directories = { "/tmp/test-notes" },
          session = { new_cards_per_day = value },
        })
        local ok, err = config.validate()
        assert.is_false(ok)
        assert.truthy(err:find("session.new_cards_per_day", 1, true))
      end
    end)

    it("returns false for invalid target_correctness values", function()
      for _, value in ipairs({ 0.5, 0.98, false, "0.85", 0 / 0, math.huge }) do
        config.setup({
          directories = { "/tmp/test-notes" },
          fsrs = { target_correctness = value },
        })
        local ok, err = config.validate()
        assert.is_false(ok)
        assert.truthy(err:find("target_correctness", 1, true))
      end
    end)

    it("validates learning steps", function()
      local invalid_steps = {
        {},
        { [1] = 1, [3] = 60 },
        { first = 1 },
        { 0 },
        { -1 },
        { "10" },
        { 0 / 0 },
        { math.huge },
      }
      for _, steps in ipairs(invalid_steps) do
        config.setup({
          directories = { "/tmp/test-notes" },
          fsrs = { weights = { learning_steps = steps } },
        })
        local ok, err = config.validate()
        assert.is_false(ok)
        assert.truthy(err:find("fsrs.weights.learning_steps", 1, true))
      end

      config.setup({
        directories = { "/tmp/test-notes" },
        fsrs = { weights = { learning_steps = { 0.5, 10, 60 } } },
      })
      assert.is_true(config.validate())
    end)

    it("validates media configuration", function()
      local invalid_cases = {
        { media = false, expected = "media must be a table" },
        { media = { enabled = "yes" }, expected = "media.enabled" },
        { media = { roots = "assets" }, expected = "media.roots" },
        { media = { images = { extensions = {} } }, expected = "media.images.extensions" },
        { media = { images = { max_width = 0 } }, expected = "media.images.max_width" },
        { media = { images = { alignment = "middle" } }, expected = "media.images.alignment" },
        { media = { audio = { extensions = { "mp-3" } } }, expected = "media.audio.extensions" },
        { media = { audio = { player = "mpv" } }, expected = "media.audio.player" },
        { media = { audio = { player = {} } }, expected = "media.audio.player" },
        { ui = { keymaps = { play_audio = false } }, expected = "ui.keymaps.play_audio" },
        { ui = { keymaps = { open_media = "" } }, expected = "ui.keymaps.open_media" },
      }
      for _, case in ipairs(invalid_cases) do
        config.setup(vim.tbl_deep_extend("force", { directories = { "/tmp/test-notes" } }, case))
        local ok, err = config.validate()
        assert.is_false(ok)
        assert.truthy(err:find(case.expected, 1, true), err)
      end
    end)

    it("accepts false to disable graduation interval cap", function()
      config.setup({
        directories = { "/tmp/test-notes" },
        fsrs = { graduating_interval_days = false },
      })
      local ok, err = config.validate()
      assert.is_true(ok)
      assert.is_nil(err)
    end)

    it("returns false for invalid graduation interval cap", function()
      config.setup({
        directories = { "/tmp/test-notes" },
        fsrs = { graduating_interval_days = 0 },
      })
      local ok, err = config.validate()
      assert.is_false(ok)
      assert.truthy(err:find("graduating_interval_days"))
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
    it("appends sqlite filename when db_path is a directory", function()
      config.setup({
        directories = { "/tmp/notes" },
        db_path = "/tmp/custom-db/",
      })
      local path = config.get_storage_path()
      assert.equals("/tmp/custom-db/flashcards.db", path)
    end)

    it("uses db_path as-is when it is a file path", function()
      config.setup({
        directories = { "/tmp/notes" },
        db_path = "/tmp/my-data.db",
      })
      local path = config.get_storage_path()
      assert.equals("/tmp/my-data.db", path)
    end)

    it("rewrites old json file paths to sqlite db paths", function()
      config.setup({
        directories = { "/tmp/notes" },
        db_path = "/tmp/my-data.json",
      })
      local path = config.get_storage_path()
      assert.equals("/tmp/my-data.db", path)
    end)

    it("uses first directory when db_path is nil", function()
      config.setup({
        directories = { "/tmp/notes" },
      })
      local path = config.get_storage_path()
      assert.equals("/tmp/notes/flashcards.db", path)
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

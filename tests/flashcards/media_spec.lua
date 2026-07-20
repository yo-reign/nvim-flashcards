describe("media", function()
  local media
  local utils
  local root

  local function write(relative, content)
    local path = root .. "/" .. relative
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    assert(utils.write_file(path, content or "fixture"))
    return utils.canonical_path(path)
  end

  local function options(overrides)
    return vim.tbl_deep_extend("force", {
      enabled = true,
      roots = {},
      images = {
        enabled = true,
        extensions = { "png", "jpg", "svg" },
        max_width = 50,
        max_height = 18,
      },
      audio = {
        enabled = true,
        extensions = { "mp3", "wav", "ogg" },
        player = false,
      },
    }, overrides or {})
  end

  before_each(function()
    root = os.tmpname()
    os.remove(root)
    vim.fn.mkdir(root, "p")
    package.loaded["flashcards.media"] = nil
    package.loaded["image"] = nil
    utils = require("flashcards.utils")
    media = require("flashcards.media")
  end)

  after_each(function()
    package.loaded["image"] = nil
    vim.fn.delete(root, "rf")
  end)

  it("extracts local images and audio relative to the source file", function()
    local source = write("languages/french.md", "# cards")
    local image = write("languages/assets/mouth.png")
    local audio = write("languages/assets/bonjour.mp3")
    local plan = media.extract(table.concat({
      "Say bonjour",
      "![Mouth position](assets/mouth.png)",
      "[Listen](assets/bonjour.mp3)",
    }, "\n"), source, { root }, options())

    assert.equals(3, #plan.lines)
    assert.equals("[Image: Mouth position]", plan.lines[2])
    assert.equals("[Audio: Listen] (press p to play)", plan.lines[3])
    assert.equals(image, plan.images[1].path)
    assert.equals(audio, plan.audio[1].path)
    assert.equals(2, plan.images[1].line)
    assert.equals(3, plan.audio[1].line)
  end)

  it("supports angle-bracket destinations containing spaces and Markdown titles", function()
    local source = write("cards.md", "# cards")
    local image = write("assets/cell diagram.png")
    local plan = media.extract(
      '![Cell](<assets/cell diagram.png> "diagram")',
      source,
      { root },
      options()
    )

    assert.equals(image, plan.images[1].path)
    assert.equals("[Image: Cell]", plan.lines[1])

    local audio = write("assets/cell.mp3")
    local audio_plan = media.extract(
      "[Listen](assets/cell.mp3 'pronunciation')",
      source,
      { root },
      options()
    )
    assert.equals(audio, audio_plan.audio[1].path)
  end)

  it("expands ~/ media paths while retaining root confinement", function()
    local source = write("cards.md", "# cards")
    local image = write("assets/dice.png")
    local outside = os.tmpname() .. ".png"
    assert(utils.write_file(outside, "outside"))
    local original_expand = vim.fn.expand
    vim.fn.expand = function(path)
      if path == "~/notes/assets/dice.png" then return image end
      if path == "~/outside/dice.png" then return outside end
      return original_expand(path)
    end
    local plan = media.extract(
      "![Dice](~/notes/assets/dice.png)",
      source,
      { root },
      options()
    )
    local escaped = media.extract(
      "![Dice](~/outside/dice.png)",
      source,
      { root },
      options()
    )
    vim.fn.expand = original_expand
    os.remove(outside)

    assert.equals(image, plan.images[1].path)
    assert.equals("[Image: Dice]", plan.lines[1])
    assert.is_nil(escaped.images[1].path)
    assert.truthy(escaped.images[1].error:find("outside", 1, true))
  end)

  it("rejects absolute media paths even when they are inside an allowed root", function()
    local source = write("cards.md", "# cards")
    local image = write("assets/cell.png")
    local plan = media.extract("![Cell](" .. image .. ")", source, { root }, options())

    assert.is_nil(plan.images[1].path)
    assert.truthy(plan.images[1].error:find("relative", 1, true))
  end)

  it("leaves media-looking Markdown inside code fences untouched", function()
    local source = write("cards.md", "# cards")
    local content = table.concat({
      "```markdown",
      "![Example](assets/example.png)",
      "[Example](assets/example.mp3)",
      "```",
    }, "\n")
    local plan = media.extract(content, source, { root }, options())

    assert.same(utils.lines(content), plan.lines)
    assert.equals(0, #plan.items)
  end)

  it("rejects remote, missing, and outside-root media", function()
    local source = write("cards.md", "# cards")
    local outside = os.tmpname() .. ".png"
    assert(utils.write_file(outside, "outside"))

    local remote = media.extract("![Remote](https://example.com/x.png)", source, { root }, options())
    local missing = media.extract("[Missing](assets/no.mp3)", source, { root }, options())
    local escaped_target = "../" .. vim.fn.fnamemodify(outside, ":t")
    local escaped = media.extract("![Outside](" .. escaped_target .. ")", source, { root }, options())
    os.remove(outside)

    assert.is_nil(remote.images[1].path)
    assert.truthy(remote.images[1].error:find("remote", 1, true))
    assert.is_nil(missing.audio[1].path)
    assert.truthy(missing.audio[1].error:find("missing", 1, true))
    assert.is_nil(escaped.images[1].path)
    assert.truthy(escaped.images[1].error:find("outside", 1, true))
  end)

  it("rejects a symlink that escapes configured roots", function()
    local uv = vim.uv or vim.loop
    if not uv.fs_symlink then return end
    local source = write("cards.md", "# cards")
    local outside = os.tmpname() .. ".png"
    assert(utils.write_file(outside, "outside"))
    local link = root .. "/linked.png"
    local linked, link_error = uv.fs_symlink(outside, link)
    if not linked then
      os.remove(outside)
      pending("cannot create symlink: " .. tostring(link_error))
      return
    end

    local plan = media.extract("![Linked](linked.png)", source, { root }, options())
    os.remove(link)
    os.remove(outside)

    assert.is_nil(plan.images[1].path)
    assert.truthy(plan.images[1].error:find("outside", 1, true))
  end)

  it("renders and clears validated images through optional image.nvim", function()
    local rendered = 0
    local cleared = 0
    local received
    local image_object = {
      render = function() rendered = rendered + 1 end,
      clear = function() cleared = cleared + 1 end,
    }
    package.loaded["image"] = {
      from_file = function(path, opts)
        received = { path = path, opts = opts }
        return image_object
      end,
    }

    local handles = media.render_images({ { path = "/tmp/image.png", row = 4 } }, {
      window = 8,
      buffer = 9,
    }, options().images)
    media.clear_images(handles)
    media.clear_images(handles)

    assert.equals(1, #handles)
    assert.equals(1, rendered)
    assert.equals(2, cleared)
    assert.equals("/tmp/image.png", received.path)
    assert.equals(8, received.opts.window)
    assert.equals(9, received.opts.buffer)
    assert.equals(4, received.opts.y)
    assert.is_true(received.opts.with_virtual_padding)
  end)

  it("passes odd audio filenames as one argv element and stops playback", function()
    local original_executable = vim.fn.executable
    local original_jobstart = vim.fn.jobstart
    local original_jobstop = vim.fn.jobstop
    local started
    local stopped
    vim.fn.executable = function(command) return command == "fake-player" and 1 or 0 end
    vim.fn.jobstart = function(argv, job_options)
      started = { argv = argv, options = job_options }
      return 42
    end
    vim.fn.jobstop = function(job_id)
      stopped = job_id
      return 1
    end

    local path = root .. "/odd $; name.mp3"
    local job, err = media.play_audio({ path = path }, {
      player = { "fake-player", "--quiet", "--" },
    })
    media.stop_audio(job)

    vim.fn.executable = original_executable
    vim.fn.jobstart = original_jobstart
    vim.fn.jobstop = original_jobstop

    assert.is_nil(err)
    assert.equals(42, job)
    assert.same({ "fake-player", "--quiet", "--", path }, started.argv)
    assert.is_false(started.options.detach)
    assert.equals(42, stopped)
  end)

  it("opens only validated media through vim.ui.open", function()
    local original_open = vim.ui.open
    local opened
    vim.ui.open = function(path)
      opened = path
      return {}, nil
    end

    local ok, err = media.open_external({ path = "/tmp/local image.png" })
    local invalid, invalid_err = media.open_external({ error = "missing" })
    vim.ui.open = original_open

    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals("/tmp/local image.png", opened)
    assert.is_false(invalid)
    assert.equals("missing", invalid_err)
  end)
end)

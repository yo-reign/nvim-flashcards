describe("review UI", function()
  local review
  local original_notify
  local original_schedule_wrap
  local original_schedule
  local uv
  local original_new_timer
  local timers
  local media_mock
  local popup_instance

  local function module_state()
    for index = 1, 20 do
      local name, value = debug.getupvalue(review.answer, index)
      if not name then break end
      if name == "state" then return value end
    end
    error("review module state upvalue not found")
  end

  before_each(function()
    package.loaded["flashcards.ui.review"] = nil
    popup_instance = nil
    package.loaded["nui.popup"] = function() return popup_instance or {} end
    media_mock = {
      extract = function(content)
        return { lines = require("flashcards.utils").lines(content), images = {}, audio = {}, items = {} }
      end,
      render_images = function() return {} end,
      clear_images = function() end,
      play_audio = function() return nil, "unavailable" end,
      stop_audio = function() end,
      open_external = function() return false, "unavailable" end,
    }
    package.loaded["flashcards.media"] = media_mock
    package.loaded["flashcards.ui.components"] = {
      format_duration = function() return "0s" end,
      percentage = function(value) return string.format("%.0f%%", value * 100) end,
    }
    require("flashcards.config").setup({ directories = { "/tmp/notes" } })
    original_notify = vim.notify
    original_schedule_wrap = vim.schedule_wrap
    original_schedule = vim.schedule
    vim.schedule_wrap = function(callback) return callback end
    uv = vim.uv or vim.loop
    original_new_timer = uv.new_timer
    timers = {}
    uv.new_timer = function()
      local timer = { stopped = false, closed = false }
      function timer:start(delay, repeat_interval, callback)
        self.delay = delay
        self.repeat_interval = repeat_interval
        self.callback = callback
      end
      function timer:stop() self.stopped = true end
      function timer:is_closing() return self.closed end
      function timer:close() self.closed = true end
      timers[#timers + 1] = timer
      return timer
    end
    review = require("flashcards.ui.review")
  end)

  after_each(function()
    vim.notify = original_notify
    vim.schedule_wrap = original_schedule_wrap
    vim.schedule = original_schedule
    uv.new_timer = original_new_timer
    package.loaded["flashcards.ui.review"] = nil
    package.loaded["flashcards.media"] = nil
    package.loaded["flashcards.ui.components"] = nil
    package.loaded["nui.popup"] = nil
  end)

  it("explains future learning steps", function()
    local message = review.deferred_step_message({
      deferred = true,
      state = { status = "learning" },
      intervals = { formatted = "10m" },
    })

    assert.equals(
      "Next Learning step is due in 10m; this session will resume automatically.",
      message
    )
  end)

  it("notifies and advances after an answer schedules a future step", function()
    local notified
    local answered = false
    local advanced = false
    vim.notify = function(message, level)
      notified = { message = message, level = level }
    end

    local state = module_state()
    state.completed = false
    state.showing_answer = true
    state.card_shown_at = nil
    state.popup = nil
    state.session = {
      answer = function(_, rating, elapsed_ms)
        answered = rating == 1 and elapsed_ms == 0
        return {
          deferred = true,
          state = { status = "relearning" },
          intervals = { formatted = "1m" },
        }
      end,
      next_card = function()
        advanced = true
        return false
      end,
      has_pending_repeats = function() return false end,
    }

    review.answer(1)

    assert.is_true(answered)
    assert.is_true(advanced)
    assert.equals(
      "Next Relearning step is due in 1m; this session will resume automatically.",
      notified.message
    )
    assert.equals(vim.log.levels.INFO, notified.level)
  end)

  it("does not inspect answer-side media before reveal", function()
    local calls = {}
    media_mock.extract = function(content)
      calls[#calls + 1] = content
      local audio = {
        kind = "audio",
        label = content,
        path = "/tmp/" .. content .. ".mp3",
        line = 1,
      }
      return { lines = { content }, images = {}, audio = { audio }, items = { audio } }
    end

    local card = {
      id = "media1",
      front = "question-audio",
      back = "answer-audio",
      file_path = "/tmp/notes/cards.md",
      tags = {},
      reversible = false,
    }
    local state = module_state()
    state.completed = false
    state.waiting_for_repeat = false
    state.showing_answer = false
    state.popup = { bufnr = vim.api.nvim_get_current_buf() }
    state.session = {
      queue = { card },
      current_idx = 1,
      start_time = require("flashcards.utils").now(),
      store = { get_card_state = function() return { status = "new" } end },
      skip = function() end,
      current_card = function() return card, false end,
      preview_intervals = function()
        return {
          [0] = { days = 1 / 1440, formatted = "1m" },
          [1] = { days = 10 / 1440, formatted = "10m" },
        }
      end,
    }

    review.skip()
    assert.same({ "question-audio" }, calls)
    assert.equals("question-audio", state.current_audio.label)

    review.show_answer()
    assert.same({ "question-audio", "question-audio", "answer-audio" }, calls)
    assert.equals("answer-audio", state.current_audio.label)
  end)

  it("applies reversible orientation before selecting visible media", function()
    local calls = {}
    media_mock.extract = function(content)
      calls[#calls + 1] = content
      return { lines = { content }, images = {}, audio = {}, items = {} }
    end
    local card = {
      id = "reverse-media",
      front = "original-front",
      back = "original-back",
      file_path = "/tmp/notes/cards.md",
      tags = {},
      reversible = true,
    }
    local state = module_state()
    state.completed = false
    state.waiting_for_repeat = false
    state.showing_answer = false
    state.popup = { bufnr = vim.api.nvim_get_current_buf() }
    state.session = {
      queue = { card },
      current_idx = 1,
      start_time = require("flashcards.utils").now(),
      store = { get_card_state = function() return { status = "new" } end },
      skip = function() end,
      current_card = function() return card, true end,
      preview_intervals = function()
        return {
          [0] = { days = 1 / 1440, formatted = "1m" },
          [1] = { days = 10 / 1440, formatted = "10m" },
        }
      end,
    }

    review.skip()
    assert.same({ "original-back" }, calls)
    review.show_answer()
    assert.same({ "original-back", "original-back", "original-front" }, calls)
  end)

  it("clears existing image handles when revealing the answer", function()
    local old_image = {}
    local cleared = false
    media_mock.clear_images = function(handles)
      if handles[1] == old_image then cleared = true end
    end
    local card = {
      id = "clear-image",
      front = "question",
      back = "answer",
      file_path = "/tmp/notes/cards.md",
      tags = {},
    }
    local state = module_state()
    state.completed = false
    state.waiting_for_repeat = false
    state.showing_answer = false
    state.image_handles = { old_image }
    state.popup = { bufnr = vim.api.nvim_get_current_buf() }
    state.session = {
      queue = { card },
      current_idx = 1,
      start_time = require("flashcards.utils").now(),
      store = { get_card_state = function() return { status = "new" } end },
      current_card = function() return card, false end,
      preview_intervals = function()
        return {
          [0] = { days = 1 / 1440, formatted = "1m" },
          [1] = { days = 10 / 1440, formatted = "10m" },
        }
      end,
    }

    review.show_answer()
    assert.is_true(cleared)
  end)

  it("replaces audio playback and stops it when the review closes", function()
    local next_job = 40
    local stopped = {}
    local exits = {}
    media_mock.play_audio = function(_, _, on_exit)
      next_job = next_job + 1
      exits[next_job] = on_exit
      return next_job
    end
    media_mock.stop_audio = function(job_id)
      if job_id then stopped[#stopped + 1] = job_id end
    end

    local state = module_state()
    state.completed = false
    state.waiting_for_repeat = false
    state.current_audio = { path = "/tmp/sound.mp3" }
    state.session = {
      clear_pending_repeats = function() end,
      summary = function() return { reviewed = 0 } end,
    }

    review.play_audio()
    review.play_audio()
    exits[41](41, 1)
    assert.equals(42, state.audio_job)
    review.close()
    exits[42](42, 1)

    assert.same({ 41, 42 }, stopped)
    assert.is_false(review.is_active())
  end)

  it("removes review lifecycle autocmds on every close", function()
    local card = {
      id = "lifecycle",
      front = "question",
      back = "answer",
      file_path = "/tmp/notes/cards.md",
      tags = {},
      state = { status = "new" },
    }
    local store = {
      get_due_cards = function() return { card }, {} end,
      get_card_state = function() return { status = "new" } end,
    }

    for iteration = 1, 2 do
      popup_instance = {
        bufnr = vim.api.nvim_get_current_buf(),
        winid = vim.api.nvim_get_current_win(),
        mount = function() end,
        unmount = function() end,
      }
      review.start(store)
      local autocmds = vim.api.nvim_get_autocmds({ group = "FlashcardsReviewMedia" })
      assert.equals(2, #autocmds)
      if iteration == 1 then
        review.close()
      else
        vim.api.nvim_exec_autocmds("WinClosed", { pattern = tostring(popup_instance.winid) })
        assert.is_false(review.is_active())
      end
      local group_exists = pcall(vim.api.nvim_get_autocmds, { group = "FlashcardsReviewMedia" })
      assert.is_false(group_exists)
    end
  end)

  it("keeps the fallback caption above a stable padded image anchor", function()
    vim.schedule = function(callback) callback() end
    local image = { kind = "image", label = "diagram", path = "/tmp/diagram.png", line = 1 }
    media_mock.extract = function()
      return { lines = { "[Image: diagram]" }, images = { image }, audio = {}, items = { image } }
    end

    local rendered_context
    local extmark
    local namespace = vim.api.nvim_create_namespace("FlashcardsImageLayoutTest")
    media_mock.render_images = function(images, context, options)
      rendered_context = { images = images, context = context, options = options }
      local render_row = images[1].render_row
      local anchor = vim.api.nvim_buf_get_lines(context.buffer, render_row, render_row + 1, false)[1]
      assert.is_true(vim.fn.strdisplaywidth(anchor) >= context.width)
      local x = math.floor(context.width / 2)
      extmark = vim.api.nvim_buf_set_extmark(context.buffer, namespace, render_row, x, {})
      return { { clear = function() end } }
    end

    local card = {
      id = "image-layout",
      front = "image",
      back = "answer",
      file_path = "/tmp/notes/cards.md",
      tags = {},
    }
    local state = module_state()
    state.completed = false
    state.waiting_for_repeat = false
    state.showing_answer = false
    state.popup = {
      bufnr = vim.api.nvim_get_current_buf(),
      winid = vim.api.nvim_get_current_win(),
    }
    state.session = {
      queue = { card },
      current_idx = 1,
      start_time = require("flashcards.utils").now(),
      store = { get_card_state = function() return { status = "new" } end },
      skip = function() end,
      current_card = function() return card, false end,
      preview_intervals = function() return {} end,
    }

    review.skip()

    assert.equals(vim.api.nvim_win_get_width(state.popup.winid), rendered_context.context.width)
    assert.equals("center", rendered_context.options.alignment)
    local visible = state.visible_images[1]
    assert.equals(visible.row + 1, visible.render_row)
    local caption = vim.api.nvim_buf_get_lines(state.popup.bufnr, visible.row, visible.row + 1, false)[1]
    assert.equals("  [Image: diagram]", caption)
    local mark = vim.api.nvim_buf_get_extmark_by_id(state.popup.bufnr, namespace, extmark, {})
    assert.same({ visible.render_row, math.floor(rendered_context.context.width / 2) }, mark)
  end)

  it("allocates independent caption and render rows for multiple images", function()
    vim.schedule = function(callback) callback() end
    local first = { kind = "image", label = "one", path = "/tmp/one.png", line = 1 }
    local second = { kind = "image", label = "two", path = "/tmp/two.png", line = 2 }
    media_mock.extract = function()
      return {
        lines = { "[Image: one]", "[Image: two]" },
        images = { first, second },
        audio = {},
        items = { first, second },
      }
    end
    local rendered
    media_mock.render_images = function(images)
      rendered = images
      return {}
    end

    local card = {
      id = "multiple-image-layout",
      front = "images",
      back = "answer",
      file_path = "/tmp/notes/cards.md",
      tags = {},
    }
    local state = module_state()
    state.completed = false
    state.waiting_for_repeat = false
    state.showing_answer = false
    state.popup = {
      bufnr = vim.api.nvim_get_current_buf(),
      winid = vim.api.nvim_get_current_win(),
    }
    state.session = {
      queue = { card },
      current_idx = 1,
      start_time = require("flashcards.utils").now(),
      store = { get_card_state = function() return { status = "new" } end },
      skip = function() end,
      current_card = function() return card, false end,
      preview_intervals = function() return {} end,
    }

    review.skip()

    assert.equals(2, #rendered)
    assert.equals(rendered[1].row + 1, rendered[1].render_row)
    assert.equals(rendered[1].render_row + 1, rendered[2].row)
    assert.equals(rendered[2].row + 1, rendered[2].render_row)
  end)

  it("rejects stale scheduled image rendering after close", function()
    local callbacks = {}
    local rendered = 0
    vim.schedule = function(callback) callbacks[#callbacks + 1] = callback end
    local image = { kind = "image", label = "diagram", path = "/tmp/diagram.png", line = 1 }
    media_mock.extract = function()
      return { lines = { "[Image: diagram]" }, images = { image }, audio = {}, items = { image } }
    end
    media_mock.render_images = function()
      rendered = rendered + 1
      return {}
    end

    local card = {
      id = "image1",
      front = "image",
      back = "answer",
      file_path = "/tmp/notes/cards.md",
      tags = {},
    }
    local state = module_state()
    state.completed = false
    state.waiting_for_repeat = false
    state.showing_answer = false
    state.popup = {
      bufnr = vim.api.nvim_get_current_buf(),
      winid = vim.api.nvim_get_current_win(),
      unmount = function() end,
    }
    state.session = {
      queue = { card },
      current_idx = 1,
      start_time = require("flashcards.utils").now(),
      store = { get_card_state = function() return { status = "new" } end },
      skip = function() end,
      current_card = function() return card, false end,
      clear_pending_repeats = function() end,
      summary = function() return { reviewed = 0 } end,
    }

    review.skip()
    assert.is_true(#callbacks >= 1)
    review.close()
    for _, callback in ipairs(callbacks) do callback() end
    assert.equals(0, rendered)
  end)

  it("waits with a one-shot timer and automatically resumes the same popup", function()
    vim.notify = function() end
    local now = require("flashcards.utils").now()
    local card = { id = "card1", front = "Q", back = "A", tags = {}, reversible = false }
    local pending = true
    local next_calls = 0
    local releases = 0
    local state = module_state()
    state.completed = false
    state.waiting_for_repeat = false
    state.showing_answer = true
    state.card_shown_at = nil
    state.popup = { bufnr = vim.api.nvim_get_current_buf() }
    state.session = {
      queue = { card },
      current_idx = 1,
      start_time = now,
      store = { get_card_state = function() return { status = "learning" } end },
      answer = function()
        return {
          deferred = true,
          state = { status = "learning" },
          intervals = { formatted = "1m" },
        }
      end,
      next_card = function(self)
        next_calls = next_calls + 1
        if next_calls == 1 then
          self.current_idx = #self.queue + 1
          return false
        end
        self.current_idx = 2
        return true
      end,
      has_pending_repeats = function() return pending end,
      next_pending_due = function() return pending and (now + 60) or nil end,
      release_due_repeats = function(self)
        releases = releases + 1
        pending = false
        self.queue[2] = card
        return { { card_id = card.id } }
      end,
      current_card = function(self) return self.queue[self.current_idx], false end,
    }

    review.answer(0)

    assert.is_true(state.waiting_for_repeat)
    assert.is_false(state.completed)
    assert.equals(1, #timers)
    assert.equals(0, timers[1].repeat_interval)
    assert.is_true(timers[1].delay > 0 and timers[1].delay <= 60000)

    timers[1].callback()

    assert.equals(1, releases)
    assert.equals(2, next_calls)
    assert.is_false(state.waiting_for_repeat)
    assert.equals("card1", state.session:current_card().id)
    assert.is_true(timers[1].closed)
  end)

  it("cancels waiting and restores the last card on undo", function()
    local now = require("flashcards.utils").now()
    local card = { id = "card1", front = "Q", back = "A", tags = {}, reversible = false }
    local pending = true
    local state = module_state()
    state.completed = false
    state.waiting_for_repeat = true
    state.showing_answer = false
    state.card_shown_at = nil
    state.popup = { bufnr = vim.api.nvim_get_current_buf() }
    state.repeat_timer = uv.new_timer()
    local timer = state.repeat_timer
    state.session = {
      queue = { card },
      current_idx = 2,
      start_time = now,
      store = { get_card_state = function() return { status = "new" } end },
      undo = function(self)
        pending = false
        self.current_idx = 1
        return true
      end,
      next_pending_due = function() return pending and (now + 60) or nil end,
      current_card = function(self) return self.queue[self.current_idx], false end,
      preview_intervals = function()
        return {
          [0] = { days = 1 / 1440, formatted = "1m" },
          [1] = { days = 10 / 1440, formatted = "10m" },
        }
      end,
    }

    review.undo()

    assert.is_true(timer.stopped)
    assert.is_true(timer.closed)
    assert.is_false(state.waiting_for_repeat)
    assert.is_true(state.showing_answer)
    assert.equals("card1", state.session:current_card().id)
  end)

  it("cancels the timer and pending state on close", function()
    vim.notify = function() end
    local now = require("flashcards.utils").now()
    local cleared = false
    local released = false
    local unmounted = false
    local state = module_state()
    state.completed = false
    state.waiting_for_repeat = false
    state.showing_answer = true
    state.card_shown_at = nil
    state.popup = {
      bufnr = vim.api.nvim_get_current_buf(),
      unmount = function() unmounted = true end,
    }
    state.session = {
      queue = { { id = "card1" } },
      current_idx = 1,
      store = { save = function() end },
      answer = function()
        return {
          deferred = true,
          state = { status = "learning" },
          intervals = { formatted = "1m" },
        }
      end,
      next_card = function(self)
        self.current_idx = 2
        return false
      end,
      has_pending_repeats = function() return true end,
      next_pending_due = function() return now + 60 end,
      release_due_repeats = function()
        released = true
        return { {} }
      end,
      clear_pending_repeats = function() cleared = true end,
      summary = function()
        return { reviewed = 1, elapsed_formatted = "0m 1s", answer_accuracy = 1 }
      end,
    }

    review.answer(0)
    local callback = timers[1].callback
    review.close()

    assert.is_true(cleared)
    assert.is_true(unmounted)
    assert.is_true(timers[1].stopped)
    assert.is_true(timers[1].closed)
    assert.is_false(review.is_active())
    callback()
    assert.is_false(released)
  end)

  it("does not produce messages for ordinary or malformed results", function()
    assert.is_nil(review.deferred_step_message({
      deferred = false,
      state = { status = "review" },
      intervals = { formatted = "5d" },
    }))
    assert.is_nil(review.deferred_step_message({ deferred = true }))
  end)
end)

describe("review UI", function()
  local review
  local original_notify
  local original_schedule_wrap
  local uv
  local original_new_timer
  local timers

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
    package.loaded["nui.popup"] = function() return {} end
    package.loaded["flashcards.ui.components"] = {
      format_duration = function() return "0s" end,
      percentage = function(value) return string.format("%.0f%%", value * 100) end,
    }
    require("flashcards.config").setup({ directories = { "/tmp/notes" } })
    original_notify = vim.notify
    original_schedule_wrap = vim.schedule_wrap
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
    uv.new_timer = original_new_timer
    package.loaded["flashcards.ui.review"] = nil
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

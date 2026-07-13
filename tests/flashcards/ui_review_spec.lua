describe("review UI", function()
  local review
  local original_notify

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
    package.loaded["flashcards.ui.components"] = {}
    original_notify = vim.notify
    review = require("flashcards.ui.review")
  end)

  after_each(function()
    vim.notify = original_notify
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
      "Next Learning step is due in 10m; start review again after it is due.",
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
    }

    review.answer(1)

    assert.is_true(answered)
    assert.is_true(advanced)
    assert.equals(
      "Next Relearning step is due in 1m; start review again after it is due.",
      notified.message
    )
    assert.equals(vim.log.levels.INFO, notified.level)
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

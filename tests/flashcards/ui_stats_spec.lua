describe("stats UI", function()
  local config
  local stats_ui

  before_each(function()
    package.loaded["flashcards.config"] = nil
    package.loaded["flashcards.ui.stats"] = nil
    package.loaded["nui.popup"] = function() return {} end
    package.loaded["nui.utils.autocmd"] = { event = {} }
    config = require("flashcards.config")
    config.setup({
      directories = { "/tmp/notes" },
      session = { new_cards_per_day = 3 },
    })
    stats_ui = require("flashcards.ui.stats")
  end)

  after_each(function()
    package.loaded["flashcards.ui.stats"] = nil
    package.loaded["flashcards.config"] = nil
    package.loaded["nui.popup"] = nil
    package.loaded["nui.utils.autocmd"] = nil
  end)

  it("renders cap-aware availability, relearning, and answer accuracy", function()
    local seen = {}
    local store = {}
    function store:get_stats(limit)
      seen.stats_limit = limit
      return {
        total_cards = 10,
        by_state = { new = 4, learning = 2, review = 3, relearning = 1 },
        due = { total = 6, new = 2, learning = 1, relearning = 1, review = 2, deferred_new = 2 },
        total_reviews = 8,
        answer_accuracy = 0.75,
        streak = 2,
        avg_time_ms = 1500,
      }
    end
    function store:get_all_tags(limit)
      seen.tags_limit = limit
      return {}
    end
    function store:get_daily_stats()
      return {}
    end

    local rendered = table.concat(stats_ui.render_stats(store), "\n")
    assert.equals(3, seen.stats_limit)
    assert.equals(3, seen.tags_limit)
    assert.truthy(rendered:find("# Available Now", 1, true))
    assert.truthy(rendered:find("Relearning: 1", 1, true))
    assert.truthy(rendered:find("New deferred by daily limit: 2", 1, true))
    assert.truthy(rendered:find("Total Answers: 8", 1, true))
    assert.truthy(rendered:find("Answer Accuracy: 75.0%", 1, true))
    assert.is_nil(rendered:find("Retention Rate", 1, true))
  end)

  it("uses cap-aware availability in the statusline", function()
    local seen_limit
    local store = {
      count_due = function(_, limit)
        seen_limit = limit
        return { total = 6 }
      end,
    }

    assert.equals(" 6", stats_ui.statusline(store))
    assert.equals(3, seen_limit)
  end)
end)

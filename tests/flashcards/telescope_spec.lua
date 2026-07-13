describe("Telescope review integration", function()
  local config
  local telescope_flashcards
  local selected_entry
  local select_callback

  local module_names = {
    "flashcards.telescope",
    "flashcards.config",
    "flashcards.ui.review",
    "telescope",
    "telescope.pickers",
    "telescope.finders",
    "telescope.config",
    "telescope.actions",
    "telescope.actions.state",
    "telescope.previewers",
  }

  before_each(function()
    for _, name in ipairs(module_names) do package.loaded[name] = nil end

    selected_entry = nil
    select_callback = nil

    package.loaded["telescope"] = {
      register_extension = function(spec) return spec end,
    }
    package.loaded["telescope.finders"] = {
      new_table = function(spec) return spec end,
    }
    package.loaded["telescope.config"] = {
      values = { generic_sorter = function() return {} end },
    }
    package.loaded["telescope.previewers"] = {
      new_buffer_previewer = function(spec) return spec end,
    }
    package.loaded["telescope.actions"] = {
      close = function() end,
      select_default = {
        replace = function(_, callback)
          select_callback = callback
        end,
      },
    }
    package.loaded["telescope.actions.state"] = {
      get_selected_entry = function() return selected_entry end,
    }
    package.loaded["telescope.pickers"] = {
      new = function(_, spec)
        return {
          find = function()
            if spec.attach_mappings then
              spec.attach_mappings(11, function() end)
            end
          end,
        }
      end,
    }

    config = require("flashcards.config")
    config.setup({
      directories = { "/tmp/notes" },
      session = { new_cards_per_day = 4 },
    })
    telescope_flashcards = require("flashcards.telescope")
  end)

  after_each(function()
    for _, name in ipairs(module_names) do package.loaded[name] = nil end
  end)

  it("shows only available cards and prioritizes the selected Due card", function()
    local passed_cap
    local started
    local card = {
      id = "selected1",
      file_path = "/tmp/notes/cards.md",
      line = 1,
      front = "Question",
      back = "Answer",
      tags = {},
      state = { status = "new" },
    }
    local store = {}
    function store:get_due_cards(tag, cap)
      assert.is_nil(tag)
      passed_cap = cap
      return { card }, { deferred_new = 2 }
    end
    function store:get_card_state()
      return { status = "new" }
    end

    package.loaded["flashcards.ui.review"] = {
      start = function(start_store, tag, opts)
        started = { store = start_store, tag = tag, opts = opts }
      end,
    }

    selected_entry = { value = card }
    telescope_flashcards.due(store)
    assert.equals(4, passed_cap)
    assert.is_function(select_callback)
    select_callback()

    assert.equals(store, started.store)
    assert.is_nil(started.tag)
    assert.equals("selected1", started.opts.priority_card_id)
  end)

  it("uses the configured policy for tag availability", function()
    local passed_cap
    local store = {
      get_all_tags = function(_, cap)
        passed_cap = cap
        return { { tag = "math", count = 3, due_count = 2 } }
      end,
    }

    telescope_flashcards.tags(store)
    assert.equals(4, passed_cap)
  end)
end)

-- Tests for the scheduler (session manager)
-- Run with: nvim --headless -c "PlenaryBustedFile tests/flashcards/scheduler_spec.lua" -c "qa"

describe("scheduler", function()
  local scheduler
  local utils

  -- Standalone deep_copy (defined before mock_utils so it can be referenced)
  local function deep_copy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
      copy[k] = type(v) == "table" and deep_copy(v) or v
    end
    return copy
  end

  -- Mock utils (same as fsrs_spec pattern)
  local mock_utils = {
    now = function() return 1700000000 end,
    days_between = function(from, to) return math.abs(to - from) / 86400 end,
    add_days = function(ts, days) return ts + math.floor(days * 86400) end,
    format_interval = function(days)
      if days < 1 / 24 then
        return math.floor(days * 24 * 60 + 0.5) .. "m"
      elseif days < 1 then
        return math.floor(days * 24 + 0.5) .. "h"
      else
        return math.floor(days + 0.5) .. "d"
      end
    end,
    deep_copy = deep_copy,
    generate_id = function()
      return "test1234"
    end,
  }

  -- ========================================================================
  -- Mock Store
  -- ========================================================================

  local function make_mock_store(cards, states)
    cards = cards or {}
    states = states or {}

    local reviews_log = {}

    local store = {
      _cards = cards,
      _states = states,
      _reviews = reviews_log,
    }

    function store:get_due_cards(tag)
      local now = mock_utils.now()
      local result = {}
      for _, card in ipairs(self._cards) do
        if not card.suspended then
          local state = self._states[card.id]
          local is_due = (not state)
            or state.status == "new"
            or (state.due_date and state.due_date <= now)
          if is_due then
            if not tag or self:_matches_tag(card, tag) then
              local c = deep_copy(card)
              c.state = deep_copy(state or { status = "new" })
              table.insert(result, c)
            end
          end
        end
      end
      return result
    end

    function store:_matches_tag(card, query_tag)
      local prefix = query_tag .. "/"
      for _, t in ipairs(card.tags or {}) do
        if t == query_tag or t:sub(1, #prefix) == prefix then
          return true
        end
      end
      return false
    end

    function store:get_card_state(id)
      local state = self._states[id]
      if state then
        return deep_copy(state)
      end
      return { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
               learning_step = 0, elapsed_days = 0, scheduled_days = 0 }
    end

    function store:update_card_state(id, new_state)
      self._states[id] = deep_copy(new_state)
    end

    function store:add_review(review)
      table.insert(self._reviews, deep_copy(review))
    end

    function store:get_card(id)
      for _, card in ipairs(self._cards) do
        if card.id == id then
          return deep_copy(card)
        end
      end
      return nil
    end

    return store
  end

  -- ========================================================================
  -- Mock FSRS
  -- ========================================================================

  local function make_mock_fsrs(opts)
    opts = opts or {}
    local fsrs = {}

    -- Default schedule: correct -> review with 5d interval, wrong -> learning with 1m interval
    function fsrs:schedule(card_state, rating, now)
      now = now or mock_utils.now()
      local state = card_state.state or card_state.status or "new"
      local new_state = deep_copy(card_state)

      if rating == 2 then -- Correct
        if state == "new" or state == "learning" or state == "relearning" then
          new_state.status = "review"
          new_state.state = "review"
          new_state.stability = 10
          new_state.difficulty = 5
          new_state.reps = (card_state.reps or 0) + 1
        else
          new_state.status = "review"
          new_state.state = "review"
          new_state.stability = (card_state.stability or 10) * 2
          new_state.difficulty = math.max(1, (card_state.difficulty or 5) - 0.3)
          new_state.reps = (card_state.reps or 0) + 1
        end
        local days = 5
        new_state.scheduled_days = days
        new_state.due_date = mock_utils.add_days(now, days)
        new_state.last_review = now
        return new_state, { days = days, formatted = "5d" }
      else -- Wrong
        if state == "review" then
          new_state.status = "relearning"
          new_state.state = "relearning"
        else
          new_state.status = "learning"
          new_state.state = "learning"
        end
        new_state.stability = 0.5
        new_state.difficulty = math.min(10, (card_state.difficulty or 5) + 0.5)
        new_state.reps = (card_state.reps or 0) + 1
        new_state.lapses = (card_state.lapses or 0) + 1
        new_state.learning_step = 0
        local days = 1 / (24 * 60) -- 1 minute in days
        new_state.scheduled_days = days
        new_state.due_date = mock_utils.add_days(now, days)
        new_state.last_review = now
        return new_state, { days = days, formatted = "1m" }
      end
    end

    function fsrs:preview_intervals(card_state, now)
      local previews = {}
      for rating = 1, 2 do
        local _, intervals = self:schedule(card_state, rating, now)
        previews[rating] = intervals
      end
      return previews
    end

    return fsrs
  end

  -- ========================================================================
  -- Setup / Teardown
  -- ========================================================================

  before_each(function()
    package.loaded["flashcards.utils"] = mock_utils
    package.loaded["flashcards.scheduler"] = nil
    scheduler = require("flashcards.scheduler")
    utils = mock_utils
  end)

  after_each(function()
    package.loaded["flashcards.utils"] = nil
    package.loaded["flashcards.scheduler"] = nil
  end)

  -- ========================================================================
  -- Helper to create standard test cards
  -- ========================================================================

  local function make_test_cards()
    -- 2 new, 2 review (due), 2 learning (due)
    local now = utils.now()
    local cards = {
      { id = "new1", front = "New Q1", back = "New A1", tags = { "math" }, reversible = false },
      { id = "new2", front = "New Q2", back = "New A2", tags = { "math" }, reversible = false },
      { id = "rev1", front = "Rev Q1", back = "Rev A1", tags = { "math" }, reversible = false },
      { id = "rev2", front = "Rev Q2", back = "Rev A2", tags = { "python" }, reversible = false },
      { id = "lrn1", front = "Lrn Q1", back = "Lrn A1", tags = { "math" }, reversible = false },
      { id = "lrn2", front = "Lrn Q2", back = "Lrn A2", tags = { "python" }, reversible = false },
    }
    local states = {
      new1 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
      new2 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
      rev1 = { status = "review", stability = 5, difficulty = 5, reps = 3, lapses = 0,
                due_date = now - 3600, last_review = now - 86400 * 5,
                learning_step = 0, elapsed_days = 5, scheduled_days = 5 },
      rev2 = { status = "review", stability = 10, difficulty = 4, reps = 5, lapses = 0,
                due_date = now - 1800, last_review = now - 86400 * 10,
                learning_step = 0, elapsed_days = 10, scheduled_days = 10 },
      lrn1 = { status = "learning", stability = 0.5, difficulty = 5, reps = 1, lapses = 0,
                due_date = now - 120, last_review = now - 600,
                learning_step = 1, elapsed_days = 0, scheduled_days = 0.007 },
      lrn2 = { status = "relearning", stability = 1, difficulty = 6, reps = 4, lapses = 1,
                due_date = now - 60, last_review = now - 300,
                learning_step = 0, elapsed_days = 0, scheduled_days = 0.001 },
    }
    return cards, states
  end

  -- ========================================================================
  -- Test: Queue Ordering
  -- ========================================================================

  describe("queue ordering", function()
    it("places learning/relearning first, then interleaved new/review", function()
      local cards, states = make_test_cards()
      local store = make_mock_store(cards, states)
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs, { new_cards_per_day = 20 })
      session:load_cards()

      -- Learning cards should come first (sorted by due_date)
      -- lrn1 due_date = now - 120 (earlier), lrn2 due_date = now - 60 (later)
      local queue = session.queue
      assert.is_true(#queue >= 6, "expected at least 6 cards in queue, got " .. #queue)

      -- First two should be learning/relearning
      local first_status = states[queue[1].id].status
      local second_status = states[queue[2].id].status
      assert.is_true(
        first_status == "learning" or first_status == "relearning",
        "first card should be learning/relearning, got " .. first_status
      )
      assert.is_true(
        second_status == "learning" or second_status == "relearning",
        "second card should be learning/relearning, got " .. second_status
      )

      -- lrn1 has earlier due_date, so it should come first
      assert.equals("lrn1", queue[1].id)
      assert.equals("lrn2", queue[2].id)

      -- After learning cards, new and review should be interleaved
      -- Interleave pattern: review, new, review, new (or similar)
      local remaining_types = {}
      for i = 3, #queue do
        local s = states[queue[i].id].status
        table.insert(remaining_types, s)
      end
      -- Should contain both new and review cards
      local has_new, has_review = false, false
      for _, s in ipairs(remaining_types) do
        if s == "new" then has_new = true end
        if s == "review" then has_review = true end
      end
      assert.is_true(has_new, "remaining queue should contain new cards")
      assert.is_true(has_review, "remaining queue should contain review cards")
    end)
  end)

  -- ========================================================================
  -- Test: New Card Daily Limit
  -- ========================================================================

  describe("new card daily limit", function()
    it("limits new cards to new_cards_per_day", function()
      local now = utils.now()
      local cards = {}
      local states = {}
      -- Create 10 new cards
      for i = 1, 10 do
        local id = "new" .. i
        table.insert(cards, { id = id, front = "Q" .. i, back = "A" .. i, tags = {}, reversible = false })
        states[id] = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                        learning_step = 0, elapsed_days = 0, scheduled_days = 0 }
      end
      -- Add 1 review card
      table.insert(cards, { id = "rev1", front = "RevQ", back = "RevA", tags = {}, reversible = false })
      states["rev1"] = { status = "review", stability = 5, difficulty = 5, reps = 3, lapses = 0,
                          due_date = now - 100, last_review = now - 86400,
                          learning_step = 0, elapsed_days = 1, scheduled_days = 1 }

      local store = make_mock_store(cards, states)
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs, { new_cards_per_day = 3 })
      session:load_cards()

      -- Count new cards in queue
      local new_count = 0
      for _, card in ipairs(session.queue) do
        if states[card.id].status == "new" then
          new_count = new_count + 1
        end
      end

      assert.equals(3, new_count)
      -- Total should be 3 new + 1 review = 4
      assert.equals(4, #session.queue)
    end)
  end)

  -- ========================================================================
  -- Test: Answer (updates state via FSRS, records review)
  -- ========================================================================

  describe("answer", function()
    it("updates card state via FSRS and records review", function()
      local now = utils.now()
      local cards = {
        { id = "card1", front = "Q", back = "A", tags = {}, reversible = false },
      }
      local states = {
        card1 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                   learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
      }

      local store = make_mock_store(cards, states)
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs)
      session:load_cards()
      session:next_card()

      -- Answer correct
      session:answer(2)

      -- Card state should be updated in store
      local new_state = store:get_card_state("card1")
      assert.equals("review", new_state.status)
      assert.equals(10, new_state.stability)
      assert.is_true(new_state.due_date > now)

      -- Review should be recorded in store
      assert.equals(1, #store._reviews)
      assert.equals("card1", store._reviews[1].card_id)
      assert.equals(2, store._reviews[1].rating)
      assert.equals("new", store._reviews[1].state_before)
      assert.equals("review", store._reviews[1].state_after)

      -- Session reviews should also be recorded
      assert.equals(1, #session.reviews)
    end)

    it("re-queues learning cards due within 30 minutes", function()
      local now = utils.now()
      local cards = {
        { id = "card1", front = "Q", back = "A", tags = {}, reversible = false },
      }
      local states = {
        card1 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                   learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
      }

      local store = make_mock_store(cards, states)
      -- Custom FSRS that returns learning state with short interval on wrong
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs)
      session:load_cards()
      session:next_card()

      -- Answer wrong -> should go to learning with 1 minute interval
      session:answer(1)

      -- Card should be re-queued (since learning with < 30 min interval)
      local found = false
      for _, c in ipairs(session.queue) do
        if c.id == "card1" then
          found = true
          break
        end
      end
      assert.is_true(found, "learning card should be re-queued")
    end)
  end)

  -- ========================================================================
  -- Test: Undo
  -- ========================================================================

  describe("undo", function()
    it("restores previous state and reversed orientation", function()
      local now = utils.now()
      local cards = {
        { id = "card1", front = "Q", back = "A", tags = {}, reversible = true },
      }
      local states = {
        card1 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                   learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
      }

      local store = make_mock_store(cards, states)
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs)
      session:load_cards()
      session:next_card()

      -- Note the reversed state
      local _, is_reversed_before = session:current_card()

      -- Answer correct
      session:answer(2)

      -- Undo
      local ok = session:undo()
      assert.is_true(ok)

      -- State should be restored
      local restored_state = store:get_card_state("card1")
      assert.equals("new", restored_state.status)
      assert.equals(0, restored_state.stability)

      -- Session reviews should be empty
      assert.equals(0, #session.reviews)

      -- Store reviews should be empty (the add was undone)
      -- Note: we only verify session-level undo; store-level depends on implementation
      -- The current card should be accessible again
      local card, is_reversed_after = session:current_card()
      assert.is_not_nil(card)
      assert.equals("card1", card.id)
      -- Reversed orientation should be preserved
      assert.equals(is_reversed_before, is_reversed_after)
    end)

    it("returns false when no reviews to undo", function()
      local cards = {
        { id = "card1", front = "Q", back = "A", tags = {}, reversible = false },
      }
      local states = {
        card1 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                   learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
      }
      local store = make_mock_store(cards, states)
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs)
      session:load_cards()
      session:next_card()

      local ok = session:undo()
      assert.is_false(ok)
    end)
  end)

  -- ========================================================================
  -- Test: Skip
  -- ========================================================================

  describe("skip", function()
    it("moves current card to end of queue, preserves reversed_map", function()
      local now = utils.now()
      local cards = {
        { id = "card1", front = "Q1", back = "A1", tags = {}, reversible = true },
        { id = "card2", front = "Q2", back = "A2", tags = {}, reversible = false },
        { id = "card3", front = "Q3", back = "A3", tags = {}, reversible = false },
      }
      local states = {
        card1 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                   learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
        card2 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                   learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
        card3 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                   learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
      }

      local store = make_mock_store(cards, states)
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs)
      session:load_cards()
      session:next_card()

      -- Get current card (should be card1 or first in queue)
      local card1, is_reversed = session:current_card()
      local card1_id = card1.id
      local original_reversed = is_reversed

      -- Skip
      session:skip()

      -- Card should now be at end of queue
      local last_card = session.queue[#session.queue]
      assert.equals(card1_id, last_card.id)

      -- Current card should advance to next
      local current, _ = session:current_card()
      assert.is_not_nil(current)
      assert.not_equals(card1_id, current.id)

      -- Reversed map should preserve the value for the skipped card
      assert.equals(original_reversed, session.reversed_map[card1_id])
    end)
  end)

  -- ========================================================================
  -- Test: Re-queue (learning cards due within 30min)
  -- ========================================================================

  describe("re-queue logic", function()
    it("does not re-queue review cards", function()
      local now = utils.now()
      local cards = {
        { id = "rev1", front = "Q", back = "A", tags = {}, reversible = false },
      }
      local states = {
        rev1 = { status = "review", stability = 5, difficulty = 5, reps = 3, lapses = 0,
                  due_date = now - 100, last_review = now - 86400 * 5,
                  learning_step = 0, elapsed_days = 5, scheduled_days = 5 },
      }

      local store = make_mock_store(cards, states)
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs)
      session:load_cards()
      session:next_card()

      -- Answer correct -> stays review with 5d interval
      session:answer(2)

      -- Should NOT be re-queued (review state, interval > 30 min)
      local found = false
      for i = session.current_idx + 1, #session.queue do
        if session.queue[i].id == "rev1" then
          found = true
          break
        end
      end
      assert.is_false(found, "review card should not be re-queued")
    end)
  end)

  -- ========================================================================
  -- Test: Preview Intervals
  -- ========================================================================

  describe("preview intervals", function()
    it("returns both rating options", function()
      local cards = {
        { id = "card1", front = "Q", back = "A", tags = {}, reversible = false },
      }
      local states = {
        card1 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                   learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
      }

      local store = make_mock_store(cards, states)
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs)
      session:load_cards()
      session:next_card()

      local previews = session:preview_intervals()
      assert.is_not_nil(previews)
      assert.is_not_nil(previews[1], "should have Wrong preview")
      assert.is_not_nil(previews[2], "should have Correct preview")
      assert.is_not_nil(previews[1].days)
      assert.is_not_nil(previews[1].formatted)
      assert.is_not_nil(previews[2].days)
      assert.is_not_nil(previews[2].formatted)
    end)
  end)

  -- ========================================================================
  -- Test: Summary
  -- ========================================================================

  describe("summary", function()
    it("returns correct counts after reviews", function()
      local now = utils.now()
      local cards = {
        { id = "card1", front = "Q1", back = "A1", tags = {}, reversible = false },
        { id = "card2", front = "Q2", back = "A2", tags = {}, reversible = false },
        { id = "card3", front = "Q3", back = "A3", tags = {}, reversible = false },
      }
      local states = {
        card1 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                   learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
        card2 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                   learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
        card3 = { status = "review", stability = 5, difficulty = 5, reps = 3, lapses = 0,
                   due_date = now - 100, last_review = now - 86400,
                   learning_step = 0, elapsed_days = 1, scheduled_days = 1 },
      }

      local store = make_mock_store(cards, states)
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs)
      session:load_cards()

      -- Review all cards: correct, wrong, correct
      session:next_card()
      session:answer(2) -- correct

      session:next_card()
      session:answer(1) -- wrong

      session:next_card()
      session:answer(2) -- correct

      local summary = session:summary()
      assert.is_not_nil(summary)
      assert.equals(3, summary.reviewed)
      assert.equals(2, summary.correct)
      assert.equals(1, summary.wrong)
      assert.is_number(summary.elapsed)
      assert.is_string(summary.elapsed_formatted)
      assert.is_number(summary.retention_rate)
      -- retention_rate should be 2/3 ~ 0.667
      assert.is_true(summary.retention_rate > 0.6 and summary.retention_rate < 0.7)
    end)

    it("returns zeros for empty session", function()
      local store = make_mock_store({}, {})
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs)
      session:load_cards()

      local summary = session:summary()
      assert.equals(0, summary.total)
      assert.equals(0, summary.reviewed)
      assert.equals(0, summary.correct)
      assert.equals(0, summary.wrong)
      assert.equals(0, summary.retention_rate)
    end)
  end)

  -- ========================================================================
  -- Test: Tag Filtering
  -- ========================================================================

  describe("tag filtering", function()
    it("only loads cards matching tag", function()
      local now = utils.now()
      local cards = {
        { id = "math1", front = "Math Q", back = "Math A", tags = { "math" }, reversible = false },
        { id = "py1", front = "Py Q", back = "Py A", tags = { "python" }, reversible = false },
        { id = "math2", front = "Math Q2", back = "Math A2", tags = { "math/algebra" }, reversible = false },
      }
      local states = {
        math1 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                    learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
        py1 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                  learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
        math2 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                    learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
      }

      local store = make_mock_store(cards, states)
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs, { tag = "math" })
      session:load_cards()

      -- Should only have math and math/algebra, not python
      assert.equals(2, #session.queue)
      local ids = {}
      for _, c in ipairs(session.queue) do
        ids[c.id] = true
      end
      assert.is_true(ids["math1"])
      assert.is_true(ids["math2"])
      assert.is_nil(ids["py1"])
    end)
  end)

  -- ========================================================================
  -- Test: Reversible Cards
  -- ========================================================================

  describe("reversible cards", function()
    it("generates reversed state for reversible cards", function()
      local cards = {
        { id = "rev1", front = "Term", back = "Definition", tags = {}, reversible = true },
      }
      local states = {
        rev1 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                  learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
      }

      local store = make_mock_store(cards, states)
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs)
      session:load_cards()
      session:next_card()

      local card, is_reversed = session:current_card()
      assert.is_not_nil(card)
      assert.equals("rev1", card.id)
      assert.is_boolean(is_reversed)
      -- reversed_map should have an entry
      assert.is_not_nil(session.reversed_map["rev1"])
    end)

    it("does not reverse non-reversible cards", function()
      local cards = {
        { id = "std1", front = "Q", back = "A", tags = {}, reversible = false },
      }
      local states = {
        std1 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                  learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
      }

      local store = make_mock_store(cards, states)
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs)
      session:load_cards()
      session:next_card()

      local card, is_reversed = session:current_card()
      assert.is_not_nil(card)
      assert.is_false(is_reversed)
    end)

    it("preserves reversed state across skip", function()
      local cards = {
        { id = "rev1", front = "Term", back = "Def", tags = {}, reversible = true },
        { id = "card2", front = "Q", back = "A", tags = {}, reversible = false },
      }
      local states = {
        rev1 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                  learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
        card2 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                   learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
      }

      local store = make_mock_store(cards, states)
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs)
      session:load_cards()
      session:next_card()

      local _, is_reversed_1 = session:current_card()
      local saved_reversed = session.reversed_map["rev1"]

      -- Skip
      session:skip()

      -- The reversed_map entry should still exist
      assert.equals(saved_reversed, session.reversed_map["rev1"])

      -- Skip to the end to get back to rev1
      session:next_card()  -- now at card at end
      -- Navigate to it
      -- After skip, current card is the next one. We need to find rev1 at end.
      -- Just check the map is preserved
      assert.equals(saved_reversed, session.reversed_map["rev1"])
    end)
  end)

  -- ========================================================================
  -- Test: Session Flow
  -- ========================================================================

  describe("session flow", function()
    it("next_card returns false when session is done", function()
      local cards = {
        { id = "card1", front = "Q", back = "A", tags = {}, reversible = false },
      }
      local states = {
        card1 = { status = "new", stability = 0, difficulty = 0, reps = 0, lapses = 0,
                   learning_step = 0, elapsed_days = 0, scheduled_days = 0 },
      }

      local store = make_mock_store(cards, states)
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs)
      session:load_cards()

      local ok = session:next_card()
      assert.is_true(ok)

      -- Answer to complete the card (correct -> goes to review, no requeue)
      session:answer(2)

      -- Should be done (no more cards unless re-queued)
      ok = session:next_card()
      assert.is_false(ok)
    end)

    it("current_card returns nil when no card is current", function()
      local store = make_mock_store({}, {})
      local fsrs = make_mock_fsrs()

      local session = scheduler.new_session(store, fsrs)
      session:load_cards()

      local card, is_reversed = session:current_card()
      assert.is_nil(card)
      assert.is_false(is_reversed)
    end)
  end)
end)

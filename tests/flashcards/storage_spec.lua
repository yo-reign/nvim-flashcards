describe("storage", function()
  local Storage = require("flashcards.storage")
  local utils = require("flashcards.utils")
  local store
  local tmp_path

  before_each(function()
    -- Create a unique temp file for each test
    tmp_path = os.tmpname() .. ".json"
    store = Storage.new("json", tmp_path)
    store:init()
  end)

  after_each(function()
    if store then
      pcall(function() store:close() end)
    end
    os.remove(tmp_path)
  end)

  -- ==========================================================================
  -- Factory
  -- ==========================================================================

  describe("factory", function()
    it("creates json backend", function()
      local s = Storage.new("json", tmp_path)
      assert.is_not_nil(s)
      assert.is_function(s.init)
    end)

    it("errors on unknown type", function()
      assert.has_error(function()
        Storage.new("unknown", tmp_path)
      end)
    end)
  end)

  -- ==========================================================================
  -- Card Operations
  -- ==========================================================================

  describe("card operations", function()
    it("upserts and retrieves a card", function()
      store:upsert_card({
        id = "abc12345",
        file_path = "math/algebra.md",
        line = 5,
        front = "What is x?",
        back = "A variable",
        reversible = false,
        suspended = false,
        tags = { "math" },
        note = "Ch.1",
      })

      local card = store:get_card("abc12345")
      assert.is_not_nil(card)
      assert.equals("abc12345", card.id)
      assert.equals("math/algebra.md", card.file_path)
      assert.equals(5, card.line)
      assert.equals("What is x?", card.front)
      assert.equals("A variable", card.back)
      assert.is_false(card.reversible)
      assert.is_false(card.suspended)
      assert.same({ "math" }, card.tags)
      assert.equals("Ch.1", card.note)
      assert.is_true(card.active)
    end)

    it("returns nil for missing card", function()
      assert.is_nil(store:get_card("nonexistent"))
    end)

    it("updates content on re-upsert", function()
      store:upsert_card({
        id = "abc12345",
        file_path = "math/algebra.md",
        line = 5,
        front = "Old front",
        back = "Old back",
        tags = { "math" },
      })

      store:upsert_card({
        id = "abc12345",
        file_path = "math/algebra.md",
        line = 10,
        front = "New front",
        back = "New back",
        tags = { "math", "algebra" },
      })

      local card = store:get_card("abc12345")
      assert.equals("New front", card.front)
      assert.equals("New back", card.back)
      assert.equals(10, card.line)
      assert.same({ "math", "algebra" }, card.tags)
    end)

    it("reactivates lost card on re-upsert", function()
      store:upsert_card({
        id = "abc12345",
        file_path = "math/algebra.md",
        line = 5,
        front = "Q",
        back = "A",
        tags = {},
      })

      store:mark_lost("abc12345")
      local card = store:get_card("abc12345")
      assert.is_false(card.active)

      -- Re-upsert with new file path
      store:upsert_card({
        id = "abc12345",
        file_path = "math/new_file.md",
        line = 3,
        front = "Q updated",
        back = "A updated",
        tags = { "math" },
      })

      card = store:get_card("abc12345")
      assert.is_true(card.active)
      assert.equals("math/new_file.md", card.file_path)
      assert.equals("Q updated", card.front)
    end)

    it("preserves FSRS state on re-upsert", function()
      store:upsert_card({
        id = "abc12345",
        file_path = "math/algebra.md",
        line = 5,
        front = "Q",
        back = "A",
        tags = {},
      })

      store:update_card_state("abc12345", {
        status = "review",
        stability = 10.5,
        difficulty = 5.2,
        reps = 3,
      })

      -- Re-upsert with updated content
      store:upsert_card({
        id = "abc12345",
        file_path = "math/algebra.md",
        line = 5,
        front = "Q updated",
        back = "A updated",
        tags = {},
      })

      local state = store:get_card_state("abc12345")
      assert.equals("review", state.status)
      assert.equals(10.5, state.stability)
      assert.equals(5.2, state.difficulty)
      assert.equals(3, state.reps)
    end)

    it("gets all active cards (excludes inactive)", function()
      store:upsert_card({
        id = "card1",
        file_path = "a.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = {},
      })
      store:upsert_card({
        id = "card2",
        file_path = "b.md",
        line = 1,
        front = "Q2",
        back = "A2",
        tags = {},
      })
      store:upsert_card({
        id = "card3",
        file_path = "c.md",
        line = 1,
        front = "Q3",
        back = "A3",
        tags = {},
      })

      store:mark_lost("card2")

      local cards = store:get_all_cards()
      assert.equals(2, #cards)
      local ids = {}
      for _, c in ipairs(cards) do
        ids[c.id] = true
      end
      assert.is_true(ids["card1"])
      assert.is_true(ids["card3"])
      assert.is_nil(ids["card2"])
    end)

    it("gets cards by file path", function()
      store:upsert_card({
        id = "card1",
        file_path = "math/algebra.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = {},
      })
      store:upsert_card({
        id = "card2",
        file_path = "math/algebra.md",
        line = 5,
        front = "Q2",
        back = "A2",
        tags = {},
      })
      store:upsert_card({
        id = "card3",
        file_path = "cs/algo.md",
        line = 1,
        front = "Q3",
        back = "A3",
        tags = {},
      })

      local cards = store:get_cards_by_file("math/algebra.md")
      assert.equals(2, #cards)
    end)

    it("get_cards_by_file excludes inactive", function()
      store:upsert_card({
        id = "card1",
        file_path = "math/algebra.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = {},
      })
      store:upsert_card({
        id = "card2",
        file_path = "math/algebra.md",
        line = 5,
        front = "Q2",
        back = "A2",
        tags = {},
      })

      store:mark_lost("card1")

      local cards = store:get_cards_by_file("math/algebra.md")
      assert.equals(1, #cards)
      assert.equals("card2", cards[1].id)
    end)
  end)

  -- ==========================================================================
  -- State Operations
  -- ==========================================================================

  describe("state operations", function()
    it("provides default state for new card", function()
      store:upsert_card({
        id = "abc12345",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local state = store:get_card_state("abc12345")
      assert.is_not_nil(state)
      assert.equals("new", state.status)
      assert.equals(0, state.stability)
      assert.equals(0, state.difficulty)
      assert.is_nil(state.due_date)
      assert.is_nil(state.last_review)
      assert.equals(0, state.reps)
      assert.equals(0, state.lapses)
      assert.equals(0, state.learning_step)
      assert.equals(0, state.elapsed_days)
      assert.equals(0, state.scheduled_days)
    end)

    it("returns nil state for missing card", function()
      assert.is_nil(store:get_card_state("nonexistent"))
    end)

    it("updates state fields", function()
      store:upsert_card({
        id = "abc12345",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local now = utils.now()
      store:update_card_state("abc12345", {
        status = "learning",
        stability = 3.5,
        difficulty = 4.2,
        due_date = now + 600,
        last_review = now,
        reps = 1,
        learning_step = 1,
      })

      local state = store:get_card_state("abc12345")
      assert.equals("learning", state.status)
      assert.equals(3.5, state.stability)
      assert.equals(4.2, state.difficulty)
      assert.equals(now + 600, state.due_date)
      assert.equals(now, state.last_review)
      assert.equals(1, state.reps)
      assert.equals(1, state.learning_step)
      -- Unchanged fields preserved
      assert.equals(0, state.lapses)
      assert.equals(0, state.elapsed_days)
    end)

    it("merges partial state updates", function()
      store:upsert_card({
        id = "abc12345",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      store:update_card_state("abc12345", { status = "learning", reps = 1 })
      store:update_card_state("abc12345", { stability = 5.0 })

      local state = store:get_card_state("abc12345")
      assert.equals("learning", state.status)
      assert.equals(1, state.reps)
      assert.equals(5.0, state.stability)
    end)
  end)

  -- ==========================================================================
  -- Due Cards
  -- ==========================================================================

  describe("due cards", function()
    it("returns new cards as due", function()
      store:upsert_card({
        id = "new1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local due = store:get_due_cards()
      assert.equals(1, #due)
      assert.equals("new1", due[1].id)
    end)

    it("returns cards with due_date in the past", function()
      store:upsert_card({
        id = "due1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local past = utils.now() - 3600
      store:update_card_state("due1", {
        status = "review",
        due_date = past,
      })

      local due = store:get_due_cards()
      assert.equals(1, #due)
      assert.equals("due1", due[1].id)
    end)

    it("excludes cards with future due_date", function()
      store:upsert_card({
        id = "future1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local future = utils.now() + 86400
      store:update_card_state("future1", {
        status = "review",
        due_date = future,
      })

      local due = store:get_due_cards()
      assert.equals(0, #due)
    end)

    it("excludes suspended cards", function()
      store:upsert_card({
        id = "susp1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
        suspended = true,
      })

      local due = store:get_due_cards()
      assert.equals(0, #due)
    end)

    it("excludes inactive cards", function()
      store:upsert_card({
        id = "lost1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      store:mark_lost("lost1")

      local due = store:get_due_cards()
      assert.equals(0, #due)
    end)

    it("filters by tag", function()
      store:upsert_card({
        id = "math1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "py1",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "python" },
      })

      local due = store:get_due_cards("math")
      assert.equals(1, #due)
      assert.equals("math1", due[1].id)
    end)

    it("filters by hierarchical tag", function()
      store:upsert_card({
        id = "alg1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math/algebra" },
      })
      store:upsert_card({
        id = "calc1",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math/calc" },
      })
      store:upsert_card({
        id = "py1",
        file_path = "test.md",
        line = 3,
        front = "Q3",
        back = "A3",
        tags = { "python" },
      })

      local due = store:get_due_cards("math")
      assert.equals(2, #due)
    end)

    it("get_new_cards returns only new status", function()
      store:upsert_card({
        id = "new1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = {},
      })
      store:upsert_card({
        id = "rev1",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = {},
      })

      store:update_card_state("rev1", { status = "review", due_date = utils.now() - 3600 })

      local new = store:get_new_cards()
      assert.equals(1, #new)
      assert.equals("new1", new[1].id)
    end)

    it("get_new_cards excludes suspended", function()
      store:upsert_card({
        id = "new1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
        suspended = true,
      })

      local new = store:get_new_cards()
      assert.equals(0, #new)
    end)

    it("get_new_cards filters by tag", function()
      store:upsert_card({
        id = "m1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "p1",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "python" },
      })

      local new = store:get_new_cards("math")
      assert.equals(1, #new)
      assert.equals("m1", new[1].id)
    end)
  end)

  -- ==========================================================================
  -- Tags
  -- ==========================================================================

  describe("tags", function()
    it("gets all tags with counts", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math", "algebra" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math", "calc" },
      })
      store:upsert_card({
        id = "c3",
        file_path = "test.md",
        line = 3,
        front = "Q3",
        back = "A3",
        tags = { "python" },
      })

      local tags = store:get_all_tags()
      local tag_map = {}
      for _, t in ipairs(tags) do
        tag_map[t.tag] = t.count
      end

      assert.equals(2, tag_map["math"])
      assert.equals(1, tag_map["algebra"])
      assert.equals(1, tag_map["calc"])
      assert.equals(1, tag_map["python"])
    end)

    it("excludes inactive cards from tag counts", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math" },
      })

      store:mark_lost("c2")

      local tags = store:get_all_tags()
      assert.equals(1, #tags)
      assert.equals("math", tags[1].tag)
      assert.equals(1, tags[1].count)
    end)

    it("excludes suspended cards from tag counts", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math" },
        suspended = true,
      })

      local tags = store:get_all_tags()
      assert.equals(1, #tags)
      assert.equals(1, tags[1].count)
    end)

    it("includes due_count for new cards", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math" },
      })

      local tags = store:get_all_tags()
      assert.equals(1, #tags)
      assert.equals("math", tags[1].tag)
      assert.equals(2, tags[1].count)
      -- New cards are always due
      assert.equals(2, tags[1].due_count)
    end)

    it("includes due_count for past-due reviewed cards", function()
      local now = os.time()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math" },
      })

      -- c1: reviewed, due in the past (due)
      store:update_card_state("c1", {
        status = "review",
        due_date = now - 3600,
      })
      -- c2: reviewed, due in the future (not due)
      store:update_card_state("c2", {
        status = "review",
        due_date = now + 86400,
      })

      local tags = store:get_all_tags()
      assert.equals(1, #tags)
      assert.equals(2, tags[1].count)
      assert.equals(1, tags[1].due_count)
    end)

    it("returns due_count of 0 when no cards are due", function()
      local now = os.time()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "python" },
      })

      -- Set card as reviewed with future due date
      store:update_card_state("c1", {
        status = "review",
        due_date = now + 86400,
      })

      local tags = store:get_all_tags()
      assert.equals(1, #tags)
      assert.equals(1, tags[1].count)
      assert.equals(0, tags[1].due_count)
    end)

    it("counts due cards per tag correctly across multiple tags", function()
      local now = os.time()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math", "algebra" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math" },
      })

      -- c1: past due
      store:update_card_state("c1", {
        status = "review",
        due_date = now - 3600,
      })
      -- c2: future due
      store:update_card_state("c2", {
        status = "review",
        due_date = now + 86400,
      })

      local tags = store:get_all_tags()
      local tag_map = {}
      for _, t in ipairs(tags) do
        tag_map[t.tag] = t
      end

      assert.equals(2, tag_map["math"].count)
      assert.equals(1, tag_map["math"].due_count)
      assert.equals(1, tag_map["algebra"].count)
      assert.equals(1, tag_map["algebra"].due_count)
    end)

    it("filters by exact tag", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "python" },
      })

      local cards = store:get_cards_by_tag("math")
      assert.equals(1, #cards)
      assert.equals("c1", cards[1].id)
    end)

    it("matches hierarchical tags", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = { "math" },
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = { "math/algebra" },
      })
      store:upsert_card({
        id = "c3",
        file_path = "test.md",
        line = 3,
        front = "Q3",
        back = "A3",
        tags = { "math/algebra/linear" },
      })
      store:upsert_card({
        id = "c4",
        file_path = "test.md",
        line = 4,
        front = "Q4",
        back = "A4",
        tags = { "mathematics" },
      })

      local cards = store:get_cards_by_tag("math")
      assert.equals(3, #cards)
      -- "mathematics" should NOT match "math" (not a child)

      local cards2 = store:get_cards_by_tag("math/algebra")
      assert.equals(2, #cards2)
    end)
  end)

  -- ==========================================================================
  -- Orphan Management
  -- ==========================================================================

  describe("orphan management", function()
    it("mark_lost sets active to false", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      store:mark_lost("c1")
      local card = store:get_card("c1")
      assert.is_false(card.active)
      assert.is_not_nil(card.lost_at)
    end)

    it("get_orphaned_cards returns inactive cards", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = {},
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = {},
      })

      store:mark_lost("c1")

      local orphans = store:get_orphaned_cards()
      assert.equals(1, #orphans)
      assert.equals("c1", orphans[1].id)
    end)

    it("delete_card permanently removes", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      store:delete_card("c1")
      assert.is_nil(store:get_card("c1"))
    end)

    it("delete_all_orphans removes all inactive", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q1",
        back = "A1",
        tags = {},
      })
      store:upsert_card({
        id = "c2",
        file_path = "test.md",
        line = 2,
        front = "Q2",
        back = "A2",
        tags = {},
      })
      store:upsert_card({
        id = "c3",
        file_path = "test.md",
        line = 3,
        front = "Q3",
        back = "A3",
        tags = {},
      })

      store:mark_lost("c1")
      store:mark_lost("c2")

      store:delete_all_orphans()

      assert.is_nil(store:get_card("c1"))
      assert.is_nil(store:get_card("c2"))
      assert.is_not_nil(store:get_card("c3"))
    end)
  end)

  -- ==========================================================================
  -- Reviews
  -- ==========================================================================

  describe("reviews", function()
    it("records and retrieves reviews", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local now = utils.now()
      store:add_review({
        card_id = "c1",
        rating = 2,
        reviewed_at = now,
        elapsed_ms = 3500,
        state_before = "new",
        state_after = "learning",
      })
      store:add_review({
        card_id = "c1",
        rating = 2,
        reviewed_at = now + 60,
        elapsed_ms = 2100,
        state_before = "learning",
        state_after = "review",
      })

      local reviews = store:get_reviews("c1")
      assert.equals(2, #reviews)
      assert.equals(2, reviews[1].rating)
      assert.equals(3500, reviews[1].elapsed_ms)
      assert.equals("new", reviews[1].state_before)
      assert.equals("learning", reviews[1].state_after)
    end)

    it("returns empty list for card with no reviews", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      local reviews = store:get_reviews("c1")
      assert.same({}, reviews)
    end)
  end)

  -- ==========================================================================
  -- Statistics
  -- ==========================================================================

  describe("statistics", function()
    it("counts by state", function()
      store:upsert_card({ id = "c1", file_path = "a.md", line = 1, front = "Q1", back = "A1", tags = {} })
      store:upsert_card({ id = "c2", file_path = "a.md", line = 2, front = "Q2", back = "A2", tags = {} })
      store:upsert_card({ id = "c3", file_path = "a.md", line = 3, front = "Q3", back = "A3", tags = {} })
      store:upsert_card({ id = "c4", file_path = "a.md", line = 4, front = "Q4", back = "A4", tags = {} })

      store:update_card_state("c2", { status = "learning" })
      store:update_card_state("c3", { status = "review" })
      store:update_card_state("c4", { status = "relearning" })

      local counts = store:count_by_state()
      assert.equals(1, counts.new)
      assert.equals(1, counts.learning)
      assert.equals(1, counts.review)
      assert.equals(1, counts.relearning)
    end)

    it("count_by_state excludes inactive", function()
      store:upsert_card({ id = "c1", file_path = "a.md", line = 1, front = "Q1", back = "A1", tags = {} })
      store:upsert_card({ id = "c2", file_path = "a.md", line = 2, front = "Q2", back = "A2", tags = {} })

      store:mark_lost("c2")

      local counts = store:count_by_state()
      assert.equals(1, counts.new)
      assert.equals(0, counts.learning)
      assert.equals(0, counts.review)
      assert.equals(0, counts.relearning)
    end)

    it("count_due returns due breakdown", function()
      local now = utils.now()

      store:upsert_card({ id = "new1", file_path = "a.md", line = 1, front = "Q1", back = "A1", tags = {} })
      store:upsert_card({ id = "rev1", file_path = "a.md", line = 2, front = "Q2", back = "A2", tags = {} })
      store:upsert_card({ id = "lrn1", file_path = "a.md", line = 3, front = "Q3", back = "A3", tags = {} })
      store:upsert_card({ id = "fut1", file_path = "a.md", line = 4, front = "Q4", back = "A4", tags = {} })

      store:update_card_state("rev1", { status = "review", due_date = now - 3600 })
      store:update_card_state("lrn1", { status = "learning", due_date = now - 60 })
      store:update_card_state("fut1", { status = "review", due_date = now + 86400 })

      local counts = store:count_due()
      assert.equals(3, counts.total)
      assert.equals(1, counts.new)
      assert.equals(1, counts.review)
      assert.equals(1, counts.learning)
    end)

    it("get_stats returns full statistics", function()
      local now = utils.now()

      store:upsert_card({ id = "c1", file_path = "a.md", line = 1, front = "Q1", back = "A1", tags = {} })
      store:upsert_card({ id = "c2", file_path = "a.md", line = 2, front = "Q2", back = "A2", tags = {} })

      store:update_card_state("c2", { status = "review", due_date = now - 100 })

      store:add_review({ card_id = "c1", rating = 2, reviewed_at = now, elapsed_ms = 3000, state_before = "new", state_after = "learning" })
      store:add_review({ card_id = "c2", rating = 1, reviewed_at = now, elapsed_ms = 5000, state_before = "review", state_after = "relearning" })

      local stats = store:get_stats()
      assert.equals(2, stats.total_cards)
      assert.equals(2, stats.total_reviews)
      assert.is_number(stats.retention_rate)
      assert.equals(4000, stats.avg_time_ms)
    end)

    it("get_daily_stats returns per-day data", function()
      local now = utils.now()
      local today = utils.format_date(now)

      store:upsert_card({ id = "c1", file_path = "a.md", line = 1, front = "Q1", back = "A1", tags = {} })

      store:add_review({ card_id = "c1", rating = 2, reviewed_at = now, elapsed_ms = 3000, state_before = "new", state_after = "learning" })
      store:add_review({ card_id = "c1", rating = 2, reviewed_at = now + 60, elapsed_ms = 2000, state_before = "learning", state_after = "review" })

      local daily = store:get_daily_stats(7)
      assert.is_table(daily)
      -- Find today's entry
      local found = false
      for _, d in ipairs(daily) do
        if d.date == today then
          found = true
          assert.equals(1, d.new_count)
          assert.equals(1, d.review_count)
        end
      end
      assert.is_true(found)
    end)
  end)

  -- ==========================================================================
  -- Persistence
  -- ==========================================================================

  describe("persistence", function()
    it("saves to disk and reloads", function()
      store:upsert_card({
        id = "persist1",
        file_path = "test.md",
        line = 1,
        front = "Persistent Q",
        back = "Persistent A",
        tags = { "test" },
      })

      store:update_card_state("persist1", {
        status = "review",
        stability = 7.5,
        reps = 5,
      })

      store:add_review({
        card_id = "persist1",
        rating = 2,
        reviewed_at = utils.now(),
        elapsed_ms = 2000,
        state_before = "new",
        state_after = "review",
      })

      store:save()

      -- Create a brand new store from the same path
      local store2 = Storage.new("json", tmp_path)
      store2:init()

      local card = store2:get_card("persist1")
      assert.is_not_nil(card)
      assert.equals("Persistent Q", card.front)
      assert.equals("Persistent A", card.back)
      assert.same({ "test" }, card.tags)

      local state = store2:get_card_state("persist1")
      assert.equals("review", state.status)
      assert.equals(7.5, state.stability)
      assert.equals(5, state.reps)

      local reviews = store2:get_reviews("persist1")
      assert.equals(1, #reviews)

      store2:close()
    end)

    it("close saves and clears data", function()
      store:upsert_card({
        id = "c1",
        file_path = "test.md",
        line = 1,
        front = "Q",
        back = "A",
        tags = {},
      })

      store:close()

      -- Verify file was written
      local content = utils.read_file(tmp_path)
      assert.is_not_nil(content)
      assert.truthy(#content > 10)

      -- Reload works
      local store2 = Storage.new("json", tmp_path)
      store2:init()
      local card = store2:get_card("c1")
      assert.is_not_nil(card)
      store2:close()
    end)

    it("init creates empty store if file does not exist", function()
      local new_path = os.tmpname() .. "_new.json"
      os.remove(new_path)

      local s = Storage.new("json", new_path)
      s:init()

      local cards = s:get_all_cards()
      assert.same({}, cards)

      s:close()
      os.remove(new_path)
    end)

    it("data survives close and reopen cycle", function()
      -- Add data
      store:upsert_card({
        id = "surv1",
        file_path = "test.md",
        line = 1,
        front = "Survive Q",
        back = "Survive A",
        tags = { "persist" },
        note = "test note",
      })
      store:update_card_state("surv1", { status = "learning", stability = 2.0 })

      -- Close
      store:close()

      -- Reopen
      store = Storage.new("json", tmp_path)
      store:init()

      -- Verify data survived
      local card = store:get_card("surv1")
      assert.equals("Survive Q", card.front)
      assert.equals("test note", card.note)

      local state = store:get_card_state("surv1")
      assert.equals("learning", state.status)
      assert.equals(2.0, state.stability)
    end)
  end)
end)

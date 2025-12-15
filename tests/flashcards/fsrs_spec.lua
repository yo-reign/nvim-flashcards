-- Tests for the FSRS algorithm
-- Run with: nvim --headless -c "PlenaryBustedDirectory tests/"

describe("fsrs", function()
    -- Mock dependencies
    local mock_config = {
        options = {
            fsrs = {
                target_correctness = 0.85,
                maximum_interval = 365,
                enable_fuzz = false, -- Disable fuzz for deterministic tests
                weights = {
                    initial_stability_wrong = 0.5,
                    initial_stability_correct = 3.0,
                    initial_difficulty = 5.0,
                    difficulty_decay = 0.3,
                    difficulty_growth = 0.5,
                    stability_factor = 2.5,
                    difficulty_weight = 0.1,
                    forget_stability_factor = 0.3,
                    learning_steps = { 1, 10, 60 },
                },
            },
        },
    }

    local mock_utils = {
        now = function() return 1700000000 end,
        days_between = function(from, to) return (to - from) / 86400 end,
        add_days = function(ts, days) return ts + math.floor(days * 86400) end,
        format_interval = function(days)
            if days < 1 then
                return math.floor(days * 24 * 60) .. "m"
            else
                return math.floor(days) .. "d"
            end
        end,
    }

    -- Setup mocks before loading the module
    before_each(function()
        package.loaded["flashcards.config"] = mock_config
        package.loaded["flashcards.utils"] = mock_utils
        package.loaded["flashcards.fsrs"] = nil
    end)

    after_each(function()
        package.loaded["flashcards.config"] = nil
        package.loaded["flashcards.utils"] = nil
        package.loaded["flashcards.fsrs"] = nil
    end)

    describe("Rating", function()
        it("should have binary ratings", function()
            local fsrs = require("flashcards.fsrs")
            assert.equals(1, fsrs.Rating.Wrong)
            assert.equals(2, fsrs.Rating.Correct)
        end)
    end)

    describe("State", function()
        it("should have all states defined", function()
            local fsrs = require("flashcards.fsrs")
            assert.equals("new", fsrs.State.New)
            assert.equals("learning", fsrs.State.Learning)
            assert.equals("review", fsrs.State.Review)
            assert.equals("relearning", fsrs.State.Relearning)
        end)
    end)

    describe("FSRS:new", function()
        it("should create scheduler with default parameters", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            assert.equals(0.85, scheduler.target_correctness)
            assert.equals(365, scheduler.maximum_interval)
            assert.is_false(scheduler.enable_fuzz)
        end)

        it("should accept custom parameters", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new({
                target_correctness = 0.9,
                maximum_interval = 180,
            })

            assert.equals(0.9, scheduler.target_correctness)
            assert.equals(180, scheduler.maximum_interval)
        end)
    end)

    describe("FSRS:init_stability", function()
        it("should return correct initial stability for Correct rating", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local stability = scheduler:init_stability(fsrs.Rating.Correct)
            assert.equals(3.0, stability)
        end)

        it("should return lower initial stability for Wrong rating", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local stability = scheduler:init_stability(fsrs.Rating.Wrong)
            assert.equals(0.5, stability)
        end)
    end)

    describe("FSRS:next_difficulty", function()
        it("should decrease difficulty on correct answer", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local new_d = scheduler:next_difficulty(5.0, fsrs.Rating.Correct)
            assert.is_true(new_d < 5.0)
            assert.equals(4.7, new_d)
        end)

        it("should increase difficulty on wrong answer", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local new_d = scheduler:next_difficulty(5.0, fsrs.Rating.Wrong)
            assert.is_true(new_d > 5.0)
            assert.equals(5.5, new_d)
        end)

        it("should clamp difficulty between 1 and 10", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            -- Test upper bound
            local high_d = scheduler:next_difficulty(9.8, fsrs.Rating.Wrong)
            assert.equals(10, high_d)

            -- Test lower bound
            local low_d = scheduler:next_difficulty(1.2, fsrs.Rating.Correct)
            assert.equals(1, low_d)
        end)
    end)

    describe("FSRS:retrievability", function()
        it("should return 1.0 for zero elapsed days", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local r = scheduler:retrievability(0, 10)
            assert.equals(1.0, r)
        end)

        it("should return 0.5 after one stability interval", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            -- After 'stability' days, retrievability should be 0.5 (half-life)
            local r = scheduler:retrievability(10, 10)
            assert.is_true(math.abs(r - 0.5) < 0.01)
        end)

        it("should decrease over time", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local r1 = scheduler:retrievability(1, 10)
            local r2 = scheduler:retrievability(5, 10)
            local r3 = scheduler:retrievability(10, 10)

            assert.is_true(r1 > r2)
            assert.is_true(r2 > r3)
        end)

        it("should return 0 for zero stability", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local r = scheduler:retrievability(5, 0)
            assert.equals(0, r)
        end)
    end)

    describe("FSRS:next_interval", function()
        it("should calculate interval based on target correctness", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new({ target_correctness = 0.85 })

            local interval = scheduler:next_interval(10)
            -- For 85% target, interval should be about stability * 0.234
            assert.is_true(interval >= 1)
            assert.is_true(interval <= 365)
        end)

        it("should increase interval with higher stability", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local i1 = scheduler:next_interval(5)
            local i2 = scheduler:next_interval(10)
            local i3 = scheduler:next_interval(20)

            assert.is_true(i2 > i1)
            assert.is_true(i3 > i2)
        end)

        it("should respect maximum interval", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new({ maximum_interval = 30 })

            local interval = scheduler:next_interval(1000)
            assert.equals(30, interval)
        end)
    end)

    describe("FSRS:schedule - New cards", function()
        it("should move to learning on first correct", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local card_state = { state = "new" }
            local new_state, intervals = scheduler:schedule(card_state, fsrs.Rating.Correct)

            assert.equals("learning", new_state.state)
            assert.equals(1, new_state.reps)
            assert.equals(0, new_state.lapses)
            assert.equals(1, new_state.learning_step)
            assert.is_true(intervals.days < 1) -- Learning interval in minutes
        end)

        it("should move to learning on first wrong with lapse", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local card_state = { state = "new" }
            local new_state, intervals = scheduler:schedule(card_state, fsrs.Rating.Wrong)

            assert.equals("learning", new_state.state)
            assert.equals(1, new_state.reps)
            assert.equals(1, new_state.lapses)
            assert.equals(0, new_state.learning_step)
            assert.is_true(intervals.days < 0.01) -- ~1 minute
        end)
    end)

    describe("FSRS:schedule - Learning cards", function()
        it("should progress through learning steps on correct", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local card_state = {
                state = "learning",
                stability = 3.0,
                difficulty = 5.0,
                learning_step = 0,
                reps = 1,
                lapses = 0,
            }

            local new_state = scheduler:schedule(card_state, fsrs.Rating.Correct)

            assert.equals("learning", new_state.state)
            assert.equals(1, new_state.learning_step)
        end)

        it("should graduate to review after completing learning steps", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local card_state = {
                state = "learning",
                stability = 3.0,
                difficulty = 5.0,
                learning_step = 2, -- Last step
                reps = 3,
                lapses = 0,
            }

            local new_state, intervals = scheduler:schedule(card_state, fsrs.Rating.Correct)

            assert.equals("review", new_state.state)
            assert.equals(0, new_state.learning_step)
            assert.is_true(intervals.days >= 1) -- Review interval
        end)

        it("should reset to first step on wrong", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local card_state = {
                state = "learning",
                stability = 3.0,
                difficulty = 5.0,
                learning_step = 2,
                reps = 3,
                lapses = 0,
            }

            local new_state = scheduler:schedule(card_state, fsrs.Rating.Wrong)

            assert.equals("learning", new_state.state)
            assert.equals(0, new_state.learning_step)
            assert.equals(1, new_state.lapses)
        end)
    end)

    describe("FSRS:schedule - Review cards", function()
        it("should increase stability on correct review", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local card_state = {
                state = "review",
                stability = 10.0,
                difficulty = 5.0,
                last_review = mock_utils.now() - 86400 * 5, -- 5 days ago
                reps = 5,
                lapses = 0,
            }

            local new_state = scheduler:schedule(card_state, fsrs.Rating.Correct)

            assert.equals("review", new_state.state)
            assert.is_true(new_state.stability > 10.0)
        end)

        it("should move to relearning on wrong review", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local card_state = {
                state = "review",
                stability = 10.0,
                difficulty = 5.0,
                last_review = mock_utils.now() - 86400 * 5,
                reps = 5,
                lapses = 0,
            }

            local new_state = scheduler:schedule(card_state, fsrs.Rating.Wrong)

            assert.equals("relearning", new_state.state)
            assert.is_true(new_state.stability < 10.0) -- Reduced stability
            assert.equals(1, new_state.lapses)
        end)

        it("should increase difficulty on wrong", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local card_state = {
                state = "review",
                stability = 10.0,
                difficulty = 5.0,
                last_review = mock_utils.now() - 86400 * 5,
                reps = 5,
                lapses = 0,
            }

            local new_state = scheduler:schedule(card_state, fsrs.Rating.Wrong)
            assert.is_true(new_state.difficulty > 5.0)
        end)

        it("should decrease difficulty on correct", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local card_state = {
                state = "review",
                stability = 10.0,
                difficulty = 5.0,
                last_review = mock_utils.now() - 86400 * 5,
                reps = 5,
                lapses = 0,
            }

            local new_state = scheduler:schedule(card_state, fsrs.Rating.Correct)
            assert.is_true(new_state.difficulty < 5.0)
        end)
    end)

    describe("FSRS:preview_intervals", function()
        it("should return intervals for both ratings", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local card_state = {
                state = "review",
                stability = 10.0,
                difficulty = 5.0,
                last_review = mock_utils.now() - 86400 * 5,
                reps = 5,
                lapses = 0,
            }

            local previews = scheduler:preview_intervals(card_state)

            assert.is_not_nil(previews[1]) -- Wrong
            assert.is_not_nil(previews[2]) -- Correct
            assert.is_not_nil(previews[1].days)
            assert.is_not_nil(previews[2].days)
            assert.is_not_nil(previews[1].formatted)
            assert.is_not_nil(previews[2].formatted)
        end)

        it("should show shorter interval for wrong than correct", function()
            local fsrs = require("flashcards.fsrs")
            local scheduler = fsrs.new()

            local card_state = {
                state = "review",
                stability = 10.0,
                difficulty = 5.0,
                last_review = mock_utils.now() - 86400 * 5,
                reps = 5,
                lapses = 0,
            }

            local previews = scheduler:preview_intervals(card_state)

            assert.is_true(previews[1].days < previews[2].days)
        end)
    end)

    describe("rating_name", function()
        it("should return correct names", function()
            local fsrs = require("flashcards.fsrs")
            assert.equals("Wrong", fsrs.rating_name(1))
            assert.equals("Correct", fsrs.rating_name(2))
            assert.equals("Unknown", fsrs.rating_name(99))
        end)
    end)

    describe("state_name", function()
        it("should return correct names", function()
            local fsrs = require("flashcards.fsrs")
            assert.equals("New", fsrs.state_name("new"))
            assert.equals("Learning", fsrs.state_name("learning"))
            assert.equals("Review", fsrs.state_name("review"))
            assert.equals("Relearning", fsrs.state_name("relearning"))
        end)
    end)

    describe("Target correctness effect", function()
        it("should schedule shorter intervals with higher target", function()
            local fsrs = require("flashcards.fsrs")

            local scheduler_85 = fsrs.new({ target_correctness = 0.85, enable_fuzz = false })
            local scheduler_90 = fsrs.new({ target_correctness = 0.90, enable_fuzz = false })

            local card_state = {
                state = "review",
                stability = 10.0,
                difficulty = 5.0,
                last_review = mock_utils.now() - 86400 * 5,
                reps = 5,
                lapses = 0,
            }

            local _, intervals_85 = scheduler_85:schedule(card_state, fsrs.Rating.Correct)
            local _, intervals_90 = scheduler_90:schedule(card_state, fsrs.Rating.Correct)

            -- Higher target correctness = shorter intervals (review more often)
            assert.is_true(intervals_90.days < intervals_85.days)
        end)
    end)
end)

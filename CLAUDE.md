# nvim-flashcards

A Neovim plugin for markdown-based spaced repetition flashcards using the FSRS algorithm.

## Project Overview

This plugin replaces Anki with a native Neovim experience. Cards are defined inline in markdown files using intuitive syntax, automatically detected through recursive directory scanning, and reviewed through a beautiful floating UI with full syntax highlighting.

## Core Features

1. **Markdown-based cards** - Define flashcards directly in your notes
2. **FSRS algorithm** - Modern, research-backed spaced repetition scheduling
3. **Hierarchical tags** - `#math/calc`, `#math/algebra` with parent inheritance
4. **Multi-line support** - Code blocks, lists, and complex formatting preserved
5. **Telescope integration** - Search, filter, and browse cards
6. **LSP/Treesitter highlighting** - Full syntax highlighting in review UI

## Architecture

```
nvim-flashcards/
├── lua/
│   └── flashcards/
│       ├── init.lua              # Plugin entry point, setup()
│       ├── config.lua            # Configuration management
│       ├── parser.lua            # Markdown parsing, card extraction
│       ├── fsrs.lua              # FSRS algorithm implementation
│       ├── db.lua                # SQLite database layer
│       ├── scheduler.lua         # Review scheduling logic
│       ├── ui/
│       │   ├── init.lua          # UI module entry
│       │   ├── review.lua        # Review session floating window
│       │   ├── stats.lua         # Statistics panel
│       │   └── components.lua    # Reusable UI components (nui.nvim)
│       ├── telescope/
│       │   ├── init.lua          # Telescope extension
│       │   └── pickers.lua       # Custom pickers (browse, due, tags)
│       └── utils.lua             # Shared utilities
├── plugin/
│   └── flashcards.lua            # Lazy-load trigger
├── doc/
│   └── flashcards.txt            # Vimdoc help
├── tests/
│   └── flashcards/               # Plenary-based tests
├── CLAUDE.md                     # This file
└── README.md                     # User documentation
```

## Dependencies

| Dependency | Purpose | Required |
|------------|---------|----------|
| `nvim-lua/plenary.nvim` | Async, paths, testing | Yes |
| `MunifTanjim/nui.nvim` | UI components (popups, layouts) | Yes |
| `nvim-telescope/telescope.nvim` | Card browsing and search | Yes |
| `kkharji/sqlite.lua` | Persistent card state storage | Yes |
| `nvim-treesitter/nvim-treesitter` | Syntax highlighting in UI | Recommended |

## Card Syntax

### Card IDs

Cards are identified by unique IDs stored as markdown comments. IDs are auto-generated when scanning:
- Inline: `front ::: back #tags <!-- fc:abc12345 -->`
- Fenced: `:::card <!-- fc:abc12345 -->`

This allows editing card content without losing review history.

### Single-line Cards

```markdown
<!-- Basic card (ID will be added on scan) -->
What is a closure? ::: A function that captures variables from its enclosing scope

<!-- With tags -->
What is a monad? ::: A design pattern for chaining operations #haskell #fp

<!-- After scanning, IDs are added automatically -->
What is a closure? ::: A function that captures variables from its enclosing scope <!-- fc:a1b2c3d4 -->
```

### Reversible Cards

Use `:?:` instead of `:::` for cards where either side can appear as the question (50% chance):

```markdown
<!-- Reversible card - can show "Term" or "Definition" as the question -->
Term :?: Definition #vocabulary

<!-- During review, if reversed, the header shows ↔ indicator -->
```

### Multi-line Cards (Fenced)

Uses `:::card` fences which don't conflict with code blocks inside. Use `:-:` to separate front from back:

```markdown
:::card <!-- fc:x9y8z7w6 -->
What does this function do?

```python
def reverse(s):
    if len(s) <= 1:
        return s
    return reverse(s[1:]) + s[0]
```
:-:
It reverses a string using recursion.
::: #python #recursion
```

Tags go on the closing `:::` line.

### Reversible Multi-line Cards

Use `:?:card` instead of `:::card` for reversible fenced cards (50% chance of showing back first):

```markdown
:?:card <!-- fc:abc12345 -->
Term or concept here
:-:
Definition or explanation here
:?: #vocabulary
```

## Tag System

### Hierarchy Rules

- Tags use `/` for hierarchy: `#math/calc`, `#math/algebra`
- Querying `#math` returns all cards tagged with `#math/*`
- Cards inherit from the containing file's path: `notes/math/calculus.md` → implicit `#math/calculus`
- Explicit tags override implicit ones
- Multiple tags per card supported

### Tag Scopes

Use `:#tag:` to apply a tag to all following cards in a file until `:#:` clears it:

```markdown
:#python:

What is a list? ::: An ordered, mutable collection
What is a dict? ::: A key-value mapping

:#:
```

Both cards get the `#python` tag without explicit `#python` on each line.

Multiple scopes stack:

```markdown
:#math:
:#algebra:

Quadratic formula ::: x = (-b ± √(b²-4ac)) / 2a

:#:
```

### Tag Storage

```sql
-- Tags stored in normalized form
CREATE TABLE card_tags (
    card_id TEXT,
    tag TEXT,           -- Full tag path: "math/calc"
    PRIMARY KEY (card_id, tag)
);

-- Querying "math" finds:
-- WHERE tag = 'math' OR tag LIKE 'math/%'
```

## FSRS Algorithm Implementation

The plugin uses a simplified FSRS-inspired algorithm with **binary ratings** (Wrong/Correct) and **adjustable target correctness**.

### Core Concepts

1. **Stability (S)**: Days until retention drops to target
2. **Difficulty (D)**: Inherent difficulty of the card (1-10)
3. **Retrievability (R)**: Current probability of recall
4. **State**: New, Learning, Review, Relearning
5. **Target Correctness**: Configurable retention target (default 85%)

### Binary Ratings

- **Wrong (1)**: Failed to recall - resets to learning
- **Correct (2)**: Successfully recalled - increases stability

### Key Features

- **Learning Steps**: Cards go through 1min → 10min → 1hour before graduating
- **Adjustable Target**: Set `target_correctness` from 0.7 to 0.95
- **Higher target = More reviews**: 90% target means shorter intervals than 85%

### Implementation

```lua
-- lua/flashcards/fsrs.lua

local FSRS = {}

-- Binary ratings
M.Rating = {
    Wrong = 1,   -- Failed to recall
    Correct = 2, -- Successfully recalled
}

-- Configurable parameters
FSRS.defaults = {
    target_correctness = 0.85,  -- 85% retention target
    maximum_interval = 365,
    weights = {
        initial_stability_wrong = 0.5,
        initial_stability_correct = 3.0,
        learning_steps = { 1, 10, 60 },  -- minutes
    },
}

function FSRS:schedule(card, rating, now)
    -- Returns next review date, updated stability, difficulty
end
```

## Database Schema

Using SQLite via `sqlite.lua` for persistence:

```sql
-- Cards table
CREATE TABLE cards (
    id TEXT PRIMARY KEY,           -- Unique ID stored in source file
    file_path TEXT NOT NULL,
    line_number INTEGER,
    front TEXT NOT NULL,
    back TEXT NOT NULL,
    reversible INTEGER DEFAULT 0,  -- 1 if card uses :?: (shows either side)
    created_at INTEGER,
    updated_at INTEGER
);

-- Card state (FSRS parameters)
CREATE TABLE card_states (
    card_id TEXT PRIMARY KEY,
    state TEXT DEFAULT 'new',      -- new, learning, review, relearning
    stability REAL DEFAULT 0,
    difficulty REAL DEFAULT 0,
    elapsed_days INTEGER DEFAULT 0,
    scheduled_days INTEGER DEFAULT 0,
    due_date INTEGER,              -- Unix timestamp
    last_review INTEGER,
    reps INTEGER DEFAULT 0,
    lapses INTEGER DEFAULT 0,
    FOREIGN KEY (card_id) REFERENCES cards(id)
);

-- Review history (for analytics and FSRS optimization)
CREATE TABLE reviews (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    card_id TEXT,
    rating INTEGER,                -- 1-4
    reviewed_at INTEGER,
    elapsed_ms INTEGER,            -- Time to answer
    state_before TEXT,
    state_after TEXT,
    FOREIGN KEY (card_id) REFERENCES cards(id)
);

-- Tags
CREATE TABLE card_tags (
    card_id TEXT,
    tag TEXT,
    PRIMARY KEY (card_id, tag),
    FOREIGN KEY (card_id) REFERENCES cards(id)
);

-- Indexes
CREATE INDEX idx_cards_file ON cards(file_path);
CREATE INDEX idx_states_due ON card_states(due_date);
CREATE INDEX idx_tags_tag ON card_tags(tag);
```

## UI Design

### Review Window

Using `nui.nvim` for a floating window with binary rating:

```
┌─────────────────────────────────────────────────────────────┐
│  nvim-flashcards                     📊 12/50  ⏱️  5m 32s   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  What is the time complexity of binary search?              │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│                                                             │
│  O(log n) - The search space is halved with each           │
│  comparison.                                                │
│                                                             │
│  ```python                                                  │
│  def binary_search(arr, target):                           │
│      left, right = 0, len(arr) - 1                         │
│      while left <= right:                                  │
│          mid = (left + right) // 2                         │
│          if arr[mid] == target:                            │
│              return mid                                     │
│      ...                                                    │
│  ```                                                        │
│                                                             │
│  #algorithms #searching                                     │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│  [1] Wrong    [2] Correct      [q] Quit                     │
│   <1m          <7d                                          │
│                                                             │
│  (Also: n=Wrong, y=Correct, s=Skip, u=Undo, e=Edit)        │
└─────────────────────────────────────────────────────────────┘
```

### Key Features

1. **Markdown rendering** with treesitter highlighting
2. **Code block syntax highlighting** (language-aware)
3. **Progress indicator** and session timer
4. **Next interval preview** for each rating
5. **Keyboard shortcuts** for all actions

### Implementation

```lua
-- Uses nui.nvim components
local Popup = require("nui.popup")
local Layout = require("nui.layout")
local event = require("nui.utils.autocmd").event

local function create_review_window()
    local popup = Popup({
        enter = true,
        focusable = true,
        border = {
            style = "rounded",
            text = {
                top = " nvim-flashcards ",
                top_align = "center",
            },
        },
        buf_options = {
            modifiable = false,
            filetype = "markdown",  -- Enables treesitter highlighting
        },
        win_options = {
            conceallevel = 2,
            concealcursor = "n",
        },
    })
    return popup
end
```

## Telescope Integration

### Pickers

1. **`:Telescope flashcards due`** - Cards due for review
2. **`:Telescope flashcards browse`** - All cards with preview
3. **`:Telescope flashcards tags`** - Browse by tag hierarchy
4. **`:Telescope flashcards search`** - Full-text search

### Implementation

```lua
-- lua/flashcards/telescope/pickers.lua
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local previewers = require("telescope.previewers")

local M = {}

function M.due_cards(opts)
    opts = opts or {}
    local db = require("flashcards.db")
    local cards = db.get_due_cards()

    pickers.new(opts, {
        prompt_title = "Due Cards",
        finder = finders.new_table({
            results = cards,
            entry_maker = function(card)
                return {
                    value = card,
                    display = card.front:sub(1, 60),
                    ordinal = card.front,
                    path = card.file_path,
                    lnum = card.line_number,
                }
            end,
        }),
        sorter = conf.generic_sorter(opts),
        previewer = previewers.new_buffer_previewer({
            title = "Card Preview",
            define_preview = function(self, entry)
                -- Render card with markdown highlighting
            end,
        }),
    }):find()
end

return M
```

## Commands

| Command | Description |
|---------|-------------|
| `:FlashcardsReview` | Start review session (due cards) |
| `:FlashcardsReview #tag` | Review cards with specific tag |
| `:FlashcardsScan` | Rescan all markdown files |
| `:FlashcardsStats` | Show statistics dashboard |
| `:FlashcardsEdit` | Jump to card source file |
| `:FlashcardsBrowse` | Open Telescope browser |
| `:FlashcardsSync` | Manual database sync |

## Configuration

```lua
require("flashcards").setup({
    -- Directories to scan for cards
    directories = {
        "~/notes",
    },

    -- Database location (pick one):
    -- Option 1: Directory path (db_filename will be appended)
    db_path = "~/notes/assets/",
    -- Option 2: Full file path
    -- db_path = "~/.local/share/nvim/flashcards.db",
    -- Option 3: Leave nil, uses db_filename in each configured directory (default)
    -- db_path = nil,
    -- db_filename = ".flashcards.db",

    -- FSRS parameters with binary rating
    fsrs = {
        target_correctness = 0.85,  -- 85% target retention (0.7-0.95)
        maximum_interval = 365,
        enable_fuzz = true,
        weights = {
            learning_steps = { 1, 10, 60 },  -- minutes
        },
    },

    -- UI settings
    ui = {
        width = 0.7,
        height = 0.6,
        border = "rounded",
        show_answer_key = "<Space>",
        keymaps = {
            wrong = "1",    -- Binary: wrong
            correct = "2",  -- Binary: correct
            quit = "q",
            edit = "e",
            skip = "s",
            undo = "u",
        },
    },

    -- Session limits
    session = {
        new_cards_per_day = 20,
    },

    -- Auto-sync on file save
    auto_sync = true,
})
```

## Implementation Plan

### Phase 1: Core Foundation ✅
1. [x] Project structure setup
2. [x] Configuration module (`config.lua`)
3. [x] Database schema and SQLite integration (`db.lua`)
4. [x] Markdown parser for card extraction (`parser.lua`)
5. [x] FSRS algorithm with binary rating (`fsrs.lua`)

### Phase 2: Basic Functionality ✅
1. [x] Card scanner (recursive directory walking)
2. [x] Card CRUD operations
3. [x] Tag parsing and hierarchy
4. [x] Scheduler for due cards (`scheduler.lua`)
5. [x] Basic commands (`:FlashcardsReview`, `:FlashcardsScan`)

### Phase 3: User Interface ✅
1. [x] Review floating window with nui.nvim
2. [x] Markdown rendering with treesitter
3. [x] Code block syntax highlighting
4. [x] Progress and statistics display
5. [x] Keyboard navigation (binary: 1=Wrong, 2=Correct)

### Phase 4: Telescope Integration ✅
1. [x] Due cards picker
2. [x] Browse all cards picker
3. [x] Tag hierarchy picker
4. [x] Full-text search picker
5. [x] Card preview

### Phase 5: Polish
1. [x] Statistics dashboard
2. [x] Binary rating system (simplified from 4-point)
3. [x] Adjustable target correctness
4. [x] FSRS algorithm tests
5. [ ] Documentation (vimdoc)
6. [ ] Export/import functionality

## Development Notes

### Treesitter Highlighting in Floating Windows

To enable syntax highlighting in the review buffer:

```lua
-- Set buffer filetype to markdown
vim.bo[buf].filetype = "markdown"

-- Treesitter will automatically attach if installed
-- For code blocks, use injections (built into nvim-treesitter)
```

### Card ID Generation

Cards are identified by inline markdown comment IDs (e.g., `<!-- fc:abc12345 -->`):

```lua
-- Generate a new unique 8-character ID
local function generate_new_id()
    local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    local id = ""
    for _ = 1, 8 do
        local idx = math.random(1, #chars)
        id = id .. chars:sub(idx, idx)
    end
    return id
end

-- Extract existing ID from text
local function extract_card_id(text)
    return text:match("<!%-%-%s*fc:([%w]+)%s*%-%->")
end

-- Format ID as comment
local function format_card_id(id)
    return "<!-- fc:" .. id .. " -->"
end
```

When scanning:
1. If card has an existing `<!-- fc:id -->` comment, use that ID
2. If no ID exists, generate a new one and write it to the source file
3. IDs persist through content edits, preserving review history

### Handling Card Updates

When scanning, compare new cards against existing:
1. **Same ID exists**: Update content if changed (preserves review state)
2. **New card**: Insert with "new" state, write ID to source file
3. **Card missing**: Delete from database

### Performance Considerations

- Use async scanning with `plenary.async`
- Lazy-load database connection
- Cache frequently accessed data
- Debounce file watchers if auto-sync enabled

## Testing Strategy

Using plenary.nvim test harness:

```lua
-- tests/flashcards/parser_spec.lua
describe("parser", function()
    local parser = require("flashcards.parser")

    it("extracts inline cards", function()
        local content = "What is 2+2? ::: 4"
        local cards = parser.parse_content(content)
        assert.equals(1, #cards)
        assert.equals("What is 2+2?", cards[1].front)
        assert.equals("4", cards[1].back)
    end)

    it("extracts tags", function()
        local content = "Question ::: Answer #math #basics"
        local cards = parser.parse_content(content)
        assert.same({"math", "basics"}, cards[1].tags)
    end)

    it("extracts reversible cards", function()
        local content = "Term :?: Definition #vocab"
        local cards = parser.parse_content(content)
        assert.equals(1, #cards)
        assert.is_true(cards[1].reversible)
    end)

    it("applies scoped tags", function()
        local content = ":#math:\nQ1 ::: A1\nQ2 ::: A2\n:#:"
        local cards = parser.parse_file("test.md", content)
        assert.equals(2, #cards)
        assert.is_true(vim.tbl_contains(cards[1].tags, "math"))
        assert.is_true(vim.tbl_contains(cards[2].tags, "math"))
    end)
end)
```

Run tests with: `nvim --headless -c "PlenaryBustedDirectory tests/"`

## References

- [FSRS Algorithm](https://github.com/open-spaced-repetition/fsrs4anki)
- [nui.nvim Documentation](https://github.com/MunifTanjim/nui.nvim)
- [telescope.nvim Developer Guide](https://github.com/nvim-telescope/telescope.nvim/blob/master/developers.md)
- [sqlite.lua](https://github.com/kkharji/sqlite.lua)
- [Neovim Plugin Best Practices](https://github.com/nvim-neorocks/nvim-best-practices)

# nvim-flashcards

A Neovim plugin for markdown-based spaced repetition flashcards using a simplified FSRS algorithm with binary ratings (Wrong/Correct).

## Features

- **Markdown-based cards** - Define flashcards directly in your notes
- **Binary rating system** - Simple Wrong/Correct rating (no complex 4-point scale)
- **Adjustable target correctness** - Set your target retention rate (default 85%)
- **FSRS-inspired algorithm** - Modern spaced repetition scheduling
- **Hierarchical tags** - `#math/calc`, `#math/algebra` with parent inheritance
- **Multi-line support** - Code blocks, lists, and complex formatting preserved
- **Telescope integration** - Search, filter, and browse cards
- **Beautiful UI** - Floating window with syntax highlighting

## Requirements

- Neovim >= 0.9.0
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- [sqlite.lua](https://github.com/kkharji/sqlite.lua)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) (optional, for syntax highlighting)

## Installation

### lazy.nvim

```lua
{
    "yo-reign/nvim-flashcards",
    dependencies = {
        "nvim-lua/plenary.nvim",
        "MunifTanjim/nui.nvim",
        "nvim-telescope/telescope.nvim",
        "kkharji/sqlite.lua",
    },
    config = function()
        require("flashcards").setup({
            directories = { "~/notes" },
            fsrs = {
                target_correctness = 0.85, -- 85% target retention
            },
        })
    end,
}
```

### packer.nvim

```lua
use {
    "yo-reign/nvim-flashcards",
    requires = {
        "nvim-lua/plenary.nvim",
        "MunifTanjim/nui.nvim",
        "nvim-telescope/telescope.nvim",
        "kkharji/sqlite.lua",
    },
    config = function()
        require("flashcards").setup({
            directories = { "~/notes" },
        })
    end,
}
```

## Quick Start

1. Initialize flashcards in your notes directory:
   ```
   :FlashcardsInit
   ```

2. Create cards in your markdown files:
   ```markdown
   What is a closure? :: A function that captures variables from its enclosing scope #programming
   ```

3. Start a review session:
   ```
   :FlashcardsReview
   ```

4. Use `1` for Correct, `2` for Wrong (or `y`/`n`)

## Card Syntax

### Inline Cards

```markdown
Question text :: Answer text #tag1 #tag2
```

After scanning, an ID comment is automatically added:
```markdown
Question text :: Answer text #tag1 #tag2 <!-- fc:abc12345 -->
```

### Multi-line Cards (Fenced)

Uses `:::card` fences which don't conflict with code blocks inside:

```markdown
:::card
What does this function do?

```python
def reverse(s):
    if len(s) <= 1:
        return s
    return reverse(s[1:]) + s[0]
```
---
It reverses a string using recursion.
::: #python #recursion
```

After scanning, an ID is added to the opening line:
```markdown
:::card <!-- fc:xyz98765 -->
```

Tags go on the closing `:::` line.

### Multi-line Cards (Custom Delimiters)

````markdown
???
Explain the difference between `let` and `const` in JavaScript.
---
- `let`: Block-scoped, can be reassigned
- `const`: Block-scoped, cannot be reassigned

```javascript
let x = 1;
x = 2; // OK

const y = 1;
y = 2; // Error!
```
#javascript
???
````

## Tags

Tags use `/` for hierarchy:
- `#math` - Top-level tag
- `#math/calc` - Sub-tag of math
- `#math/algebra` - Another sub-tag

Reviewing `#math` includes all `#math/*` cards.

Cards also inherit tags from their file path:
- `notes/programming/python.md` → implicit `#programming/python`

## Commands

| Command | Description |
|---------|-------------|
| `:FlashcardsReview` | Start review session (shows tag picker with due counts) |
| `:FlashcardsReview #tag` | Review cards with specific tag (supports Tab completion) |
| `:FlashcardsScan` | Scan directories for cards |
| `:FlashcardsStats` | Show statistics |
| `:FlashcardsBrowse` | Browse cards (Telescope) |
| `:FlashcardsDue` | Show due cards (Telescope) |
| `:FlashcardsTags` | Browse by tags (Telescope) |
| `:FlashcardsInit` | Initialize in current directory |

### Tag Picker

Running `:FlashcardsReview` without arguments opens a tag picker that shows:
- Due count for each tag (how many cards need review now)
- Total card count per tag
- Tags sorted by due count (most urgent first)

```
Select tag to review:
> All cards (5 cards due)
  #math (3 cards due)
  #programming (2 cards due)
  #history (0 cards due)
```

Use Tab completion with `:FlashcardsReview #` to quickly filter by tag.

## Review Keybindings

| Key | Action |
|-----|--------|
| `Space` | Show answer |
| `1` or `y` | Correct (knew it) |
| `2` or `n` | Wrong (didn't know) |
| `s` | Skip card |
| `u` | Undo last answer |
| `e` | Edit card source |
| `q` or `Esc` | Quit session |

## Configuration

```lua
require("flashcards").setup({
    -- Directories to scan for cards
    directories = { "~/notes" },

    -- Database location (pick one):
    -- Option 1: Directory path (db_filename will be appended)
    db_path = "~/notes/assets/",
    -- Option 2: Full file path
    -- db_path = "~/.local/share/nvim/flashcards.db",
    -- Option 3: Leave nil, uses db_filename in each configured directory (default)
    -- db_path = nil,
    -- db_filename = ".flashcards.db",

    -- FSRS algorithm settings
    fsrs = {
        target_correctness = 0.85,  -- 85% target (0.7-0.95)
        maximum_interval = 365,      -- Max days between reviews
        enable_fuzz = true,          -- Spread reviews slightly
        weights = {
            learning_steps = { 1, 10, 60 }, -- Minutes: 1m, 10m, 1h
        },
    },

    -- UI settings
    ui = {
        width = 0.7,
        height = 0.6,
        border = "rounded",
        keymaps = {
            correct = "1",
            wrong = "2",
            quit = "q",
            skip = "s",
            undo = "u",
            edit = "e",
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

## How It Works

### Card Tracking

Cards are identified by a unique ID stored as a markdown comment (e.g., `<!-- fc:abc12345 -->`):

- **IDs are auto-generated** - When you scan, new cards get IDs written to the source file
- **Edit freely** - Change the front/back content without losing review history
- **Stable identity** - As long as the ID comment stays, the card keeps its progress
- **Git-friendly** - IDs are visible in your notes and sync naturally

By default, the database is stored in your notes directory (`.flashcards.db`) so you can sync it with git across devices. Alternatively, set `db_path` to store the database in a custom location (e.g., `~/.local/share/nvim/flashcards.db`).

### Learning Phase

New cards go through a learning phase with short intervals (1 min → 10 min → 1 hour by default) before graduating to the regular review schedule. During a session:

- **New cards** may reappear within the same session if due within 30 minutes
- This is intentional - it helps you learn new material before spacing it out
- Once a card "graduates," it follows the longer spaced repetition schedule

### Spaced Repetition

The algorithm adjusts intervals based on your answers:
- **Correct**: Interval increases (card becomes easier)
- **Wrong**: Card returns to learning phase with short intervals

Target retention is configurable (default 85%) - higher targets mean shorter intervals.

## Telescope Integration

```lua
-- In your telescope config
require("telescope").load_extension("flashcards")
```

Then use:
- `:Telescope flashcards` or `:Telescope flashcards browse`
- `:Telescope flashcards due`
- `:Telescope flashcards tags`
- `:Telescope flashcards search`

## License

MIT

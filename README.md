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

4. Use `1` for Wrong, `2` for Correct (or `n`/`y`)

## Card Syntax

### Inline Cards

```markdown
Question text :: Answer text #tag1 #tag2
```

### Multi-line Cards (Fenced)

````markdown
```card
What does this function do?
---
It reverses a string using recursion:

```python
def reverse(s):
    if len(s) <= 1:
        return s
    return reverse(s[1:]) + s[0]
```
#python #recursion
```
````

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
| `:FlashcardsReview` | Start review session |
| `:FlashcardsReview #tag` | Review cards with specific tag |
| `:FlashcardsScan` | Scan directories for cards |
| `:FlashcardsStats` | Show statistics |
| `:FlashcardsBrowse` | Browse cards (Telescope) |
| `:FlashcardsDue` | Show due cards (Telescope) |
| `:FlashcardsTags` | Browse by tags (Telescope) |
| `:FlashcardsInit` | Initialize in current directory |

## Review Keybindings

| Key | Action |
|-----|--------|
| `Space` | Show answer |
| `1` or `n` | Wrong (didn't know) |
| `2` or `y` | Correct (knew it) |
| `s` | Skip card |
| `u` | Undo last answer |
| `e` | Edit card source |
| `q` or `Esc` | Quit session |

## Configuration

```lua
require("flashcards").setup({
    -- Directories to scan for cards
    directories = { "~/notes" },

    -- Database is stored in the first directory for easy git sync
    db_filename = ".flashcards.db",

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
            wrong = "1",
            correct = "2",
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

## How Card Tracking Works

Cards are identified by a hash of their content (file path + front + back). This means:
- **Same content = same card** - Progress is preserved
- **Content changes = new card** - If you edit a card significantly, it becomes a new card

This design keeps the system simple and predictable. The database is stored in your notes directory (`.flashcards.db`) so you can sync it with git across devices.

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

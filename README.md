# nvim-flashcards

A Neovim plugin for markdown-based spaced repetition flashcards using a simplified FSRS algorithm with binary ratings (Wrong/Correct).

## Features

- **Markdown-based cards** - Define flashcards directly in your notes
- **Binary rating system** - Simple Wrong/Correct rating
- **Adjustable target correctness** - Set your target retention rate (default 85%)
- **FSRS-inspired algorithm** - Modern spaced repetition scheduling
- **Hierarchical tags** - `#math/calc`, `#math/algebra` with parent inheritance
- **Named tag scopes** - Apply tags to blocks of cards without repeating yourself
- **Multi-line support** - Code blocks, lists, and complex formatting preserved
- **Reversible cards** - Cards that can quiz you in either direction
- **Telescope integration** - Browse, search, and filter cards
- **Orphan management** - Soft-delete lost cards, reactivate or purge them
- **JSON storage** - Human-readable data file you can manually inspect and edit
- **Auto-sync** - Cards update on file save

## Requirements

- Neovim >= 0.9.0
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) (optional, for syntax highlighting in review window)

## Installation

### lazy.nvim

```lua
{
    "yo-reign/nvim-flashcards",
    dependencies = {
        "nvim-lua/plenary.nvim",
        "MunifTanjim/nui.nvim",
        "nvim-telescope/telescope.nvim",
    },
    config = function()
        require("flashcards").setup({
            directories = { "~/notes/flashcards/" },
            storage = "json",
            db_path = "~/notes/assets/",
            fsrs = {
                target_correctness = 0.85,
            },
        })

        vim.keymap.set("n", "<leader>fcr", ":FlashcardsReview<CR>", { desc = "Review flashcards" })
        vim.keymap.set("n", "<leader>fcs", ":FlashcardsScan<CR>", { desc = "Scan for new flashcards" })
        vim.keymap.set("n", "<leader>fcb", ":FlashcardsBrowse<CR>", { desc = "Browse flashcards" })
        vim.keymap.set("n", "<leader>fct", ":FlashcardsTags<CR>", { desc = "Browse flashcard tags" })
        vim.keymap.set("n", "<leader>fcd", ":FlashcardsDue<CR>", { desc = "Browse due flashcards" })
        vim.keymap.set("n", "<leader>fcS", ":FlashcardsStats<CR>", { desc = "Show flashcard stats" })
        vim.keymap.set("n", "<leader>fco", ":FlashcardsOrphans<CR>", { desc = "Manage orphaned cards" })
    end,
}
```

## Quick Start

1. Add card syntax to your markdown files (see Card Syntax below)

2. Scan for cards:
   ```
   :FlashcardsScan
   ```

3. Start a review session:
   ```
   :FlashcardsReview
   ```

4. Rate cards: `1` = Wrong, `2` = Correct (or `n`/`y`)

## Card Syntax

### Inline Cards

```markdown
Question text ::: Answer text #tag1 #tag2
```

After scanning, an ID comment is automatically added:
```markdown
Question text ::: Answer text #tag1 #tag2 <!-- fc:abc12345 -->
```

### Reversible Cards

Use `:?:` instead of `:::` for cards that can be shown in either direction (50% chance):

```markdown
Term :?: Definition #vocabulary
```

A `↔` indicator shows in the review header when a card is reversed.

### Multi-line Cards (Fenced)

Use `:::card` / `:::end` fences with `:-:` separating front from back:

```markdown
:::card
What does this function do?

` ``python
def reverse(s):
    if len(s) <= 1:
        return s
    return reverse(s[1:]) + s[0]
` ``
:-:
It reverses a string using recursion.
:::end #python #recursion
```

After scanning, an ID is added to the opening line:
```markdown
:::card <!-- fc:xyz98765 -->
```

Tags go on the closing `:::end` line.

### Reversible Multi-line Cards

Use `:?:card` / `:?:end` for reversible fenced cards:

```markdown
:?:card
Term or concept here
:-:
Definition or explanation here
:?:end #vocabulary
```

### Source Annotations

Add a note on the line after a card to record its source:

```markdown
What is the quadratic formula? ::: x = (-b +/- sqrt(b^2 - 4ac)) / 2a #math
<!-- note: Serge Lang Ch.1 p.12 -->
```

Notes are shown as footnotes during review when `config.ui.show_note = true`.

### Suspended Cards

Add `!suspended` to a card's ID comment to exclude it from reviews:

```markdown
What is X? ::: Y <!-- fc:abc12345 !suspended -->
```

Suspended cards are still visible when browsing but never appear in review sessions.

### Template Variables

Template variables expand at parse time, useful in tag scopes and notes:

- `{{file.name}}` - filename without extension
- `{{file.dir}}` - parent directory name
- `{{file.path}}` - relative path from scan root, no extension

```markdown
:#{{file.dir}}/{{file.name}}:
<!-- note: {{file.name}} (1.2.3:5) -->
```

## Tags

Tags use `/` for hierarchy:
- `#math` - Top-level tag
- `#math/calc` - Sub-tag
- Reviewing `#math` includes all `#math/*` cards

### Tag Scopes

Use `:#tag:` to apply a tag to a block of cards. Close with `:#/tag:`:

```markdown
:#python:

What is a list? ::: An ordered, mutable collection
What is a dict? ::: A key-value mapping

:#/python:
```

Both cards get the `#python` tag. Scopes are nestable with named closes:

```markdown
:#python:
:#decorators:

What is @property? ::: A decorator that creates a managed attribute

:#/decorators:

What is a generator? ::: A function that yields values lazily

:#/python:
```

The first card gets `#python` and `#python/decorators` (nested scopes build hierarchical tags). The second card gets only `#python`. Inline tags are also nested under the current scope — `#extra` inside `:#python:` becomes `#python/extra`.

## Commands

| Command | Description |
|---------|-------------|
| `:FlashcardsReview [tag]` | Start review session, optionally filtered by tag |
| `:FlashcardsScan` | Scan directories for new/changed cards |
| `:FlashcardsStats` | Show statistics dashboard |
| `:FlashcardsBrowse` | Browse all cards (Telescope) |
| `:FlashcardsDue` | Browse due cards (Telescope) |
| `:FlashcardsTags` | Browse by tag hierarchy (Telescope) |
| `:FlashcardsOrphans` | Manage orphaned/lost cards (Telescope) |

## Review Keybindings

| Key | Action |
|-----|--------|
| `Space` | Show answer |
| `1` or `n` | Wrong |
| `2` or `y` | Correct |
| `s` | Skip card |
| `u` | Undo last answer |
| `e` | Edit card source file |
| `q` or `Esc` | Quit session |

## Configuration

```lua
require("flashcards").setup({
    -- Directories to scan for cards
    directories = { "~/notes/flashcards/" },

    -- Storage backend: "json" (default)
    -- SQLite backend planned for future release
    storage = "json",

    -- Where to store the data file
    -- Directory path: appends "flashcards.json" automatically
    -- File path: used as-is
    -- nil: uses first configured directory
    db_path = "~/notes/assets/",

    -- File patterns to scan
    file_patterns = { "*.md", "*.markdown" },

    -- Directories/patterns to ignore during scan
    ignore_patterns = { "node_modules", ".git", ".obsidian", ".trash" },

    -- FSRS algorithm settings
    fsrs = {
        target_correctness = 0.85,  -- 0.7-0.97, higher = more reviews
        maximum_interval = 365,
        enable_fuzz = true,
        weights = {
            initial_stability_correct = 3.0,
            initial_stability_wrong = 0.5,
            learning_steps = { 1, 10, 60 }, -- minutes
        },
    },

    -- UI settings
    ui = {
        width = 0.7,
        height = 0.6,
        border = "rounded",
        show_note = true, -- show source annotations during review
        keymaps = {
            show_answer = "<Space>",
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

    -- Auto-sync cards when markdown files are saved
    auto_sync = true,
})
```

## How It Works

### Card Tracking

Cards are identified by unique IDs stored as markdown comments (`<!-- fc:abc12345 -->`):

- **IDs are auto-generated** when you scan - new cards get IDs written back to the source file
- **Edit freely** - change card content without losing review history
- **Stable identity** - as long as the ID comment stays, the card keeps its progress
- **Git-friendly** - IDs are visible in your notes and sync naturally

### Storage

Card state is stored in a human-readable JSON file (`flashcards.json`). You can inspect and manually edit it. The file location is controlled by `db_path` in your config.

A SQLite backend is planned for a future release, which will offer better performance for large collections (thousands of cards).

### Orphan Management

When a card's ID disappears from your files (deleted, moved outside scan dirs), it becomes "orphaned":

- The card is **soft-deleted** (`active: false`) - review history is preserved
- If the same ID reappears later, the card is **automatically reactivated**
- Use `:FlashcardsOrphans` to permanently delete or manually reactivate orphaned cards

### Learning Phase

New cards go through learning steps (1min, 10min, 1hour by default) before graduating to the regular review schedule. During a session, learning cards may reappear if due within 30 minutes.

### Spaced Repetition

The FSRS-inspired algorithm adjusts intervals based on your answers:
- **Correct**: interval increases, difficulty decreases slightly
- **Wrong**: card returns to learning phase with short intervals

Target retention is configurable (default 85%) - higher targets mean shorter intervals and more reviews.

## Telescope Integration

Pickers are registered automatically during setup. You can also load them explicitly:

```lua
require("telescope").load_extension("flashcards")
```

Then use:
- `:Telescope flashcards browse`
- `:Telescope flashcards due`
- `:Telescope flashcards tags`
- `:Telescope flashcards search`
- `:Telescope flashcards orphans`

## Health Check

Run `:checkhealth flashcards` to verify dependencies and configuration.

## License

MIT

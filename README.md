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
- **Source refs** - Leading section prefixes like `(1.2.3:5)` render as review footnotes
- **Local media** - Show diagrams and play pronunciation/audio files from cards
- **Telescope integration** - Browse, search, and filter cards
- **Orphan management** - Soft-delete lost cards, reactivate or purge them
- **SQLite storage** - ACID transactions, rollback journaling, foreign keys, and integrity checks for durable review history
- **Auto-sync** - Cards update on file save

## Requirements

- Neovim >= 0.9.0
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) (optional, for syntax highlighting in review window)
- [3rd/image.nvim](https://github.com/3rd/image.nvim) plus its backend/ImageMagick requirements (optional, for inline images)
- `mpv`, `ffplay`, `afplay`, or `paplay` (optional, for controlled audio playback)
- SQLite runtime library (`libsqlite3`; available by default on macOS and most Linux distributions)

## Installation

### lazy.nvim

```lua
{
    "yo-reign/nvim-flashcards",
    dependencies = {
        "nvim-lua/plenary.nvim",
        "MunifTanjim/nui.nvim",
        "nvim-telescope/telescope.nvim",
        {
            "3rd/image.nvim",
            -- magick_cli uses the system ImageMagick executable, so the
            -- optional Lua `magick` rock build is unnecessary.
            build = false,
            opts = {
                backend = "kitty", -- or "sixel" / "ueberzug"
                processor = "magick_cli",
                -- Flashcards uses the direct API and owns float cleanup.
                integrations = {
                    markdown = { enabled = false },
                },
            },
        },
    },
    config = function()
        require("flashcards").setup({
            directories = { "~/notes/flashcards/" },
            -- SQLite is the only supported backend.
            storage = "sqlite",
            db_path = "~/notes/assets/",
            media = {
                enabled = true,
                -- Optional extra roots; scan directories are already allowed.
                roots = {},
            },
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

4. Rate cards: `0` = Wrong, `1` = Correct (or `n`/`y`)

## Card Syntax

### Inline Cards

```markdown
Question text ::: Answer text #tag1 #tag2
```

Spaces around `:::` / `:?:` are optional; front/back text is trimmed during parsing and display.

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

### Source References

Prefix a card front with a textbook/source location to record where it came from. Numeric section references are recognized directly:

```markdown
(1.2.3:5) What is the quadratic formula? ::: x = (-b +/- sqrt(b^2 - 4ac)) / 2a #math
```

For other source descriptions, use the explicit `ref:` marker. This avoids treating ordinary prompt text such as `(True/False)` as metadata:

```markdown
(ref: Lang, Algebra I, §2) What does the theorem say? ::: It says ... #math
```

For fenced cards, put either form at the start of the front:

```markdown
:::card
(1.2.3:5-7) What does the theorem say?
:-:
It says ...
:::end #math
```

The prefix stays in your markdown file, but review/search stores the cleaned front (`What is the quadratic formula?`) and shows the source ref as a footnote when `config.ui.show_note = true`.

Legacy `<!-- note: ... -->` comments are still parsed for existing cards. Existing free-form parenthesized refs that were already stored as notes remain compatible when their source files are rescanned; use `(ref: ...)` for new ones.

### Images and Audio

Media remains ordinary Markdown and is stored as part of the card text. Media
references may be placed on their own line or appended to prose; the review UI
moves each recognized item to its own placeholder/render row so an image cannot
cover the surrounding text. Fenced cards are recommended for media-heavy cards:

```markdown
:::card
Which structure is highlighted?

![Plant cell](assets/plant-cell.png)
:-:
A chloroplast.

[Play pronunciation](audio/chloroplast.mp3)
:::end #biology
```

- Images use standard Markdown image syntax: `![label](relative/path.png)`.
- Audio uses a standard Markdown link whose target ends in a configured audio
  extension: `[label](relative/path.mp3)`.
- Paths are resolved relative to the Markdown source file, not Neovim's current
  directory. Explicit home paths such as `~/notes/assets/dice.png` are also
  supported when they remain inside an allowed root. Paths containing spaces
  must use `<...>`, such as `![Cell](<assets/cell diagram.png>)`.
- Media is local-only and must remain inside a configured flashcard directory or
  an explicitly configured `media.roots` directory. Remote URLs are rejected.
- Question-side media is available immediately. Answer-side files are not
  resolved, rendered, or played until the answer is revealed.
- Audio never autoplays. Press `p` to play/replay the preferred visible audio
  and `o` to open visible media with the platform handler.

Inline image display uses the optional
[`3rd/image.nvim`](https://github.com/3rd/image.nvim) direct API. Configure its
Kitty, Sixel, or Überzug++ backend separately. Without it, the review window
keeps a readable image placeholder and `o` can open the file externally. Audio
players are auto-detected in this order: `mpv`, `ffplay`, `afplay`, `paplay`.
Telescope previews remain text/Markdown-only.

The lazy.nvim installation example above includes `3rd/image.nvim`. Its
Markdown integration is disabled because nvim-flashcards uses the direct API
and owns image placement and cleanup inside its floating review window.
`build = false` skips the unnecessary Lua `magick` rock because `magick_cli`
uses the system ImageMagick executable. On macOS install the system tools with:

```sh
# Recommended image conversion and audio playback
brew install imagemagick mpv

# Optional alternative audio player (provides ffplay)
brew install ffmpeg

# Only if :checkhealth flashcards cannot find the macOS SQLite runtime
brew install sqlite
```

`mpv` is optional but recommended for consistent audio-format support. Ghostty
can use the configured Kitty graphics backend directly; the Überzug++ package
is not needed for that setup.

### Suspended Cards

Add `!suspended` to a card's ID comment to exclude it from reviews:

```markdown
What is X? ::: Y <!-- fc:abc12345 !suspended -->
```

Suspended cards are still visible when browsing but never appear in review sessions.

### Template Variables

Template variables expand at parse time, useful in tag scopes:

- `{{file.name}}` - filename without extension
- `{{file.dir}}` - parent directory name
- `{{file.path}}` - relative path from scan root, no extension

```markdown
:#{{file.dir}}/{{file.name}}:

(1.2.3:5) What is the quadratic formula? ::: x = (-b +/- sqrt(b^2 - 4ac)) / 2a

:#/math/algebra:
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
| `0` or `n` | Wrong |
| `1` or `y` | Correct |
| `s` | Skip card |
| `u` | Undo last answer |
| `e` | Edit card source file |
| `p` | Play/replay visible card audio |
| `o` | Open visible media externally |
| `q` or `Esc` | Quit session |

## Configuration

```lua
require("flashcards").setup({
    -- Directories to scan for cards
    directories = { "~/notes/flashcards/" },

    -- Storage backend: SQLite only (default)
    -- JSON storage has been removed to protect review history from
    -- whole-file corruption/truncation failures.
    storage = "sqlite",

    -- Where to store the database
    -- Directory path: appends "flashcards.db" automatically
    -- File path: used as-is (old .json paths are rewritten to .db)
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
        -- Cap first review after learning; false disables
        graduating_interval_days = 3,
        weights = {
            initial_stability_correct = 3.0,
            initial_stability_wrong = 0.5,
            learning_steps = { 1, 10, 60 }, -- minutes
        },
    },

    -- Local media. No media is copied into SQLite.
    media = {
        enabled = true,
        roots = {}, -- extra allowed roots; scan directories are always allowed
        images = {
            enabled = true,
            extensions = { "png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "svg" },
            max_width = 50,
            max_height = 18,
        },
        audio = {
            enabled = true,
            extensions = { "mp3", "wav", "ogg", "flac", "m4a", "aac", "opus" },
            -- false auto-detects a player. A custom value is an argv prefix,
            -- never a shell command string.
            player = false,
            -- player = { "mpv", "--no-video", "--really-quiet", "--" },
        },
    },

    -- UI settings
    ui = {
        width = 0.7,
        height = 0.6,
        border = "rounded",
        show_note = true, -- show source refs/notes during review
        keymaps = {
            show_answer = "<Space>",
            wrong = "0",
            correct = "1",
            quit = "q",
            skip = "s",
            undo = "u",
            edit = "e",
            play_audio = "p",
            open_media = "o",
        },
    },

    -- New-card policy: false is unlimited (default).
    -- Use a non-negative integer for a daily cap; 0 disables new cards.
    session = {
        new_cards_per_day = false,
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

Card state is stored in a SQLite database (`flashcards.db`). The backend uses SQLite rollback journaling, `synchronous=FULL`, foreign keys, per-operation transactions, and startup integrity checks so review history is committed durably instead of rewriting one fragile JSON file.

The database location is controlled by `db_path` in your config. If `db_path` is a directory, `flashcards.db` is created inside it.

### Existing SQLite databases

**Media upgrade:** no SQL migration, schema change, new table, or database
replacement is required. Image/audio references remain ordinary text in the
existing `cards.front` and `cards.back` columns and are resolved only while a
card is displayed. To upgrade safely:

1. Back up `flashcards.db` as a normal precaution.
2. Update the plugin and restart Neovim.
3. Keep the same `db_path`, scan directories, and every existing
   `<!-- fc:id -->` comment.
4. Add media Markdown to the source cards and run `:FlashcardsScan` once (or
   save the file with `auto_sync = true`).
5. Review any scan errors before continuing.

The existing ID-based upsert changes card text/path metadata while retaining the
same card row, FSRS state, due date, reviews, and daily statistics. Do not delete
or recreate the database, remove ID comments, or purge orphans as an upgrade
step. Media files themselves stay beside the notes and are never imported as
SQLite BLOBs, so the database remains fully compatible with older releases.

New scans also store each card's
canonical absolute source path so files with the same relative name in different
configured directories cannot collide. Existing root-relative rows are upgraded
**only** when the scanner finds the same `<!-- fc:id -->` in a source file; the
card ID, FSRS state, and review history are preserved. No bulk path rewrite is
performed because it could associate old records with the wrong root.

As with any database upgrade, back up `flashcards.db`, then run
`:FlashcardsScan` once after updating. Orphaned records whose source no longer
exists intentionally retain their old path as historical metadata.

**Upgrade from JSON:** remove `storage = "json"` from your config or change it
to `"sqlite"`. On first open, if the new empty database has a sibling legacy
JSON file (for example `flashcards.json` next to `flashcards.db`),
nvim-flashcards imports readable cards and reviews once and leaves the JSON
file untouched as a backup. If the JSON file is malformed, startup fails loudly
instead of silently creating an empty history.

### Orphan Management

When a card's ID disappears from your files (deleted or moved outside scan
roots), it becomes "orphaned":

- The card is **soft-deleted** (`active: false`) - review history is preserved
- If the same ID reappears later, the card is **automatically reactivated**
- Use `:FlashcardsOrphans` to permanently delete or manually reactivate
  orphaned cards

### Learning Phase

New cards go through learning steps (1min, 10min, 1hour by default) before
graduating to the regular review schedule. Future-due learning steps are never
shown early. While the review popup remains open, they stay pending and are
inserted a few cards ahead as soon as they become due. If the active queue ends
first, the popup waits and resumes automatically with a one-shot timer. Closing
the popup is always safe; persisted due dates make those cards available in a
later session.

### Spaced Repetition

The FSRS-inspired algorithm adjusts intervals based on your answers:

- **Correct**: interval increases, difficulty decreases slightly
- **Wrong**: card returns to learning phase with short intervals

Target retention is configurable (default 85%) - higher targets mean shorter
intervals and more reviews. The first interval after a new card graduates from
learning is capped by `graduating_interval_days` (default 3 days) to avoid an
overly large initial jump; set it to `false` to restore the old uncapped
behavior.

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

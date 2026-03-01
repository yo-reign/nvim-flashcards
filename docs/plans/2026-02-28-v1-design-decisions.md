# v1 Design Decisions

All decisions made during brainstorming session on 2026-02-28.

## Syntax

### Card Separators (unchanged from prototype)
- Inline normal: `front ::: back`
- Inline reversible: `front :?: back`
- Fenced normal open: `:::card`
- Fenced reversible open: `:?:card`
- Front/back separator: `:-:`

### Card Closing (CHANGED from prototype)
- Fenced normal close: `:::end #tags` (was `:::`)
- Fenced reversible close: `:?:end #tags` (was `:?:`)

### Tag Scopes (CHANGED from prototype)
- Open: `:#tagname:`
- Close: `:#/tagname:` (was `:#:` — ambiguous when nesting)
- Nestable: inner scopes stack, cards get all active scope tags
- Mismatched close = parse error reported to user

### Card IDs (unchanged)
- Format: `<!-- fc:abc12345 -->`
- 8-char alphanumeric
- Auto-generated on scan, written back to source file
- Plugin force-reloads buffers after write-back via `checktime`

### Source Annotations (NEW)
- Format: `<!-- note: freeform text here -->`
- Placed on line after a card
- Supports template variables
- Shown as footnote during review when `config.ui.show_note = true`

### Suspended Cards (NEW)
- Format: `<!-- fc:abc12345 !suspended -->`
- Excluded from all review/due queries
- Still visible in browse

### Template Variables (NEW)
- `{{file.name}}` — filename without extension
- `{{file.dir}}` — parent directory name
- `{{file.path}}` — relative path from scan root, no extension
- Expand at parse time in tag scopes and note annotations
- Enable opt-in file-based tags: `:#{{file.dir}}/{{file.name}}:`

## Tags
- **Manual only** — no automatic path-based tag generation
- Hierarchical with `/`: `#math/algebra`
- Querying `math` matches `math` and `math/*`
- Scoped tags merge with inline tags

## Storage
- **Configurable**: `storage = "json"` (default) or `storage = "sqlite"`
- JSON: human-readable `flashcards.json`, user can manually edit card data
- SQLite: better performance for large collections
- Both implement identical interface
- `db_path` config points to directory (filename auto-appended) or full file path

## Orphan Handling
- When a card's ID is not found during scan: `active = false`, `lost_at = timestamp`
- NOT deleted — review history preserved
- If same ID reappears later: reactivated automatically
- `:FlashcardsOrphans` command — Telescope picker to permanently delete or reactivate

## File/Directory Change Resilience
- Card inline ID is sole identity anchor
- File path is metadata, rebuilt on every scan
- Renames/moves detected by finding same ID at new path
- Template variables re-expand on scan (tags update automatically)

## Architecture
- Full ground-up rewrite (not incremental refactor)
- Clean slate for DB/storage (user chose to lose existing review history)
- Same module structure but cleaner: parser state machine, storage interface pattern
- Telescope consolidated to single file
- `storage/` subdirectory with init.lua factory + json.lua + sqlite.lua backends

## Commands
| Command | Action |
|---------|--------|
| `:FlashcardsReview [tag]` | Start review session |
| `:FlashcardsScan` | Rescan all directories |
| `:FlashcardsStats` | Show statistics dashboard |
| `:FlashcardsBrowse` | Telescope browse all cards |
| `:FlashcardsDue` | Telescope browse due cards |
| `:FlashcardsTags` | Telescope browse tags |
| `:FlashcardsOrphans` | Manage orphaned cards |

## FSRS
- Kept from prototype (well-tested, correct)
- Binary rating: Wrong=1, Correct=2
- States: New, Learning, Review, Relearning
- Configurable target_correctness (0.7-0.97, default 0.85)

## User Config Update Needed
- Add `storage = "json"` to setup call
- Add `<leader>fco` keymap for `:FlashcardsOrphans`
- Remove sqlite.lua from required deps (now optional)

## Files to Migrate (in ~/notes/flashcards/)
- Change `:::` closers to `:::end`
- Change `:?:` closers to `:?:end`
- Change `:#:` closers to named `:#/tagname:`

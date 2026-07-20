--- Local image and audio helpers for flashcard review content.
--- Media references remain ordinary Markdown stored in card front/back text;
--- this module only derives a transient render plan at review time.
--- @module flashcards.media
local M = {}

local utils = require("flashcards.utils")

local function trim(value)
  return utils.trim(value or "")
end

local function extension_set(extensions)
  local result = {}
  for _, extension in ipairs(extensions or {}) do
    result[extension:lower():gsub("^%.", "")] = true
  end
  return result
end

local function target_extension(target)
  return target:lower():match("%.([%w]+)$")
end

local function parse_target(raw_target)
  local expression = trim(raw_target)
  local target, title
  if expression:sub(1, 1) == "<" then
    target, title = expression:match("^<([^>]*)>%s*(.*)$")
    if not target then
      return nil, "invalid angle-bracket media path"
    end
  else
    target, title = expression:match("^(%S+)%s*(.*)$")
  end

  target = trim(target)
  title = trim(title)
  if target == "" then
    return nil, "empty media path"
  end
  if title ~= ""
    and not title:match('^"[^"]*"$')
    and not title:match("^'[^']*'$")
    and not title:match("^%([^%)]*%)$") then
    return nil, "invalid Markdown media title"
  end
  return target
end

local function is_remote_or_special(target)
  if target:find("\0", 1, true) then
    return true
  end
  -- Keep Windows drive letters local, but reject every URI/data scheme.
  return target:match("^%a[%w+.-]*:") ~= nil and target:match("^%a:[/\\]") == nil
end

local function allowed_roots(directories, extra_roots)
  local roots = {}
  local seen = {}
  for _, collection in ipairs({ directories or {}, extra_roots or {} }) do
    for _, root in ipairs(collection) do
      local canonical = utils.canonical_path(root)
      if not seen[canonical] then
        seen[canonical] = true
        roots[#roots + 1] = canonical
      end
    end
  end
  return roots
end

--- Resolve a local media target relative to the card's Markdown source file,
--- or expand an explicit `~/` target. Both the source file and resolved media
--- must remain inside configured roots.
--- @param target string Markdown link destination
--- @param card_file_path string canonical or legacy card source path
--- @param directories string[] configured flashcard directories
--- @param extra_roots string[]|nil extra explicitly permitted media roots
--- @return string|nil absolute_path
--- @return string|nil error_message
function M.resolve(target, card_file_path, directories, extra_roots)
  if type(target) ~= "string" or target == "" then
    return nil, "empty media path"
  end
  if is_remote_or_special(target) then
    return nil, "remote and special media URLs are not supported"
  end

  local is_home_path = target:sub(1, 2) == "~/"
  if utils.is_absolute_path(target) then
    return nil, "absolute media paths are not supported; use a relative or ~/ path"
  end

  local source_path = utils.resolve_card_path(card_file_path, directories)
  if not source_path then
    return nil, "cannot resolve card source file"
  end

  local source_dir = vim.fn.fnamemodify(source_path, ":h")
  local candidate = is_home_path and utils.normalize_path(target) or (source_dir .. "/" .. target)
  local canonical = utils.canonical_path(candidate)
  local inside_allowed_root = false
  for _, root in ipairs(allowed_roots(directories, extra_roots)) do
    if utils.is_subpath(canonical, root) then
      inside_allowed_root = true
      break
    end
  end
  if not inside_allowed_root then
    return nil, "media path is outside configured roots"
  end
  if vim.fn.filereadable(canonical) ~= 1 or vim.fn.getftype(canonical) ~= "file" then
    return nil, "media file is missing or unreadable"
  end

  return canonical
end

local function placeholder(kind, label, valid)
  local title = label ~= "" and label or kind
  if valid then
    if kind == "audio" then
      return string.format("[Audio: %s] (press p to play)", title)
    end
    return string.format("[Image: %s]", title)
  end
  return string.format("[%s unavailable: %s]", kind == "audio" and "Audio" or "Image", title)
end

local function fence_ticks(line)
  local ticks = line:match("^%s*(`+)")
  if ticks and #ticks >= 3 then
    return #ticks
  end
  return nil
end

local function closing_parenthesis(line, open_index)
  local depth = 1
  local quote = nil
  local escaped = false
  for index = open_index + 1, #line do
    local character = line:sub(index, index)
    if escaped then
      escaped = false
    elseif character == "\\" then
      escaped = true
    elseif quote then
      if character == quote then quote = nil end
    elseif character == '"' or character == "'" then
      quote = character
    elseif character == "(" then
      depth = depth + 1
    elseif character == ")" then
      depth = depth - 1
      if depth == 0 then return index end
    end
  end
  return nil
end

local function inside_inline_code(line, position)
  local open_ticks = nil
  local index = 1
  while index < position do
    if line:sub(index, index) == "`" then
      local run_end = index
      while line:sub(run_end + 1, run_end + 1) == "`" do
        run_end = run_end + 1
      end
      local run_length = run_end - index + 1
      if not open_ticks then
        open_ticks = run_length
      elseif run_length == open_ticks then
        open_ticks = nil
      end
      index = run_end + 1
    else
      index = index + 1
    end
  end
  return open_ticks ~= nil
end

local function extract_line_references(line, image_options, audio_options, image_extensions, audio_extensions)
  local references = {}
  local pieces = {}
  local search_index = 1
  local output_index = 1

  while search_index <= #line do
    local label_open = line:find("[", search_index, true)
    if not label_open then break end
    local is_image = label_open > 1 and line:sub(label_open - 1, label_open - 1) == "!"
    local token_start = is_image and (label_open - 1) or label_open
    local label_close = line:find("]", label_open + 1, true)
    local target_open = label_close and label_close + 1 or nil
    if not label_close or line:sub(target_open, target_open) ~= "(" then
      search_index = label_open + 1
    else
      local target_close = closing_parenthesis(line, target_open)
      if not target_close then
        break
      end

      local label = line:sub(label_open + 1, label_close - 1)
      local raw_target = line:sub(target_open + 1, target_close - 1)
      local target = parse_target(raw_target)
      local extension = target and target_extension(target) or nil
      local kind = nil
      if not inside_inline_code(line, token_start) then
        if is_image and image_options.enabled ~= false and extension and image_extensions[extension] then
          kind = "image"
        elseif not is_image and audio_options.enabled ~= false and extension and audio_extensions[extension] then
          kind = "audio"
        end
      end

      if kind then
        pieces[#pieces + 1] = line:sub(output_index, token_start - 1)
        pieces[#pieces + 1] = " "
        references[#references + 1] = {
          kind = kind,
          label = trim(label),
          raw_target = raw_target,
        }
        output_index = target_close + 1
      end
      search_index = target_close + 1
    end
  end

  if #references == 0 then
    return line, references
  end
  pieces[#pieces + 1] = line:sub(output_index)
  return table.concat(pieces):gsub("%s+$", ""), references
end

--- Extract supported Markdown media references and build separate placeholders.
--- References may occupy a full line or appear alongside prose. Media inside
--- fenced or inline code is left untouched. A destination containing spaces
--- must use Markdown's `<path with spaces>` form.
--- @param content string visible card-side Markdown
--- @param card_file_path string card source path
--- @param directories string[] configured flashcard directories
--- @param options table media configuration
--- @return table plan { lines, images, audio, items }
function M.extract(content, card_file_path, directories, options)
  options = options or {}
  local plan = { lines = {}, images = {}, audio = {}, items = {} }
  if options.enabled == false then
    plan.lines = utils.lines(content)
    return plan
  end

  local image_options = options.images or {}
  local audio_options = options.audio or {}
  local image_extensions = extension_set(image_options.extensions)
  local audio_extensions = extension_set(audio_options.extensions)
  local active_fence = 0

  for _, line in ipairs(utils.lines(content)) do
    local ticks = fence_ticks(line)
    if ticks then
      if active_fence == 0 then
        active_fence = ticks
      elseif ticks >= active_fence then
        active_fence = 0
      end
      plan.lines[#plan.lines + 1] = line
    elseif active_fence > 0 then
      plan.lines[#plan.lines + 1] = line
    else
      local text, references = extract_line_references(
        line,
        image_options,
        audio_options,
        image_extensions,
        audio_extensions
      )
      if trim(text) ~= "" then
        plan.lines[#plan.lines + 1] = text
      end

      for _, reference in ipairs(references) do
        local target, parse_error = parse_target(reference.raw_target)
        local path, resolve_error
        if target then
          path, resolve_error = M.resolve(target, card_file_path, directories, options.roots)
        end
        local item = {
          kind = reference.kind,
          label = reference.label,
          target = target,
          path = path,
          error = parse_error or resolve_error,
          line = #plan.lines + 1,
        }
        plan.lines[#plan.lines + 1] = placeholder(
          reference.kind,
          reference.label ~= "" and reference.label or (target or "media"),
          path ~= nil
        )
        plan.items[#plan.items + 1] = item
        local bucket = reference.kind == "image" and plan.images or plan.audio
        bucket[#bucket + 1] = item
      end

      if trim(text) == "" and #references == 0 then
        plan.lines[#plan.lines + 1] = line
      end
    end
  end

  return plan
end

local function image_geometry(context, options)
  local padding = 2
  local window_width = context.width
  if not window_width and context.window then
    local ok, width = pcall(vim.api.nvim_win_get_width, context.window)
    if ok then window_width = width end
  end
  window_width = window_width or (options.max_width + (padding * 2))

  local width = math.max(1, math.min(options.max_width, window_width - (padding * 2)))
  local height = options.max_height
  local alignment = options.alignment or "center"
  local x = padding
  if alignment == "center" then
    x = math.max(padding, math.floor((window_width - width) / 2))
  elseif alignment == "right" then
    x = math.max(padding, window_width - width - padding)
  end
  return { x = x, width = width, height = height }
end

--- Render validated image records through optional 3rd/image.nvim.
--- @param images table[] records with absolute path and zero-based render row
--- @param context table { window, buffer, width? }
--- @param options table image configuration
--- @return table[] handles image objects that must later be cleared
--- @return string|nil error_message
function M.render_images(images, context, options)
  if not images or #images == 0 or not options or options.enabled == false then
    return {}
  end
  local ok, image_api = pcall(require, "image")
  if not ok then
    return {}, "image.nvim is not available"
  end

  local geometry = image_geometry(context, options)
  local handles = {}
  for _, item in ipairs(images) do
    if item.path then
      local created, image_or_error = pcall(image_api.from_file, item.path, {
        window = context.window,
        buffer = context.buffer,
        namespace = "nvim-flashcards",
        inline = true,
        with_virtual_padding = true,
        x = geometry.x,
        y = item.render_row or item.row,
        width = geometry.width,
        height = geometry.height,
      })
      if created and image_or_error then
        local rendered = pcall(function() image_or_error:render() end)
        if rendered then
          -- Keep the object even when image.nvim is still transforming it;
          -- its guarded callback will render later and this handle owns cleanup.
          handles[#handles + 1] = image_or_error
        else
          pcall(function() image_or_error:clear() end)
        end
      end
    end
  end
  return handles
end

--- Clear image.nvim objects idempotently.
--- @param handles table[]|nil
function M.clear_images(handles)
  for _, image in ipairs(handles or {}) do
    pcall(function() image:clear() end)
  end
end

local function executable(command)
  return type(command) == "string" and command ~= "" and vim.fn.executable(command) == 1
end

--- Return the configured or auto-detected audio argv prefix and display name.
--- @param options table audio configuration
--- @return string[]|nil argv_prefix
--- @return string|nil player_name
function M.audio_player(options)
  options = options or {}
  if type(options.player) == "table" and #options.player > 0 then
    if executable(options.player[1]) then
      return vim.deepcopy(options.player), options.player[1]
    end
    return nil, options.player[1]
  end

  local candidates = {
    { name = "mpv", argv = { "mpv", "--no-video", "--no-terminal", "--really-quiet", "--" } },
    { name = "ffplay", argv = { "ffplay", "-nodisp", "-autoexit", "-loglevel", "error" } },
    { name = "afplay", argv = { "afplay" } },
    { name = "paplay", argv = { "paplay" } },
  }
  for _, candidate in ipairs(candidates) do
    if executable(candidate.argv[1]) then
      return candidate.argv, candidate.name
    end
  end
  return nil, nil
end

--- Start one validated audio file without invoking a shell.
--- @param item table media record
--- @param options table audio configuration
--- @param on_exit function|nil receives job_id and exit_code
--- @return number|nil job_id
--- @return string|nil error_message
function M.play_audio(item, options, on_exit)
  if not item or not item.path then
    return nil, (item and item.error) or "no playable audio on the visible card side"
  end
  local prefix, name = M.audio_player(options)
  if not prefix then
    return nil, name and ("configured audio player is unavailable: " .. name) or "no supported audio player found"
  end

  local argv = vim.deepcopy(prefix)
  argv[#argv + 1] = item.path
  local job_id = vim.fn.jobstart(argv, {
    detach = false,
    on_exit = function(id, code)
      if on_exit then
        on_exit(id, code)
      end
    end,
  })
  if type(job_id) ~= "number" or job_id <= 0 then
    return nil, "failed to start audio player"
  end
  return job_id
end

--- Stop a playback job if it is still active.
--- @param job_id number|nil
function M.stop_audio(job_id)
  if type(job_id) == "number" and job_id > 0 then
    pcall(vim.fn.jobstop, job_id)
  end
end

local function fallback_opener()
  if vim.fn.has("mac") == 1 and executable("open") then
    return { "open" }
  end
  if vim.fn.has("unix") == 1 and executable("xdg-open") then
    return { "xdg-open" }
  end
  return nil
end

--- Open validated media with the platform handler. This is always explicit;
--- unavailable audio/image adapters never launch external applications alone.
--- @param item table media record
--- @return boolean ok
--- @return string|nil error_message
function M.open_external(item)
  if not item or not item.path then
    return false, (item and item.error) or "no local media available"
  end

  if vim.ui and type(vim.ui.open) == "function" then
    local called, process_or_error, open_error = pcall(vim.ui.open, item.path)
    if not called then
      return false, tostring(process_or_error)
    end
    if open_error then
      return false, tostring(open_error)
    end
    return true
  end

  local argv = fallback_opener()
  if not argv then
    return false, "no platform media opener is available"
  end
  argv[#argv + 1] = item.path
  local job_id = vim.fn.jobstart(argv, { detach = true })
  if type(job_id) ~= "number" or job_id <= 0 then
    return false, "failed to open media"
  end
  return true
end

--- Return optional runtime capability information for :checkhealth.
--- @param options table media configuration
--- @return table
function M.capabilities(options)
  local image_ok = pcall(require, "image")
  local player_argv, player_name = M.audio_player((options and options.audio) or {})
  return {
    image_nvim = image_ok,
    audio_player = player_argv and player_name or nil,
    requested_audio_player = player_name,
    external_open = (vim.ui and type(vim.ui.open) == "function") or fallback_opener() ~= nil,
  }
end

return M

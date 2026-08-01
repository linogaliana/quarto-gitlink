--- @module gitlink
--- @license MIT
--- @copyright 2026 Mickaël Canouil
--- @author Mickaël Canouil

--- Extension name constant
local EXTENSION_NAME = 'gitlink'

--- Load modules
local str = require(quarto.utils.resolve_path('_modules/string.lua'):gsub('%.lua$', ''))
local log = require(quarto.utils.resolve_path('_modules/logging.lua'):gsub('%.lua$', ''))
local meta_mod = require(quarto.utils.resolve_path('_modules/metadata.lua'):gsub('%.lua$', ''))
local html_mod = require(quarto.utils.resolve_path('_modules/html.lua'):gsub('%.lua$', ''))
local paths = require(quarto.utils.resolve_path('_modules/paths.lua'):gsub('%.lua$', ''))
local git = require(quarto.utils.resolve_path('_modules/git.lua'):gsub('%.lua$', ''))
local bitbucket = require(quarto.utils.resolve_path('_modules/bitbucket.lua'):gsub('%.lua$', ''))
local platforms = require(quarto.utils.resolve_path('_modules/platforms.lua'):gsub('%.lua$', ''))
local colour = require(quarto.utils.resolve_path('_modules/colour.lua'):gsub('%.lua$', ''))
local widget = require(quarto.utils.resolve_path('_modules/widget.lua'):gsub('%.lua$', ''))
local icons = require(quarto.utils.resolve_path('_modules/icons.lua'):gsub('%.lua$', ''))

--- @type string The platform type (github, gitlab, codeberg, gitea, bitbucket)
local platform = 'github'

--- @type string|nil The repository name (e.g., "owner/repo")
local repository_name = nil

--- @type string|nil GitLab group (optionally with subgroups, e.g. "group/subgroup")
--- that relative project references such as "subgroup/project#123" are
--- resolved against.
local group_name = nil

--- @type string The base URL for the Git hosting platform
local base_url = 'https://github.com'

--- @type table<string, boolean> Set of reference IDs from the document
local references_ids_set = {}

--- @type table<string, boolean> Set of citation IDs forced to be treated as mentions
local force_mentions_set = {}

--- @type boolean Whether the filter is enabled for this document
local is_enabled = true

--- @type boolean Whether to show visible platform badges
local show_platform_badge = true

--- @type string Badge position: "after" or "before"
local badge_position = 'after'

--- @type string Badge background colour (hex or colour name)
local badge_background_colour = '#c3c3c3'

--- @type string|nil Badge text colour (hex or colour name)
local badge_text_colour = nil

--- @type boolean Whether to shorten link text matching platform URLs
local normalize_links = true

--- @type boolean Whether to fetch issue/PR/commit titles for link text
local fetch_titles = false

--- @type table<string, string> Cache of fetched titles by URL
local title_cache = {}

--- @type boolean Whether to fetch issue/merge request open/closed/merged status
local fetch_status = false

--- @type table<string, table|false> Cache of fetched {label, class} status by API URL; false means "fetched, unavailable"
local status_cache = {}

--- @type table<string, table> Display label and CSS class for each known platform state value
local STATUS_STATE_LABELS = {
  opened = { label = 'Open', class = 'open' },
  open = { label = 'Open', class = 'open' },
  closed = { label = 'Closed', class = 'closed' },
  merged = { label = 'Merged', class = 'merged' },
  locked = { label = 'Locked', class = 'locked' },
}

--- @type table<string, table|false> Cached platform configurations by name (per render); false means "looked up and not found"
local platform_config_cache = {}

--- @type table<integer, string>|nil Cached list of all known platform names (per render)
local all_platform_names_cache = nil

--- @type integer Full length of a git commit SHA
local COMMIT_SHA_FULL_LENGTH = 40

--- @type integer Short length for displaying commit SHA
local COMMIT_SHA_SHORT_LENGTH = 7

--- @type integer Minimum length for a valid git commit SHA
local COMMIT_SHA_MIN_LENGTH = 7

--- @type string Lua pattern matching a 3-, 4-, 6-, or 8-character hex colour with leading #
local HEX_COLOUR_PATTERN = '^#%x%x%x%x?%x?%x?%x?%x?$'

--- @type string Null device for the shell `io.popen` spawns into: `NUL` on
--- Windows (`cmd.exe` errors out on the Unix `/dev/null` path), `/dev/null`
--- elsewhere. `package.config`'s first line is Lua's own directory separator,
--- a reliable OS check without shelling out.
local NULL_DEVICE = package.config:sub(1, 1) == '\\' and 'NUL' or '/dev/null'

--- Validate a colour value as a hex code or CSS named colour.
--- Returns the original value if valid, or nil if invalid.
--- @param value string|nil The candidate colour value
--- @param option_label string The metadata option name (for warnings)
--- @return string|nil The validated colour value, or nil if invalid
local function validate_colour(value, option_label)
  if str.is_empty(value) then
    return nil
  end
  local s = value --[[@as string]]
  if s:match(HEX_COLOUR_PATTERN) or colour.is_named_colour(s) then
    return s
  end
  log.log_warning(
    EXTENSION_NAME,
    "Ignoring invalid '" .. option_label .. "' value '" .. s ..
    "': expected a hex colour (e.g. '#c3c3c3') or a CSS named colour."
  )
  return nil
end

--- Convert a validated colour value to its hex form for Typst rgb().
--- Hex codes are returned unchanged; CSS named colours are resolved via
--- the colour module. Assumes the value has already been validated.
--- @param value string The colour value (hex code or CSS named colour)
--- @return string The hex form
local function colour_to_hex(value)
  if value:match(HEX_COLOUR_PATTERN) then
    return value
  end
  return colour.named_to_HTML(value)
end

--- Read a boolean metadata value with a default.
--- Reads the raw value rather than going through `get_metadata_value()`, so a
--- boolean, a quoted string, and a bare YAML `false` all resolve the same way.
--- @param gitlink_meta table|nil The `extensions.gitlink` metadata sub-table
--- @param key string The option key
--- @param default boolean The default when the option is absent
--- @return boolean The resolved boolean value
local function read_boolean_meta(gitlink_meta, key, default)
  local value = gitlink_meta and gitlink_meta[key]
  if value == nil then
    return default
  end
  return str.stringify(value):lower() ~= 'false'
end

--- Reset all module-level state to defaults.
--- Quarto can render multiple documents in one process, so module-level state
--- from a previous document must be cleared at the start of each Meta pass.
local function reset_state()
  platform = 'github'
  repository_name = nil
  group_name = nil
  base_url = 'https://github.com'
  references_ids_set = {}
  force_mentions_set = {}
  is_enabled = true
  show_platform_badge = true
  badge_position = 'after'
  badge_background_colour = '#c3c3c3'
  badge_text_colour = nil
  normalize_links = true
  fetch_titles = false
  title_cache = {}
  fetch_status = false
  status_cache = {}
  platform_config_cache = {}
  all_platform_names_cache = nil
  if platforms.clear_custom_platforms then
    platforms.clear_custom_platforms()
  end
  -- Dependency tracking is per document; without a reset, dependencies added
  -- for a previous document in the same process would be skipped here.
  html_mod.reset_dependencies()
end

--- Get the cached list of all known platform names.
--- @return table<integer, string> List of platform names
local function get_all_platform_names()
  if not all_platform_names_cache then
    all_platform_names_cache = platforms.get_all_platform_names()
  end
  return all_platform_names_cache
end

--- Get platform configuration (cached per render).
--- Memoises lookups against `platform_config_cache` to avoid repeated calls
--- to the platforms module for every Str element in the document.
--- The cache stores `false` for "looked up and not found" so repeated misses
--- skip the underlying lookup.
--- @param platform_name string The platform name
--- @return table|nil The platform configuration or nil if not found
local function get_platform_config(platform_name)
  if not platform_name then
    return nil
  end
  local key = platform_name:lower()
  local cached = platform_config_cache[key]
  if cached ~= nil then
    return cached or nil
  end
  local config = platforms.get_platform_config(key)
  platform_config_cache[key] = config or false
  return config
end

--- Parse a full repository URL to extract platform, base-url, and owner/repo.
--- Matches the URL against all known platform base URLs.
--- @param url string The full repository URL (e.g., "https://github.com/owner/repo")
--- @return string|nil platform_name The matched platform name
--- @return string|nil matched_base_url The base URL portion
--- @return string|nil repo_path The owner/repo portion
local function parse_repo_url(url)
  local all_names = get_all_platform_names()
  for _, name in ipairs(all_names) do
    local config = get_platform_config(name)
    if config and config.base_url then
      local escaped = str.escape_pattern(config.base_url)
      local repo_path = url:match('^' .. escaped .. '/(.+)$')
      if repo_path then
        repo_path = repo_path:match('^([^%?#]+)') or repo_path
        repo_path = repo_path:gsub('%.git$', ''):gsub('/$', '')
        if not str.is_empty(repo_path) then
          return name, config.base_url, repo_path
        end
      end
    end
  end
  return nil, nil, nil
end

--- @type table<string, string> Hex colour for each status class, used by the Typst status box
local STATUS_STATE_COLOURS = {
  open = '#1f883d',
  closed = '#cf222e',
  merged = '#8250df',
  locked = '#57606a',
}

--- @type table<string, string> Octicon (or brand-icon) name for each platform's
--- HTML badge. Platforms without an entry keep the plain-text label.
local PLATFORM_ICON_NAMES = {
  github = 'mark-github',
  gitlab = 'gitlab',
}

--- @type table<string, table<string, string>> Octicon name for each
--- ref-type/status-class combination, GitHub-style (open issue vs. open
--- merge/pull request use different glyphs).
local STATUS_ICON_NAMES = {
  issue = {
    open = 'issue-opened',
    closed = 'issue-closed',
    locked = 'issue-locked',
    unknown = 'issue-opened',
  },
  merge_request = {
    open = 'git-pull-request',
    closed = 'git-pull-request-closed',
    merged = 'git-merge',
    locked = 'git-pull-request-locked',
    unknown = 'git-pull-request',
  },
}

--- Build the inline content for an HTML badge: an icon when one is known and
--- embeds successfully, otherwise the plain-text fallback.
--- @param icon_name string|nil The icon name to try (see `icons.get_icon`), or nil to always use text
--- @param fallback_text string The text to use when no icon is available
--- @return table content A one-element Pandoc inline list (RawInline SVG or Str) for the badge body
--- @return boolean is_icon Whether the content rendered as an icon
local function html_badge_content(icon_name, fallback_text)
  if icon_name then
    local svg = icons.render_icon_svg(icon_name, 14, EXTENSION_NAME)
    if svg then
      return { pandoc.RawInline('html', svg) }, true
    end
  end
  return { pandoc.Str(fallback_text) }, false
end

--- Create a link with platform label
--- @param text string|nil The link text
--- @param uri string|nil The URI
--- @param platform_name string|nil The platform name
--- @param status table|nil Optional {label, class} issue/merge request status (see `fetch_status_for`)
--- @return pandoc.Link|pandoc.Span|nil A Pandoc Link element with platform label or Span containing link and badge(s)
local function create_platform_link(text, uri, platform_name, status)
  if str.is_empty(uri) or str.is_empty(text) or str.is_empty(platform_name) then
    return nil
  end

  local platform_label = platforms.get_platform_display_name(platform_name --[[@as string]])

  local link_content = { pandoc.Str(text --[[@as string]]) }
  local link_attr = pandoc.Attr('', {}, {})

  if quarto.doc.is_format("html:js") or quarto.doc.is_format("html") then
    link_attr = pandoc.Attr('', {}, { title = platform_label })
    local link = pandoc.Link(link_content, uri --[[@as string]], '', link_attr)

    local platform_badge = nil
    local status_badge = nil
    if show_platform_badge or status then
      local css_path = quarto.utils.resolve_path("gitlink.css")
      html_mod.ensure_html_dependency({
        name = 'quarto-gitlink',
        version = '1.0.0',
        stylesheets = { css_path }
      })
    end

    if show_platform_badge then
      local badge_classes = { 'gitlink-badge', 'badge', 'text-bg-secondary' }
      local badge_style = {}
      if not str.is_empty(badge_background_colour) then
        table.insert(badge_style, 'background-color: ' .. badge_background_colour .. ';')
      end
      if not str.is_empty(badge_text_colour) then
        table.insert(badge_style, 'color: ' .. badge_text_colour .. ';')
      end

      local content, is_icon = html_badge_content(PLATFORM_ICON_NAMES[(platform_name --[[@as string]]):lower()],
        platform_label)
      if is_icon then
        table.insert(badge_classes, 'gitlink-icon-badge')
      end

      local badge_attr = pandoc.Attr(
        '',
        badge_classes,
        {
          title = platform_label,
          ['aria-label'] = platform_label .. ' platform',
          style = table.concat(badge_style, ' ')
        }
      )
      platform_badge = pandoc.Span(content, badge_attr)
    end

    if status then
      local icon_names = STATUS_ICON_NAMES[status.ref_type or '']
      local content, is_icon = html_badge_content(icon_names and icon_names[status.class], status.label)
      local status_classes = { 'gitlink-badge', 'gitlink-status-badge', 'badge', 'gitlink-status-' .. status.class }
      if is_icon then
        table.insert(status_classes, 'gitlink-icon-badge')
      end
      local status_attr = pandoc.Attr(
        '',
        status_classes,
        { title = status.label, ['aria-label'] = status.label .. ' status' }
      )
      status_badge = pandoc.Span(content, status_attr)
    end

    if platform_badge or status_badge then
      -- The status badge always sits immediately before the link (it reads
      -- like a state marker, e.g. a checkbox); `badge-position` only ever
      -- governs the platform badge, which defaults to after the link.
      local inlines = {}
      if status_badge then
        table.insert(inlines, status_badge)
        table.insert(inlines, pandoc.Space())
      end
      if platform_badge and badge_position == "before" then
        table.insert(inlines, platform_badge)
        table.insert(inlines, pandoc.Space())
        table.insert(inlines, link)
      else
        table.insert(inlines, link)
        if platform_badge then
          table.insert(inlines, platform_badge)
        end
      end
      return pandoc.Span(inlines)
    else
      return link
    end
  elseif quarto.doc.is_format("typst") then
    local link = pandoc.Link(link_content, uri --[[@as string]], '', link_attr)

    -- Typst rgb() only accepts hex strings, so convert any CSS-named colour
    -- (already validated at Meta time) to its hex equivalent.
    local function typst_box(label, bg_hex, text_colour_hex)
      local text_colour_opt = ''
      if not str.is_empty(text_colour_hex) then
        text_colour_opt = ', fill: rgb("' .. text_colour_hex .. '")'
      end
      return pandoc.RawInline('typst', ' #box(fill: rgb("' ..
          bg_hex ..
          '"), inset: 2pt, outset: 0pt, radius: 3pt, baseline: -0.3em, text(size: 0.45em' ..
          text_colour_opt .. ', [' .. label .. ']))')
    end

    local platform_badge = nil
    local status_badge = nil
    if show_platform_badge then
      local bg_hex = colour_to_hex(badge_background_colour)
      local text_colour_hex = not str.is_empty(badge_text_colour) and colour_to_hex(badge_text_colour --[[@as string]]) or nil
      platform_badge = typst_box(platform_label, bg_hex, text_colour_hex)
    end
    if status then
      status_badge = typst_box(status.label, STATUS_STATE_COLOURS[status.class] or '#c3c3c3', '#ffffff')
    end

    if platform_badge or status_badge then
      -- Same fixed order as HTML: status always immediately before the link;
      -- `badge-position` only governs the platform badge.
      local inlines = {}
      if status_badge then
        table.insert(inlines, status_badge)
        table.insert(inlines, pandoc.Space())
      end
      if platform_badge and badge_position == "before" then
        table.insert(inlines, platform_badge)
        table.insert(inlines, pandoc.Space())
        table.insert(inlines, link)
      else
        table.insert(inlines, link)
        if platform_badge then
          table.insert(inlines, platform_badge)
        end
      end
      return pandoc.Span(inlines)
    else
      return link
    end
  else
    local suffix = platform_label
    if status then
      suffix = suffix .. ', ' .. status.label
    end
    table.insert(link_content, pandoc.Space())
    table.insert(link_content, pandoc.Str("(" .. suffix .. ")"))
    return pandoc.Link(link_content, uri --[[@as string]], '', link_attr)
  end
end

--- Get repository name from metadata or git remote.
--- This function extracts the repository name either from document metadata
--- or by querying the git remote origin URL.
--- @param meta table The document metadata table.
--- @return table The metadata table (unchanged).
local function get_repository(meta)
  -- Reset module-level state at the start of every document so a previous
  -- render in a batch does not bleed into this one.
  reset_state()

  -- Allow opt-out at the document level for drafts, templates, or any
  -- document where automatic link rewriting is undesirable. The navbar
  -- widget is gated independently so a site can run widget-only with
  -- `enabled: false` and `widget.enabled: true`.
  local extensions_meta = meta and meta['extensions']
  local gitlink_meta = extensions_meta and extensions_meta['gitlink']
  local widget_meta = gitlink_meta and gitlink_meta['widget']
  local widget_enabled = widget.is_enabled(widget_meta)
  is_enabled = read_boolean_meta(gitlink_meta, 'enabled', true)
  if not is_enabled and not widget_enabled then
    return meta
  end

  local meta_platform = meta_mod.get_metadata_value(meta, 'gitlink', 'platform')
  local meta_base_url = meta_mod.get_metadata_value(meta, 'gitlink', 'base-url')
  local meta_repository = meta_mod.get_metadata_value(meta, 'gitlink', 'repository-name')
  local meta_group = meta_mod.get_metadata_value(meta, 'gitlink', 'group')
  local meta_custom_platforms = meta_mod.get_metadata_value(meta, 'gitlink', 'custom-platforms-file')

  if not str.is_empty(meta_custom_platforms) then
    local original_path = meta_custom_platforms --[[@as string]]
    local custom_file_path = paths.resolve_project_path(original_path)
    local ok, err = platforms.initialise(custom_file_path)
    if not ok then
      log.log_error(
        EXTENSION_NAME,
        "Failed to load custom platforms from '" .. original_path .. "':\n" .. (err or 'unknown error')
      )
      return meta
    end
  else
    local ok, err = platforms.initialise()
    if not ok then
      log.log_error(EXTENSION_NAME, "Failed to load built-in platforms:\n" .. (err or 'unknown error'))
      return meta
    end
  end

  -- Parse repo-url from project metadata (website/book)
  local project_repo_url = meta_mod.get_project_repo_url()
  local parsed_platform, parsed_base_url, parsed_repo_name = nil, nil, nil
  if project_repo_url then
    parsed_platform, parsed_base_url, parsed_repo_name = parse_repo_url(project_repo_url)
    if not parsed_platform then
      log.log_warning(
        EXTENSION_NAME,
        "Could not match project repo-url '" .. project_repo_url ..
        "' to any known platform. Falling back to default resolution."
      )
    end
  end

  -- Resolve platform: explicit metadata > repo-url detection > default 'github'
  if not str.is_empty(meta_platform) then
    platform = (meta_platform --[[@as string]]):lower()
  elseif parsed_platform then
    platform = parsed_platform
  else
    platform = 'github'
  end

  local config = get_platform_config(platform)
  if not config then
    local available_platforms = table.concat(get_all_platform_names(), ', ')
    log.log_error(
      EXTENSION_NAME,
      "Unsupported platform: '" .. platform ..
      "'. Supported platforms are: " .. available_platforms .. '.'
    )
    return meta
  end

  -- Resolve base-url: explicit metadata > repo-url detection > platform default
  if not str.is_empty(meta_base_url) then
    base_url = meta_base_url --[[@as string]]
  elseif parsed_base_url then
    base_url = parsed_base_url
  else
    base_url = config.base_url
  end

  -- Resolve repository-name: explicit metadata > repo-url path > git remote
  if not str.is_empty(meta_repository) then
    repository_name = meta_repository
  elseif parsed_repo_name then
    repository_name = parsed_repo_name
  elseif not str.is_empty(meta_group) then
    -- Group mode: references are written relative to the group (e.g.
    -- "subgroup/project#123"), so there is no single "current repository" to
    -- fall back to; auto-detecting the git remote here would silently point
    -- bare "#123"-style references at the wrong project.
    repository_name = nil
  else
    repository_name = git.get_repository()
  end

  if not str.is_empty(meta_group) then
    group_name = (meta_group --[[@as string]]):gsub('/$', '')
    if platform ~= 'gitlab' then
      log.log_warning(
        EXTENSION_NAME,
        "'extensions.gitlink.group' is only resolved for the 'gitlab' platform; it has no effect for '" ..
        platform .. "'."
      )
    end
  end

  show_platform_badge = read_boolean_meta(gitlink_meta, 'show-platform-badge', true)

  local badge_pos_meta = meta_mod.get_metadata_value(meta, 'gitlink', 'badge-position')
  if badge_pos_meta ~= nil then
    badge_position = badge_pos_meta --[[@as string]]
  end

  local badge_bg_colour_meta = meta_mod.get_metadata_value(meta, 'gitlink', 'badge-background-colour')
  if not str.is_empty(badge_bg_colour_meta) then
    local validated_bg = validate_colour(badge_bg_colour_meta --[[@as string]], 'badge-background-colour')
    if validated_bg then
      badge_background_colour = validated_bg
    end
  end

  local badge_text_colour_meta = meta_mod.get_metadata_value(meta, 'gitlink', 'badge-text-colour')
  if not str.is_empty(badge_text_colour_meta) then
    local validated_text = validate_colour(badge_text_colour_meta --[[@as string]], 'badge-text-colour')
    if validated_text then
      badge_text_colour = validated_text
    end
  end

  normalize_links = read_boolean_meta(gitlink_meta, 'normalize-links', true)

  -- Default-false flag: only literal 'true' enables it (matches YAML boolean
  -- coercion). Anything else falls back to false.
  local fetch_titles_meta = gitlink_meta and gitlink_meta['fetch-titles']
  if fetch_titles_meta ~= nil then
    fetch_titles = (str.stringify(fetch_titles_meta):lower() == 'true')
  end

  -- Default-false flag: fetches issue/merge request open/closed/merged status
  -- from the platform's REST API (currently only configured for GitLab, via
  -- 'status' in platforms.yml). Best-effort: network or API failures are
  -- logged once and otherwise leave the link unstyled.
  local fetch_status_meta = gitlink_meta and gitlink_meta['fetch-status']
  if fetch_status_meta ~= nil then
    fetch_status = (str.stringify(fetch_status_meta):lower() == 'true')
  end
  if fetch_status and not (config.status and not str.is_empty(config.status.issue_endpoint)) then
    log.log_warning(
      EXTENSION_NAME,
      "'extensions.gitlink.fetch-status' is enabled but platform '" .. platform ..
      "' has no status API configured; no status badges will be shown."
    )
  end

  -- Read the optional `mentions` list (citation IDs to force-treat as mentions).
  -- Direct table access because get_metadata_value flattens lists via stringify.
  local mentions_meta = gitlink_meta and gitlink_meta['mentions']
  if mentions_meta then
    if type(mentions_meta) == 'table' then
      for _, mention in ipairs(mentions_meta) do
        local id = str.stringify(mention)
        if not str.is_empty(id) then
          force_mentions_set[id] = true
        end
      end
    else
      local id = str.stringify(mentions_meta)
      if not str.is_empty(id) then
        force_mentions_set[id] = true
      end
    end
  end

  if widget_enabled then
    widget.setup({
      extension_name = EXTENSION_NAME,
      widget_meta = widget_meta,
      platform = platform,
      platform_config = config,
      base_url = base_url,
      repository_name = repository_name,
      display_name = platforms.get_platform_display_name(platform),
    })
  end

  return meta
end

--- Extract and store reference IDs from the document
--- This function collects all reference IDs from the document to distinguish
--- between actual citations and Git hosting mentions
--- @param doc pandoc.Pandoc The Pandoc document
--- @return pandoc.Pandoc The document (unchanged)
local function get_references(doc)
  local references = pandoc.utils.references(doc)
  for _, reference in ipairs(references) do
    if reference.id then
      references_ids_set[reference.id] = true
    end
  end
  return doc
end

--- Process Git hosting mentions in citations.
--- Distinguishes between actual bibliography citations and Git hosting @mentions.
--- When the citation id appears in `gitlink.mentions`, the citation is forced
--- to be treated as a mention even if a reference with that id exists.
--- @param cite pandoc.Cite The citation element
--- @return pandoc.Cite|pandoc.Link The original citation or a Git hosting mention link
local function process_mentions(cite)
  if not is_enabled then
    return cite
  end
  local cite_id = cite.citations[1] and cite.citations[1].id
  if cite_id and not force_mentions_set[cite_id] and references_ids_set[cite_id] then
    return cite
  end
  local mention_text = str.stringify(cite.content)
  local config = get_platform_config(platform)
  if config and config.patterns.user then
    local username = mention_text:match(config.patterns.user)
    if username then
      local url_format = config.url_formats.user
      local uri = base_url .. url_format:gsub("{username}", username)
      local link = create_platform_link(mention_text, uri, platform)
      return link or cite
    end
  end
  return cite
end


--- Prefix a matched relative project path with the configured GitLab group.
--- Lets `sous-groupe/projet#123` resolve against `extensions.gitlink.group`
--- instead of requiring the full namespace (group/sous-groupe/projet) in text.
--- @param repo string The project path as matched in the text (e.g. "sous-groupe/projet")
--- @return string The path to use for URL building
local function apply_group_prefix(repo)
  if str.is_empty(group_name) then
    return repo
  end
  return group_name .. "/" .. repo
end

--- Substitute `{base-url}`, `{repo-encoded}`, `{repo}`, and `{number}` in a
--- status API endpoint template. Function replacements (rather than plain
--- string arguments) keep literal `%` characters introduced by percent-encoding
--- from being misread as gsub capture references.
--- @param template string The endpoint template (e.g. "{base-url}/api/v4/projects/{repo-encoded}/issues/{number}")
--- @param current_base_url string
--- @param repo string
--- @param number string
--- @return string The resolved endpoint URL
local function resolve_status_endpoint(template, current_base_url, repo, number)
  local resolved = template
  resolved = resolved:gsub('{base%-url}', function() return current_base_url end)
  resolved = resolved:gsub('{repo%-encoded}', function() return str.url_encode(repo) end)
  resolved = resolved:gsub('{repo}', function() return repo end)
  resolved = resolved:gsub('{number}', function() return number end)
  return resolved
end

--- @type boolean Whether the missing/invalid-token warning has already been logged this render
local status_token_warning_shown = false

--- Build the auth header argument for a status API call from the platform's
--- configured environment variable (e.g. `GITLAB_TOKEN`). Returns nil (an
--- anonymous request) when no environment variable is configured, it is unset,
--- or its value contains characters that would be unsafe to embed in the
--- shell command line.
--- @param status_config table The platform's `status` configuration
--- @return string|nil The "Header-Name: value" string, or nil
local function status_auth_header(status_config)
  if str.is_empty(status_config.token_env) then
    return nil
  end
  local token = os.getenv(status_config.token_env)
  if str.is_empty(token) then
    return nil
  end
  if (token --[[@as string]]):find('[\r\n"`$]') then
    if not status_token_warning_shown then
      log.log_warning(
        EXTENSION_NAME,
        "Ignoring '" .. status_config.token_env .. "': it contains characters that cannot be used in a request header."
      )
      status_token_warning_shown = true
    end
    return nil
  end
  local header_name = status_config.token_header or 'Authorization'
  return header_name .. ': ' .. token
end

--- Log why a status fetch was abandoned, once per (unique) endpoint since
--- `status_cache` already prevents re-fetching the same endpoint twice.
--- @param endpoint string The API endpoint that was requested (no credentials in it: the token travels as a header, never in the URL)
--- @param reason string Human-readable reason
local function log_status_fetch_failure(endpoint, reason)
  log.log_warning(
    EXTENSION_NAME,
    "Could not fetch status from '" .. endpoint .. "': " .. reason .. '.'
  )
end

--- Fetch and normalise the open/closed/merged status of an issue or merge
--- request via the platform's REST API (best-effort, cached per render).
--- Returns nil when `fetch-status` is off, the platform has no `status`
--- section in its configuration (only GitLab defines one currently), or the
--- request fails for any reason; failures never abort the render (failure
--- reasons are logged as warnings via `log_status_fetch_failure`).
--- @param config table The platform configuration
--- @param current_base_url string The platform base URL for this match
--- @param repo string The fully-resolved repository/project path
--- @param ref_type string "issue" or "merge_request" (or "pull", treated as "merge_request")
--- @param number string The issue/merge request number
--- @return table|nil {label, class} or nil
local function fetch_status_for(config, current_base_url, repo, ref_type, number)
  if not fetch_status or not config.status then
    return nil
  end
  local template = ref_type == 'issue' and config.status.issue_endpoint or config.status.merge_request_endpoint
  if str.is_empty(template) then
    return nil
  end
  local endpoint = resolve_status_endpoint(template, current_base_url, repo, number)

  local cached = status_cache[endpoint]
  if cached ~= nil then
    return cached or nil
  end

  if endpoint:find('"', 1, true) or endpoint:find("'", 1, true) then
    log_status_fetch_failure(endpoint, 'the URL contains a quote character')
    status_cache[endpoint] = false
    return nil
  end

  local header_arg = ''
  local auth_header = status_auth_header(config.status)
  if auth_header then
    header_arg = ' -H "' .. auth_header .. '"'
  end

  -- No `-f`/`--fail`: that flag discards the response body on HTTP errors,
  -- which previously made every non-2xx response (bad token, private
  -- project, wrong path, rate limit) fail completely silently. `-w` appends
  -- the HTTP status on its own line so failures can be diagnosed instead.
  local handle = io.popen(
    'curl -sSL --max-time 8 -A "quarto-gitlink"' .. header_arg ..
    ' -w "\\nGITLINK_HTTP_STATUS:%{http_code}" "' .. endpoint .. '" 2>' .. NULL_DEVICE, 'r'
  )
  if not handle then
    log_status_fetch_failure(endpoint, 'could not start curl')
    status_cache[endpoint] = false
    return nil
  end
  local output = handle:read('*a') or ''
  handle:close()

  local body, http_status = output:match('^(.-)\nGITLINK_HTTP_STATUS:(%d+)%s*$')
  if not http_status then
    log_status_fetch_failure(endpoint, 'no response (network error, invalid base-url, or the request timed out)')
    status_cache[endpoint] = false
    return nil
  end
  if http_status == '000' then
    log_status_fetch_failure(
      endpoint, 'could not connect (network error, invalid base-url, or a TLS certificate problem)'
    )
    status_cache[endpoint] = false
    return nil
  end
  if http_status ~= '200' then
    local hint = ''
    if http_status == '401' then
      hint = '; check the ' .. tostring(config.status.token_env) .. ' environment variable'
    elseif http_status == '403' or http_status == '404' then
      hint = '; check the project path/number and that the token (if any) has access'
    elseif http_status == '429' then
      hint = '; rate limited, consider setting ' .. tostring(config.status.token_env)
    end
    log_status_fetch_failure(endpoint, 'HTTP ' .. http_status .. hint)
    status_cache[endpoint] = false
    return nil
  end

  local state_field = config.status.state_field or 'state'
  local ok, decoded = pcall(quarto.json.decode, body)
  if not ok or type(decoded) ~= 'table' or str.is_empty(decoded[state_field]) then
    log_status_fetch_failure(endpoint, 'unexpected response format (could not find "' .. state_field .. '")')
    status_cache[endpoint] = false
    return nil
  end

  local raw_state = str.stringify(decoded[state_field]):lower()
  local base = STATUS_STATE_LABELS[raw_state] or { label = raw_state:sub(1, 1):upper() .. raw_state:sub(2), class = 'unknown' }
  -- Build a fresh table (never mutate the shared STATUS_STATE_LABELS entries,
  -- which are reused across every call): ref_type picks the issue vs. merge
  -- request icon in `create_platform_link`.
  local info = {
    label = base.label,
    class = base.class,
    ref_type = (ref_type == 'issue') and 'issue' or 'merge_request',
  }
  status_cache[endpoint] = info
  return info
end

--- Process issues and merge requests
--- @param elem pandoc.Str The string element to process
--- @param current_platform string The current platform name
--- @param current_base_url string The current base URL
--- @return pandoc.Link|nil A link or nil if no valid pattern found
--- @return string|nil The platform name used for this match
--- @return string|nil The base URL used for this match
local function process_issues_and_mrs(elem, current_platform, current_base_url)
  local config = get_platform_config(current_platform)
  if not config then
    return nil, nil, nil
  end

  local text = elem.text
  local repo = nil
  local number = nil
  local ref_type = nil
  local short_link = nil
  local matched_platform = current_platform
  local matched_base_url = current_base_url

  for _, pattern in ipairs(config.patterns.issue) do
    if pattern == "#(%d+)" and text:match("^#(%d+)$") then
      number = text:match("^#(%d+)$")
      repo = repository_name
      ref_type = "issue"
      short_link = "#" .. number
      break
    elseif pattern == "([^/]+/[^/#]+)#(%d+)" and text:match("^([^/]+/[^/#]+)#(%d+)$") then
      repo, number = text:match("^([^/]+/[^/#]+)#(%d+)$")
      ref_type = "issue"
      short_link = repo .. "#" .. number
      break
    elseif pattern == "([^/]+/[^#]+)#(%d+)" and text:match("^([^/]+/[^#]+)#(%d+)$") then
      local matched_repo
      matched_repo, number = text:match("^([^/]+/[^#]+)#(%d+)$")
      -- Tolerate a trailing slash before the delimiter (e.g. "subgroup/project/#123"):
      -- otherwise it would end up baked into the API/project path as a bogus
      -- empty segment.
      matched_repo = matched_repo:gsub('/+$', '')
      ref_type = "issue"
      short_link = matched_repo .. "#" .. number
      repo = apply_group_prefix(matched_repo)
      break
    elseif pattern == "GH%-(%d+)" and text:match("^GH%-(%d+)$") then
      number = text:match("^GH%-(%d+)$")
      repo = repository_name
      ref_type = "issue"
      short_link = "#" .. number
      break
    end
  end

  if not number and config.patterns.merge_request then
    for _, pattern in ipairs(config.patterns.merge_request) do
      if pattern == "!(%d+)" and text:match("^!(%d+)$") then
        number = text:match("^!(%d+)$")
        repo = repository_name
        ref_type = "merge_request"
        short_link = "!" .. number
        break
      elseif pattern == "([^/]+/[^/#]+)!(%d+)" and text:match("^([^/]+/[^/#]+)!(%d+)$") then
        repo, number = text:match("^([^/]+/[^/#]+)!(%d+)$")
        ref_type = "merge_request"
        short_link = repo .. "!" .. number
        break
      elseif pattern == "([^/]+/[^!]+)!(%d+)" and text:match("^([^/]+/[^!]+)!(%d+)$") then
        local matched_repo
        matched_repo, number = text:match("^([^/]+/[^!]+)!(%d+)$")
        -- Tolerate a trailing slash before the delimiter (e.g. "subgroup/project/!123").
        matched_repo = matched_repo:gsub('/+$', '')
        ref_type = "merge_request"
        short_link = matched_repo .. "!" .. number
        repo = apply_group_prefix(matched_repo)
        break
      end
    end
  end

  if not number then
    local all_platform_names = get_all_platform_names()
    for _, platform_name in ipairs(all_platform_names) do
      local platform_config = get_platform_config(platform_name)
      if platform_config then
        local platform_base_url = platform_config.base_url
        local escaped_platform_url = str.escape_pattern(platform_base_url)
        local url_pattern_issue = '^' .. escaped_platform_url .. '/([^/]+/[^/]+)/%-?/?issues?/(%d+)'
        local url_pattern_mr = '^' .. escaped_platform_url .. '/([^/]+/[^/]+)/%-?/?merge[_%-]requests/(%d+)'
        local url_pattern_pull_requests = '^' .. escaped_platform_url .. '/([^/]+/[^/]+)/%-?/?pull%-requests/(%d+)'
        local url_pattern_pull = '^' .. escaped_platform_url .. '/([^/]+/[^/]+)/%-?/?pulls?/(%d+)'

        if text:match(url_pattern_issue) then
          repo, number = text:match(url_pattern_issue)
          ref_type = 'issue'
          if repo == repository_name then
            short_link = '#' .. number
          else
            short_link = repo .. '#' .. number
          end
          matched_platform = platform_name
          matched_base_url = platform_base_url
          config = platform_config
          break
        elseif text:match(url_pattern_mr) then
          repo, number = text:match(url_pattern_mr)
          ref_type = 'merge_request'
          if repo == repository_name then
            short_link = '!' .. number
          else
            short_link = repo .. '!' .. number
          end
          matched_platform = platform_name
          matched_base_url = platform_base_url
          config = platform_config
          break
        elseif text:match(url_pattern_pull_requests) then
          repo, number = text:match(url_pattern_pull_requests)
          ref_type = 'pull'
          if repo == repository_name then
            short_link = '#' .. number
          else
            short_link = repo .. '#' .. number
          end
          matched_platform = platform_name
          matched_base_url = platform_base_url
          config = platform_config
          break
        elseif text:match(url_pattern_pull) then
          repo, number = text:match(url_pattern_pull)
          ref_type = 'pull'
          if repo == repository_name then
            short_link = '#' .. number
          else
            short_link = repo .. '#' .. number
          end
          matched_platform = platform_name
          matched_base_url = platform_base_url
          config = platform_config
          break
        end
      end
    end
  end

  if number and repo and ref_type then
    local url_format
    if ref_type == "issue" then
      url_format = config.url_formats.issue
    elseif ref_type == "merge_request" then
      url_format = config.url_formats.merge_request
    elseif ref_type == "pull" then
      url_format = config.url_formats.pull
    end

    if url_format then
      local uri = matched_base_url .. url_format:gsub("{repo}", repo):gsub("{number}", number)
      local status = fetch_status_for(config, matched_base_url, repo, ref_type, number)
      return create_platform_link(short_link, uri, matched_platform, status), matched_platform, matched_base_url
    end
  end

  return nil, nil, nil
end

--- Process user/organisation references
--- @param elem pandoc.Str The string element to process
--- @param current_platform string The current platform name
--- @return pandoc.Link|nil A user link or nil if no valid pattern found
--- @return string|nil The platform name used for this match
--- @return string|nil The base URL used for this match
local function process_users(elem, current_platform)
  local config = get_platform_config(current_platform)
  if not config then
    return nil, nil, nil
  end

  local text = elem.text
  local username = nil

  local all_platform_names = get_all_platform_names()
  for _, platform_name in ipairs(all_platform_names) do
    local platform_config = get_platform_config(platform_name)
    if platform_config then
      local platform_base_url = platform_config.base_url
      local escaped_platform_url = str.escape_pattern(platform_base_url)
      local url_pattern = '^' .. escaped_platform_url .. '/([%w%-%.]+)$'

      if text:match(url_pattern) then
        username = text:match(url_pattern)
        if username then
          local url_format = platform_config.url_formats.user
          local uri = platform_base_url .. url_format:gsub('{username}', username)
          return create_platform_link('@' .. username, uri, platform_name), platform_name, platform_base_url
        end
      end
    end
  end

  return nil, nil, nil
end

--- Process commit references
--- @param elem pandoc.Str The string element to process
--- @param current_platform string The current platform name
--- @param current_base_url string The current base URL
--- @return pandoc.Link|nil A commit link or nil if no valid pattern found
--- @return string|nil The platform name used for this match
--- @return string|nil The base URL used for this match
local function process_commits(elem, current_platform, current_base_url)
  local config = get_platform_config(current_platform)
  if not config then
    return nil, nil, nil
  end

  local text = elem.text
  local repo = nil
  local commit_sha = nil
  local short_link = nil
  local matched_platform = current_platform
  local matched_base_url = current_base_url

  for _, pattern in ipairs(config.patterns.commit) do
    if pattern == "^(%x+)$" and text:match("^(%x+)$") and text:len() >= COMMIT_SHA_MIN_LENGTH and text:len() <= COMMIT_SHA_FULL_LENGTH then
      commit_sha = text:match("^(%x+)$")
      repo = repository_name
      short_link = commit_sha:sub(1, COMMIT_SHA_SHORT_LENGTH)
      break
    elseif pattern == "([^/]+/[^/@]+)@(%x+)" and text:match("^([^/]+/[^/@]+)@(%x+)$") then
      local r, sha = text:match("^([^/]+/[^/@]+)@(%x+)$")
      if sha:len() >= COMMIT_SHA_MIN_LENGTH and sha:len() <= COMMIT_SHA_FULL_LENGTH then
        repo = r
        commit_sha = sha
        short_link = repo .. "@" .. commit_sha:sub(1, COMMIT_SHA_SHORT_LENGTH)
        break
      end
    elseif pattern == "([^/]+/[^@]+)@(%x+)" and text:match("^([^/]+/[^@]+)@(%x+)$") then
      local r, sha = text:match("^([^/]+/[^@]+)@(%x+)$")
      -- Tolerate a trailing slash before the delimiter (e.g. "subgroup/project/@sha").
      r = r:gsub('/+$', '')
      if sha:len() >= COMMIT_SHA_MIN_LENGTH and sha:len() <= COMMIT_SHA_FULL_LENGTH then
        commit_sha = sha
        short_link = r .. "@" .. commit_sha:sub(1, COMMIT_SHA_SHORT_LENGTH)
        repo = apply_group_prefix(r)
        break
      end
    elseif pattern == "(%w+)@(%x+)" and text:match("^(%w+)@(%x+)$") then
      local user, sha = text:match("^(%w+)@(%x+)$")
      if repository_name and sha:len() >= COMMIT_SHA_MIN_LENGTH and sha:len() <= COMMIT_SHA_FULL_LENGTH then
        local repo_part = repository_name:match("/(.+)")
        if repo_part then
          repo = user .. "/" .. repo_part
          commit_sha = sha
          short_link = user .. "@" .. sha:sub(1, COMMIT_SHA_SHORT_LENGTH)
          break
        end
      end
    end
  end

  if not commit_sha then
    local all_platform_names = get_all_platform_names()
    for _, platform_name in ipairs(all_platform_names) do
      local platform_config = get_platform_config(platform_name)
      if platform_config then
        local platform_base_url = platform_config.base_url
        local escaped_platform_url = str.escape_pattern(platform_base_url)
        local url_pattern = '^' .. escaped_platform_url .. '/([^/]+/[^/]+)/%-?/?commits?/(%x+)$'
        if text:match(url_pattern) then
          local r, sha = text:match(url_pattern)
          if sha:len() >= COMMIT_SHA_MIN_LENGTH and sha:len() <= COMMIT_SHA_FULL_LENGTH then
            repo = r
            commit_sha = sha
            if repo == repository_name then
              short_link = commit_sha:sub(1, COMMIT_SHA_SHORT_LENGTH)
            else
              short_link = repo .. '@' .. commit_sha:sub(1, COMMIT_SHA_SHORT_LENGTH)
            end
            matched_platform = platform_name
            matched_base_url = platform_base_url
            config = platform_config
            break
          end
        end
      end
    end
  end

  if commit_sha and repo
      and commit_sha:len() >= COMMIT_SHA_MIN_LENGTH
      and commit_sha:len() <= COMMIT_SHA_FULL_LENGTH then
    local url_format = config.url_formats.commit
    local uri = matched_base_url .. url_format:gsub("{repo}", repo):gsub("{sha}", commit_sha)
    return create_platform_link(short_link, uri, matched_platform), matched_platform, matched_base_url
  end

  return nil, nil, nil
end

--- Process "repo@sha/path" file-at-commit references, linking to the
--- platform's file/blob view. Driven entirely by the `file` section of the
--- platform configuration (currently only GitLab's `platforms.yml` entry
--- defines one), so a platform without it is simply skipped.
--- @param elem pandoc.Str The string element to process
--- @param current_platform string The current platform name
--- @param current_base_url string The current base URL
--- @return pandoc.Link|nil A file link or nil if no valid pattern found
--- @return string|nil The platform name used for this match
--- @return string|nil The base URL used for this match
local function process_files(elem, current_platform, current_base_url)
  local config = get_platform_config(current_platform)
  if not config or not config.file or str.is_empty(config.file.pattern) or str.is_empty(config.file.url_format) then
    return nil, nil, nil
  end

  local text = elem.text
  local repo, sha, file_path = text:match('^' .. config.file.pattern .. '$')
  if not repo or str.is_empty(sha) or str.is_empty(file_path) then
    return nil, nil, nil
  end
  if sha:len() < COMMIT_SHA_MIN_LENGTH or sha:len() > COMMIT_SHA_FULL_LENGTH then
    return nil, nil, nil
  end

  -- Tolerate a trailing slash before the delimiter (e.g. "subgroup/project/@sha/path").
  repo = repo:gsub('/+$', '')
  local short_link = repo .. '@' .. sha:sub(1, COMMIT_SHA_SHORT_LENGTH) .. '/' .. file_path
  local full_repo = apply_group_prefix(repo)
  local uri = current_base_url ..
      config.file.url_format:gsub('{repo}', full_repo):gsub('{sha}', sha):gsub('{path}', file_path)
  return create_platform_link(short_link, uri, current_platform), current_platform, current_base_url
end

--- Try the issue/MR, commit, file, and user matchers on a single token's text.
--- @param text string The token text to match
--- @return pandoc.Link|pandoc.Span|nil A link, a badge span, or nil
local function match_single(text)
  local elem = pandoc.Str(text)
  return process_issues_and_mrs(elem, platform, base_url)
    or process_files(elem, platform, base_url)
    or process_commits(elem, platform, base_url)
    or process_users(elem, platform)
end

--- Match a token's text as a single reference or a comma-separated group.
--- First tries a whole-text match. If that fails and the text is a
--- comma-separated group (two or more segments), matches every segment; the
--- group is recognised only when *all* segments are valid references, so mixed
--- text such as "1,000" or "#1,note" is left untouched. Comma separators are
--- preserved as literal `Str` inlines.
--- @param text string The token text (already stripped of surrounding brackets)
--- @return pandoc.Link|pandoc.Span|pandoc.List|nil A link, a badge span, a list of inlines, or nil
local function match_reference_group(text)
  local link = match_single(text)
  if link then
    return link
  end

  if not text:find(",", 1, true) then
    return nil
  end

  local links = {}
  local count = 0
  for segment in (text .. ","):gmatch("([^,]*),") do
    if segment == "" then
      return nil
    end
    local seg_link = match_single(segment)
    if not seg_link then
      return nil
    end
    count = count + 1
    links[count] = seg_link
  end

  if count < 2 then
    return nil
  end

  local result = pandoc.List({})
  for i = 1, count do
    if i > 1 then
      result:insert(pandoc.Str(","))
    end
    result:insert(links[i])
  end
  return result
end

--- Main Git hosting processing function
--- Attempts to convert string elements into Git hosting links by trying different patterns
--- @param elem pandoc.Str The string element to process
--- @return pandoc.Str|pandoc.Link|pandoc.List The original element, a link, or a list of inlines
local function process_gitlink(elem)
  if not is_enabled then
    return elem
  end
  if not platform or not base_url or str.is_empty(platform) then
    return elem
  end
  -- When link normalisation is disabled, leave bare URL tokens alone.
  -- Pandoc represents the visible text of an autolink as a Str inside the
  -- Link element, so skipping URL-shaped tokens preserves the URL text.
  if not normalize_links then
    local t = elem.text
    if t and (t:sub(1, 7) == 'http://' or t:sub(1, 8) == 'https://') then
      return elem
    end
  end

  -- Fast path: match the raw text directly, including bare comma-separated
  -- groups such as "#2,#3".
  local link = match_reference_group(elem.text)
  if link then
    return link
  end

  -- Slow path: peel unbalanced surrounding brackets and trailing punctuation
  -- and retry. This also handles bracket groups that Pandoc split across
  -- whitespace, e.g. "(#2," and "#3)" from "(#2, #3)", and single-token groups
  -- such as "(#2,#3)".
  local prefix, inner, suffix = str.strip_edges(elem.text)
  if prefix ~= "" or suffix ~= "" then
    if inner ~= "" then
      link = match_reference_group(inner)
      if link then
        local result = pandoc.List({})
        if prefix ~= "" then
          result:insert(pandoc.Str(prefix))
        end
        if pandoc.utils.type(link) == "List" then
          result:extend(link)
        else
          result:insert(link)
        end
        if suffix ~= "" then
          result:insert(pandoc.Str(suffix))
        end
        return result
      end
    end
  end

  -- Embedded path: scan for a bracket pair anywhere inside the token and
  -- retry the matchers on the bracket content. Handles cases where the
  -- bracket is surrounded by additional text or punctuation, e.g.
  -- "something(#1)", "(#1).", ".(#1).", "(#1)something", "something(#1,#2)".
  local search_pos = 1
  while true do
    local b_prefix, b_content, b_suffix, open_pos = str.find_bracketed_content(elem.text, search_pos)
    if not b_content then
      break
    end

    local content_link = match_reference_group(b_content)
    if content_link then
      local result = pandoc.List({})
      if b_prefix ~= "" then
        result:insert(pandoc.Str(b_prefix))
      end
      if pandoc.utils.type(content_link) == "List" then
        result:extend(content_link)
      else
        result:insert(content_link)
      end
      if b_suffix ~= "" then
        result:insert(pandoc.Str(b_suffix))
      end
      return result
    end

    search_pos = open_pos + 1
  end

  return elem
end

--- Recover a gitlink reference Pandoc's citation parser split across a
--- Str/Cite boundary. A slash immediately before "@" (e.g. "repo/@sha/path",
--- from the still-common habit of writing a slash before every delimiter)
--- makes Pandoc's reader start a citation right there, tokenising it as
--- `Str("repo/")` followed by `Cite("sha/path")` instead of one Str -- so it
--- never reaches `process_gitlink` as a single token.
---
--- The fix only ever *tries* the merge: it reconstructs the original text
--- (the Cite's rendered content is exactly "@" plus its citation id, which
--- can itself contain slashes) and runs it through the normal matchers. If
--- that resolves to a real gitlink reference, the Str/Cite pair is replaced
--- by the resulting link; if not, both are left completely untouched, so a
--- genuine citation or @mention immediately after a slash-ending word is
--- never at risk.
--- @param inlines pandoc.List The block's inline content
--- @return pandoc.List The (possibly modified) inline content
local function merge_slash_cite_splits(inlines)
  local result = pandoc.List({})
  local i = 1
  while i <= #inlines do
    local elem = inlines[i]
    local next_elem = inlines[i + 1]
    if elem.t == "Str" and elem.text:sub(-1) == "/" and next_elem and next_elem.t == "Cite" then
      local candidate = elem.text .. str.stringify(next_elem.content)
      local link = match_single(candidate)
      if link then
        result:insert(link)
        i = i + 2
      else
        result:insert(elem)
        i = i + 1
      end
    else
      result:insert(elem)
      i = i + 1
    end
  end
  return result
end

--- Process inline elements for Bitbucket multi-word patterns
--- @param elem table Block element containing inline content
--- @return table The modified element
local function process_inlines(elem)
  if not is_enabled then
    return elem
  end
  if elem.content and platform == "bitbucket" then
    elem.content = bitbucket.process_inlines(elem.content, base_url, repository_name, create_platform_link)
  end
  return elem
end

--- Run `merge_slash_cite_splits` on a block's inline content. Registered as
--- the *last* filter pass (after the `Str`/`Cite` passes, not alongside
--- `process_inlines` above) so the link it produces is never walked again by
--- a later pass: `process_gitlink` re-processing the freshly-created link's
--- own display text produced a link nested inside a link.
--- @param elem table Block element containing inline content
--- @return table The modified element
local function recover_slash_cite_splits(elem)
  if not is_enabled then
    return elem
  end
  if elem.content then
    elem.content = merge_slash_cite_splits(elem.content)
  end
  return elem
end

--- Fetch the HTML <title> of a URL via curl (best-effort, cached per render).
--- Returns nil when fetching is disabled, the URL cannot be reached, or curl
--- is not available. Failures log a warning but never abort the render.
--- @param uri string The URL to fetch
--- @return string|nil The page title, or nil if unavailable
local function fetch_title_for(uri)
  if not fetch_titles then
    return nil
  end
  local cached = title_cache[uri]
  if cached ~= nil then
    return cached or nil
  end
  if uri:find('"', 1, true) or uri:find("'", 1, true) then
    title_cache[uri] = false
    return nil
  end
  local handle = io.popen(
    'curl -fsSL --max-time 5 -A "quarto-gitlink" "' .. uri .. '" 2>' .. NULL_DEVICE, 'r'
  )
  if not handle then
    log.log_warning(EXTENSION_NAME, "Title fetch unavailable (could not start curl).")
    title_cache[uri] = false
    return nil
  end
  local body = handle:read('*a') or ''
  handle:close()
  local raw_title = body:match('<title[^>]*>(.-)</title>')
  if not raw_title or raw_title == '' then
    title_cache[uri] = false
    return nil
  end
  local decoded = raw_title
      :gsub('&amp;', '&')
      :gsub('&lt;', '<')
      :gsub('&gt;', '>')
      :gsub('&quot;', '"')
      :gsub('&#39;', "'")
  local trimmed = str.trim(decoded)
  if trimmed == '' then
    title_cache[uri] = false
    return nil
  end
  title_cache[uri] = trimmed
  return trimmed
end

--- Process Link elements to shorten platform URLs used as link text.
--- When `gitlink.normalize-links` is true (the default), an autolink whose text
--- equals its target (e.g. `<https://github.com/owner/repo/issues/1>`) is
--- unwrapped so the later `Str` pass converts the bare URL to its platform-style
--- form (e.g. `#1`). Unwrapping (rather than returning the converted link here)
--- avoids a doubly nested link, because the `Str` pass also descends into link
--- content and would re-process the shortened text.
--- When `gitlink.fetch-titles` is true, an autolink whose target points at a
--- known platform URL is given a title-derived link text (issue/PR/commit
--- title) instead of the URL when the fetch succeeds.
--- @param elem pandoc.Link The link element to process
--- @return pandoc.Link|pandoc.Str The original link, a retitled link, or the unwrapped URL
local function process_link(elem)
  if not is_enabled or not normalize_links then
    return elem
  end

  local link_text = str.stringify(elem.content)
  local link_target = elem.target

  if link_text == link_target then
    if fetch_titles then
      local title = fetch_title_for(link_target)
      if title then
        return pandoc.Link({ pandoc.Str(title) }, link_target, '', elem.attr)
      end
    end

    -- Only unwrap when the URL is a recognised platform reference; otherwise the
    -- autolink is left untouched so ordinary URLs keep their link.
    -- `process_gitlink` returns its argument unchanged when nothing matches, so
    -- an identity check reliably detects a conversion. `pandoc.utils.type`
    -- cannot be used here: it reports "Inline" for both `Str` and `Link`.
    local temp_str = pandoc.Str(link_text)
    if process_gitlink(temp_str) ~= temp_str then
      return temp_str
    end
  end

  return elem
end

--- Pandoc filter configuration
--- Defines the order of filter execution:
--- 1. Extract references from the document
--- 2. Get repository information from metadata
--- 3. Process inline containers for Bitbucket multi-word patterns
--- 4. Process link elements to shorten URLs used as link text
--- 5. Process string elements for Git hosting patterns
--- 6. Process citations for Git hosting mentions
return {
  { Pandoc = get_references },
  { Meta = get_repository },
  { Plain = process_inlines, Para = process_inlines },
  { Link = process_link },
  { Str = process_gitlink },
  -- Between the Str and Cite passes: the Cite elements it consumes must
  -- still be intact (process_mentions hasn't run yet), and nothing later
  -- walks Str/Link content, so the link it produces is never re-processed.
  { Plain = recover_slash_cite_splits, Para = recover_slash_cite_splits },
  { Cite = process_mentions }
}

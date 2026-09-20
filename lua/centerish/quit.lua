local M = {}

---@param win? integer
---@return boolean?
local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

---Copy a source window's appearance to an inactive floating window.
---Use a private namespace to preserve the chosen normal and winbar colors and return a
---lookup for the source's effective highlight definitions.
---@param target integer Floating window receiving the copied highlights.
---@param source integer Window whose appearance is copied.
---@param active boolean Whether to use the source's active normal and winbar colors.
---@param name string Name of the private highlight namespace.
---@return integer namespace
---@return fun(group: string): vim.api.keyset.get_hl_info lookup Source highlight lookup.
local function match_highlights(target, source, active, name)
  local original = vim.api.nvim_get_hl_ns({ winid = source })
  local groups = original > 0 and vim.api.nvim_get_hl(original, {}) or {}
  -- Without a name, get_hl returns a map rather than a single definition.
  ---@cast groups table<string, vim.api.keyset.get_hl_info>
  local mapping = {}
  if original <= 0 then
    for from, to in vim.wo[source].winhighlight:gmatch("([^,:]+):([^,]+)") do
      mapping[from] = to
      groups[from] = vim.api.nvim_get_hl(0, { name = to, link = false })
    end
  end
  ---Resolve a highlight for the source window, including global fallbacks.
  ---@param group string Highlight group name.
  ---@return vim.api.keyset.get_hl_info
  local function get(group)
    local attrs = vim.api.nvim_get_hl(original > 0 and original or 0, {
      name = mapping[group] or group,
      link = false,
    })
    if original > 0 and vim.tbl_isempty(attrs) then
      attrs = vim.api.nvim_get_hl(0, { name = group, link = false })
    end
    return attrs
  end
  local normal = get(active and "Normal" or "NormalNC")
  if vim.tbl_isempty(normal) then
    normal = get("Normal")
  end
  groups.Normal, groups.NormalNC, groups.NormalFloat = normal, normal, normal
  local winbar = get(active and "WinBar" or "WinBarNC")
  groups.WinBar, groups.WinBarNC = winbar, winbar
  local namespace = vim.api.nvim_create_namespace(name)
  for group in pairs(vim.api.nvim_get_hl(namespace, {})) do
    vim.api.nvim_set_hl(namespace, group, {})
  end
  for group, attrs in pairs(groups) do
    -- Neovim documents get_hl definitions as valid set_hl input.
    vim.api.nvim_set_hl(namespace, group, attrs --[[@as vim.api.keyset.highlight]])
  end
  vim.api.nvim_win_set_hl_ns(target, namespace)
  return namespace, get
end

---Render the source winbar once so expressions keep their original window context.
---Give each highlight span a private name so copied base colors cannot replace it.
---Escape literal percent signs for the mirror's winbar.
---@param source integer Window whose bar is copied.
---@param namespace integer Mirror's private highlight namespace.
---@param lookup fun(group: string): vim.api.keyset.get_hl_info Source highlight lookup.
---@return string format Static winbar text with highlight switches.
local function render_winbar(source, namespace, lookup)
  local format = vim.wo[source].winbar
  if format == "" then
    return ""
  end
  local rendered = vim.api.nvim_eval_statusline(format, {
    winid = source,
    use_winbar = true,
    highlights = true,
    maxwidth = vim.api.nvim_win_get_width(source),
    fillchar = vim.api.nvim_win_call(source, function()
      return vim.opt_local.fillchars:get().wbr or " "
    end),
  })
  local parts = {}
  for index, highlight in ipairs(rendered.highlights) do
    local following = rendered.highlights[index + 1]
    local stop = following and following.start or #rendered.str
    local source_group = highlight.groups and highlight.groups[#highlight.groups] or highlight.group
    local group = "CenterishQuitWinBar" .. index
    vim.api.nvim_set_hl(namespace, group, lookup(source_group) --[[@as vim.api.keyset.highlight]])
    local text = rendered.str:sub(highlight.start + 1, stop):gsub("%%", "%%%%")
    parts[#parts + 1] = "%#" .. group .. "#" .. text
  end
  return table.concat(parts)
end

---Keep the final editor view stable while allowing the original quit to exit.
---Use preview and floating padding so native quit checks and hooks still run.
---Return both callbacks together, or both nil when preparation is unavailable.
---@param pads { left?: centerish.Padding, right?: centerish.Padding }
---@return (fun())? restore Restore the temporary layout after a refused quit.
---@return (fun())? dismiss Close the mirrored view before unloading its buffer.
function M.prepare(pads)
  local preview = pads.left or pads.right
  if not preview or not valid(preview.win) then
    return
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[win].previewwindow then
      return
    end
  end

  local other = pads.left and pads.right
  local mirror, original_width, original_namespace
  local function dismiss()
    if valid(mirror) then
      vim.api.nvim_win_close(mirror, true)
    end
    mirror = nil
  end

  ---Remove the mirror and return surviving padding to ordinary split windows.
  local function restore()
    dismiss()
    if valid(preview.win) then
      vim.wo[preview.win].previewwindow = false
    end
    if other and valid(other.win) then
      if vim.api.nvim_win_get_config(other.win).relative ~= "" then
        vim.api.nvim_win_set_config(
          other.win,
          { split = "right", win = -1, width = original_width }
        )
      end
      if original_namespace then
        vim.api.nvim_win_set_hl_ns(other.win, original_namespace)
      end
    end
  end

  local ok, err = xpcall(function()
    if other and valid(other.win) then
      local editor = vim.api.nvim_get_current_win()
      local position = vim.api.nvim_win_get_position(editor)
      mirror = vim.api.nvim_open_win(vim.api.nvim_win_get_buf(editor), false, {
        relative = "editor",
        row = position[1],
        col = position[2],
        width = vim.api.nvim_win_get_width(editor),
        height = vim.api.nvim_win_get_height(editor),
        focusable = false,
        zindex = 1,
        border = "none",
        noautocmd = true,
      })
      local editor_namespace, editor_highlight =
        match_highlights(mirror, editor, true, "centerish_quit_editor")
      vim.wo[mirror].winbar = render_winbar(editor, editor_namespace, editor_highlight)

      local pad_position = vim.api.nvim_win_get_position(other.win)
      original_width = vim.api.nvim_win_get_width(other.win)
      original_namespace = vim.api.nvim_get_hl_ns({ winid = other.win })
      local namespace = match_highlights(other.win, other.win, false, "centerish_quit_padding")
      vim.api.nvim_set_hl(
        namespace,
        "CenterishQuitSeparator",
        editor_highlight("WinSeparator") --[[@as vim.api.keyset.highlight]]
      )
      local separator = vim.opt_local.fillchars:get().vert or "│"
      vim.api.nvim_win_set_config(other.win, {
        relative = "editor",
        row = pad_position[1],
        col = pad_position[2] - 1,
        width = original_width,
        height = vim.api.nvim_win_get_height(other.win),
        focusable = false,
        zindex = 1,
        border = { "", "", "", "", "", "", "", { separator, "CenterishQuitSeparator" } },
      })
    end
    vim.wo[preview.win].previewwindow = true
  end, debug.traceback)

  if not ok then
    restore()
    error(err)
  end
  return restore, dismiss
end

return M

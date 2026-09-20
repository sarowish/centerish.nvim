local session = require("centerish.session")

local M = {}

---@class centerish.Padding
---@field win integer
---@field buf integer
---@field options table<string, boolean|integer|string> Window options restored if padding becomes an editor.

---@class centerish.PaddingState
---@field pads { left?: centerish.Padding, right?: centerish.Padding }
---@field growth centerish.Spans Padding columns consumed since enabling.
---@field owner string Unique identity shared by this tab's saved padding.
---@field adjustment? centerish.Spans Manual changes to the calculated padding spans.
---@field target? integer Editor target associated with those manual changes.

---@class centerish.Sidebars
---@field left integer[]
---@field right integer[]

---@param win? integer
---@return boolean?
local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

---Recognize padding only when its owned window and buffer still match.
---@param state centerish.PaddingState
---@param win integer
---@return boolean
function M.is_owned(state, win)
  for _, pad in pairs(state.pads) do
    if pad.win == win and valid(win) and vim.api.nvim_win_get_buf(win) == pad.buf then
      return true
    end
  end

  return false
end

---Remove one side of owned padding, deleting its unused buffer before forgetting it.
---If closing it would leave Neovim without an ordinary window, reuse it as
---an editable blank window with its saved window options.
---Call with the owning tab current, inside the caller's layout transaction.
---@param state centerish.PaddingState
---@param side centerish.Side
function M.close(state, side)
  local pad = state.pads[side]

  if not pad then
    return
  end

  if valid(pad.win) and vim.api.nvim_win_get_buf(pad.win) == pad.buf then
    -- Keep Neovim usable if the user closed every real window in this tab.
    local ordinary = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(win).relative == "" then
        ordinary = ordinary + 1
      end
    end

    if
      ordinary == 1
      and vim.api.nvim_win_get_config(pad.win).relative == ""
      and #vim.api.nvim_list_tabpages() == 1
    then
      local buf = vim.api.nvim_create_buf(true, false)
      local fixed = vim.wo[pad.win].winfixbuf
      vim.wo[pad.win].winfixbuf = false
      local ok, err = pcall(vim.api.nvim_win_set_buf, pad.win, buf)
      if valid(pad.win) then
        -- Buffer callbacks can fail after the swap has already succeeded.
        if vim.api.nvim_win_get_buf(pad.win) ~= pad.buf then
          for name, value in pairs(pad.options) do
            vim.wo[pad.win][name] = value
          end
        else
          vim.wo[pad.win].winfixbuf = fixed
        end
      end
      if not ok then
        if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) == 0 then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
        error(err)
      end
    else
      vim.api.nvim_win_close(pad.win, true)
    end
  end

  if vim.api.nvim_buf_is_valid(pad.buf) and #vim.fn.win_findbuf(pad.buf) == 0 then
    vim.api.nvim_buf_delete(pad.buf, { force = true })
  end
  state.pads[side] = nil
end

---Choose where to place padding relative to an edge sidebar or the tab edge.
---@param side centerish.Side
---@param sidebars centerish.Sidebars
---@return integer? anchor Sidebar to split beside, or nil for the tab edge.
---@return centerish.Side split Direction relative to the anchor.
---@return integer index Expected position in the top-level row.
local function padding_position(side, sidebars)
  local wins = sidebars[side]
  local anchor = side == "left" and wins[#wins] or wins[1]
  local tree = vim.fn.winlayout()
  local index
  if anchor and tree[1] == "row" then
    ---@cast tree vim.fn.winlayout.branch
    for position, child in ipairs(tree[2]) do
      if child[1] == "leaf" and child[2] == anchor then
        index = position
        break
      end
    end
  end
  anchor = index and anchor or nil
  return anchor,
    anchor and (side == "left" and "right" or "left") or side,
    index and (side == "left" and index + 1 or index - 1)
      or (side == "left" and 1 or (tree[1] == "row" and #tree[2] or 1))
end

local padding_options = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  statuscolumn = "",
  statusline = " ",
  winbar = "",
  colorcolumn = "",
  cursorline = false,
  cursorcolumn = false,
  winfixwidth = true,
  winfixbuf = true,
  previewwindow = false,
  spell = false,
  list = false,
  fillchars = "eob: ",
}

---Configure a padding buffer and window, saving options for later reuse as an editor.
---When adopting padding from a session, take those options from the template.
---@param pad centerish.Padding
---@param template? integer Window whose options are saved for later restoration.
function M.style(pad, template)
  session.buffer(pad.buf)
  for name, value in pairs(padding_options) do
    pad.options[name] = vim.wo[template or pad.win][name]
    vim.wo[pad.win][name] = value
  end
end

---Check that padding still occupies its full-height edge or sidebar position.
---@param pad centerish.Padding
---@param side centerish.Side
---@param sidebars centerish.Sidebars
---@return boolean? Whether padding occupies its expected position.
local function positioned(pad, side, sidebars)
  local _, _, index = padding_position(side, sidebars)
  local tree = vim.fn.winlayout()
  return tree[1] == "row"
    and tree[2][index]
    and tree[2][index][1] == "leaf"
    and tree[2][index][2] == pad.win
end

---Create a named scratch pad and register it with the tab's state.
---Start at the minimum allowed width; layout application sizes it afterwards.
---@param state centerish.PaddingState
---@param side centerish.Side
---@param sidebars centerish.Sidebars
---@return centerish.Padding
local function create_padding(state, side, sidebars)
  local anchor, split = padding_position(side, sidebars)
  local buf = vim.api.nvim_create_buf(false, true)
  local fixed = anchor and vim.wo[anchor].winfixwidth or false

  if anchor then
    vim.wo[anchor].winfixwidth = false
  end

  local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
    split = split,
    win = anchor or -1,
    width = math.max(1, vim.o.winminwidth),
  })

  if anchor then
    vim.wo[anchor].winfixwidth = fixed
  end

  if not ok then
    vim.api.nvim_buf_delete(buf, { force = true })
    error(win)
  end

  local pad = { win = win, buf = buf, options = {} }
  vim.api.nvim_win_call(win, function()
    state.pads[side] = pad
    M.style(pad)
    session.name(pad.buf, state.owner, side, state.growth, state.adjustment, state.target)
  end)

  return pad
end

---Make owned padding match the requested spans and restore sidebar widths.
---Release surplus space before creating or moving pads to their expected sides.
---Call with the owning tab current, inside the caller's layout transaction.
---@param state centerish.PaddingState
---@param spans centerish.Spans
---@param sidebars centerish.Sidebars
---@param widths centerish.WidthMap Sidebar widths to preserve.
function M.apply(state, spans, sidebars, widths)
  -- Release space before allocating it on the other side.
  for _, side in ipairs({ "left", "right" }) do
    local pad = state.pads[side]
    if spans[side] == 0 then
      M.close(state, side)
    elseif pad and M.is_owned(state, pad.win) then
      if vim.api.nvim_win_get_width(pad.win) > spans[side] - 1 then
        vim.api.nvim_win_set_width(pad.win, spans[side] - 1)
      end
    end
  end

  for _, side in ipairs({ "left", "right" }) do
    if spans[side] > 0 then
      local pad = state.pads[side]
      if not pad or not M.is_owned(state, pad.win) then
        M.close(state, side)
        create_padding(state, side, sidebars)
      elseif not positioned(pad, side, sidebars) then
        local anchor, split = padding_position(side, sidebars)
        local fixed = anchor and vim.wo[anchor].winfixwidth or false
        if anchor then
          vim.wo[anchor].winfixwidth = false
        end
        local ok, err = pcall(vim.api.nvim_win_set_config, pad.win, {
          split = split,
          win = anchor or -1,
          width = math.max(1, vim.o.winminwidth),
        })
        if anchor then
          vim.wo[anchor].winfixwidth = fixed
        end
        if not ok then
          error(err)
        end
      end
    end
  end

  for win, width in pairs(widths) do
    if valid(win) and vim.api.nvim_win_get_width(win) ~= width then
      vim.api.nvim_win_set_width(win, width)
    end
  end

  for _, side in ipairs({ "right", "left" }) do
    local pad = state.pads[side]
    if pad and vim.api.nvim_win_get_width(pad.win) ~= spans[side] - 1 then
      vim.api.nvim_win_set_width(pad.win, spans[side] - 1)
    end
  end
end

return M

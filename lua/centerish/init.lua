local configuration = require("centerish.config")
local layout = require("centerish.layout")
local padding = require("centerish.padding")
local quit = require("centerish.quit")
local session = require("centerish.session")

local M = {}

---@alias centerish.WindowSet table<integer, true>
---@alias centerish.WidthMap table<integer, integer>
---@alias centerish.FlatRow { [1]: "row", [2]: vim.fn.winlayout.leaf[] }

local config = configuration.resolve()

---@class centerish.Spans
---@field left integer
---@field right integer

---@class centerish.EditorBounds
---@field left integer First editor column, counted from zero.
---@field right integer Column immediately after the rightmost editor.

---@class centerish.SessionMetadata
---@field owner string Identity shared by one tab's saved padding.
---@field side centerish.Side Padding side encoded in the buffer name.
---@field growth centerish.Spans Saved adaptive growth, in columns.
---@field adjustment? centerish.Spans Saved manual changes to the padding spans.
---@field target? integer Editor target used when the manual changes were saved.

---@class centerish.TabState: centerish.PaddingState
---@field last_win integer Last focused window outside padding.
---@field restore_quit? fun() Restore padding after a refused native quit.
---@field widths? centerish.WidthMap Last stable editor widths.
---@field buffers? table<integer, integer> Last editor buffers.
---@field columns? integer Screen width when those widths were captured.
---@field lines? integer Screen height when those widths were captured.
---@field tree? vim.fn.winlayout.ret Last editor-only layout.
---@field sidebars? centerish.WidthMap Last sidebar widths.
---@field actual_sidebars? centerish.WidthMap Last observed native sidebar widths.
---@field preserved_sidebars? centerish.WidthMap Sidebar widths before layout work, retained until idle.
---@field sidebar_requests? centerish.WidthMap Explicit Lua sidebar width requests awaiting a refresh.
---@field manual_sidebars? centerish.WindowSet Sidebars receiving native resize input.
---@field manual_sidebar_widths? centerish.WidthMap Sidebar widths after that native input.
---@field layout? vim.fn.winlayout.ret Last complete layout.
---@field spans? centerish.Spans Last stable padding spans, including separators.
---@field bounds? centerish.EditorBounds Last stable outer editor edges.
---@field manual_resize? boolean Native width command or separator drag originated at an editor.
---@field automatic_resize? boolean Native focus or winwidth changes may enlarge an editor.

---@type table<integer, centerish.TabState>
local tabs = {}
local busy, pending = false, false
local pending_session = false
local dragging = false
---@type table<integer, true>
local refresh_tabs = {}
---@type fun()
local schedule_updates
---@type integer?
local group

---@param win? integer
---@return boolean?
local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

---Block layout work and public requests until native session loading and adoption finish.
---@return boolean
local function session_loading()
  return pending_session or not not vim.g.SessionLoad
end

---Collect the current tab's ordinary editor windows and sidebars.
---Sidebar lists follow their screen order from left to right.
---@param state centerish.TabState
---@return centerish.WindowSet editors
---@return centerish.Sidebars sidebars
local function scan(state)
  local editors, sidebars = {}, { left = {}, right = {} }

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local win_config = vim.api.nvim_win_get_config(win)
    if
      win_config.relative == ""
      and not win_config.external
      and not padding.is_owned(state, win)
    then
      local buf = vim.api.nvim_win_get_buf(win)
      local sidebar = config.sidebars[vim.bo[buf].filetype]

      if sidebar then
        table.insert(sidebars[sidebar.side], win)
      else
        editors[win] = true
      end
    end
  end

  for _, wins in pairs(sidebars) do
    table.sort(wins, function(a, b)
      return vim.api.nvim_win_get_position(a)[2] < vim.api.nvim_win_get_position(b)[2]
    end)
  end

  return editors, sidebars
end

---Apply allocated widths while temporarily pinning each completed editor column.
---Restore the user's winfixwidth settings when resizing finishes.
---@param editors centerish.WindowSet
---@param widths centerish.WidthMap Allocated width for every editor window.
local function resize_editors(editors, widths)
  local changed = false
  for win in pairs(editors) do
    changed = changed or vim.api.nvim_win_get_width(win) ~= widths[win]
  end
  if not changed then
    return
  end
  local ordered, fixed = vim.tbl_keys(editors), {}
  table.sort(ordered, function(a, b)
    local pa, pb = vim.api.nvim_win_get_position(a), vim.api.nvim_win_get_position(b)
    return pa[2] == pb[2] and pa[1] < pb[1] or pa[2] < pb[2]
  end)
  local ok, err = xpcall(function()
    for _, win in ipairs(ordered) do
      fixed[win] = vim.wo[win].winfixwidth
      vim.wo[win].winfixwidth = false
    end
    for _, win in ipairs(ordered) do
      if vim.api.nvim_win_get_width(win) ~= widths[win] then
        vim.api.nvim_win_set_width(win, widths[win])
      end
      vim.wo[win].winfixwidth = true
    end
  end, debug.traceback)
  for win, value in pairs(fixed) do
    if valid(win) then
      vim.wo[win].winfixwidth = value
    end
  end
  if not ok then
    error(err)
  end
end

---Measure the widest unfolded line in the viewport, including window gutters.
---Use display-cell widths for tabs and wide characters.
---@param win integer
---@return integer
local function visible_width(win)
  local result = 0
  vim.api.nvim_win_call(win, function()
    local last = vim.fn.line("w$")
    local line = vim.fn.line("w0")
    local buf = vim.api.nvim_get_current_buf()

    while line <= last do
      local fold_end = vim.fn.foldclosedend(line)
      if fold_end ~= -1 then
        line = fold_end + 1
      else
        local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
        result = math.max(result, vim.fn.strdisplaywidth(text))
        line = line + 1
      end
    end

    result = result + vim.fn.getwininfo(win)[1].textoff
  end)

  return result
end

---Find the outer edges shared by the tab's editing area.
---@param editors centerish.WindowSet
---@return centerish.EditorBounds
local function editor_bounds(editors)
  local left, right = math.huge, 0
  for win in pairs(editors) do
    local col = vim.api.nvim_win_get_position(win)[2]
    left = math.min(left, col)
    right = math.max(right, col + vim.api.nvim_win_get_width(win))
  end
  return { left = left, right = right }
end

---Capture native sidebar resizing before a buffer callback can request another width.
---@param state centerish.TabState
local function remember_manual_sidebars(state)
  if not state.manual_sidebars then
    return
  end
  state.manual_sidebar_widths = state.manual_sidebar_widths or {}
  for win in pairs(state.manual_sidebars) do
    if valid(win) then
      local width = vim.api.nvim_win_get_width(win)
      state.manual_sidebar_widths[win] = width
      if state.preserved_sidebars then
        state.preserved_sidebars[win] = width
      end
      if state.sidebar_requests then
        state.sidebar_requests[win] = nil
      end
    end
  end
  state.manual_sidebars = nil
end

---Keep the pre-change widths through scheduled layout callbacks, including new refreshes.
---@param state centerish.TabState
local function preserve_sidebars(state)
  if not state.preserved_sidebars then
    state.preserved_sidebars =
      vim.tbl_extend("force", {}, state.sidebars or {}, state.manual_sidebar_widths or {})
  end
end

---@param state centerish.TabState
local function remember_sidebar_geometry(state)
  state.actual_sidebars = {}
  for win in pairs(state.sidebars or {}) do
    if valid(win) then
      state.actual_sidebars[win] = vim.api.nvim_win_get_width(win)
    end
  end
end

---Capture native sizing before leaving a sidebar or forwarding a Lua width request.
---Lua sizing, screen changes and unfinished layout work are already accounted for.
---@param state centerish.TabState
---@param win integer
local function remember_sidebar_resize(state, win)
  if
    state.preserved_sidebars
    or state.automatic_resize
    or state.columns ~= vim.o.columns
    or state.lines ~= vim.o.lines
    or not state.actual_sidebars
    or not state.actual_sidebars[win]
    or state.actual_sidebars[win] == vim.api.nvim_win_get_width(win)
  then
    return
  end
  local editors = scan(state)
  if not vim.deep_equal(layout.editors(vim.fn.winlayout(), editors), state.tree) then
    return
  end
  for editor, buf in pairs(state.buffers or {}) do
    if not valid(editor) or vim.api.nvim_win_get_buf(editor) ~= buf then
      return
    end
  end
  state.manual_sidebars = state.manual_sidebars or {}
  state.manual_sidebars[win] = true
  remember_manual_sidebars(state)
end

---Remember externally resized edges while the screen and surrounding layout are unchanged.
---Compare with the last applied geometry so delayed events from our own sizing are ignored.
---@param state centerish.TabState
---@param bounds centerish.EditorBounds Current outer editor edges.
---@param spans centerish.Spans Padding calculated without a manual adjustment.
---@param target integer Current editor target, including fixed-width windows.
local function remember_resize(state, bounds, spans, target)
  local actual = { left = 0, right = 0 }
  for side, pad in pairs(state.pads) do
    if padding.is_owned(state, pad.win) then
      actual[side] = vim.api.nvim_win_get_width(pad.win) + 1
    end
  end
  -- A fixed-width or configuration change can move the baseline beneath an
  -- existing adjustment. Rebase it so it cannot repeatedly enlarge the editor.
  if
    not vim.deep_equal(bounds, state.bounds)
    or not vim.deep_equal(actual, state.spans)
    or (state.adjustment and state.target ~= target)
  then
    state.adjustment = { left = actual.left - spans.left, right = actual.right - spans.right }
  end
end

---Reorder a flat row without entering editors or disturbing their viewports.
---@param desired centerish.FlatRow
local function apply_reorder(desired)
  if vim.deep_equal(vim.fn.winlayout(), desired) then
    return
  end

  local widths, fixed, helpers = {}, {}, {}
  local splitkeep = vim.o.splitkeep

  local function set_options(win, options)
    for name, value in pairs(options) do
      vim.cmd(
        "noautocmd call nvim_set_option_value("
          .. vim.fn.string(name)
          .. ", "
          .. vim.fn.string(value)
          .. ", {'win': "
          .. win
          .. "})"
      )
    end
  end

  for _, child in ipairs(desired[2]) do
    local win = child[2]
    widths[win] = vim.api.nvim_win_get_width(win)
    fixed[win] = { winfixwidth = vim.wo[win].winfixwidth, winfixheight = vim.wo[win].winfixheight }
  end

  -- Split moves temporarily redistribute widths. Keep the top line until the
  -- original dimensions return, without resolving pending curswant or applying
  -- old screen coordinates from earlier tabline or winbar changes.
  local ok, err = xpcall(function()
    -- libvterm resizes immediately, even before redraw. Keep a full-size view
    -- of each terminal so temporary narrowing cannot discard its output.
    local protected = {}
    for _, child in ipairs(desired[2]) do
      local buf = vim.api.nvim_win_get_buf(child[2])
      if vim.bo[buf].buftype == "terminal" and not protected[buf] then
        protected[buf] = true
        local width, height = 0, 0
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
          local info = vim.fn.getwininfo(win)[1]
          width = math.max(width, info.width - info.textoff)
          height = math.max(height, info.height)
        end

        if width > 0 and height > 0 then
          -- Opening from a terminal copies its live cursor into buffer history.
          -- Start from padding, then load the saved terminal mark and options
          -- natively so closing the helper preserves future buffer restoration.
          local state = tabs[vim.api.nvim_get_current_tabpage()]
          local source
          for _, leaf in ipairs(desired[2]) do
            if padding.is_owned(state, leaf[2]) then
              source = leaf[2]
              break
            end
          end

          local helper = vim.api.nvim_win_call(source, function()
            return vim.api.nvim_open_win(vim.api.nvim_win_get_buf(source), false, {
              relative = "editor",
              row = 0,
              col = 0,
              width = width,
              height = height,
              border = "none",
              focusable = false,
              zindex = 1,
              noautocmd = true,
            })
          end)
          helpers[#helpers + 1] = helper
          vim.cmd("noautocmd keepalt call win_execute(" .. helper .. ", 'buffer " .. buf .. "')")

          local info = vim.fn.getwininfo(helper)[1]
          vim.cmd(
            "noautocmd call nvim_win_set_config("
              .. helper
              .. ", {'width': "
              .. (width + info.textoff)
              .. ", 'height': "
              .. (height + info.winbar)
              .. "})"
          )
        end
      end
    end

    vim.cmd("noautocmd set splitkeep=topline")
    for win in pairs(fixed) do
      set_options(win, { winfixwidth = false, winfixheight = true })
    end

    for index, child in ipairs(desired[2]) do
      local current = vim.fn.winlayout()[2][index][2]
      if current ~= child[2] then
        vim.cmd(
          "noautocmd call nvim_win_set_config("
            .. child[2]
            .. ", {'split': 'left', 'win': "
            .. current
            .. ", 'width': "
            .. widths[child[2]]
            .. "})"
        )
      end
    end

    for _, child in ipairs(desired[2]) do
      local win = child[2]
      vim.cmd("noautocmd call nvim_win_set_width(" .. win .. ", " .. widths[win] .. ")")
      set_options(win, { winfixwidth = true, winfixheight = true })
    end
  end, debug.traceback)

  local restored, restore_err = xpcall(function()
    for _, helper in ipairs(helpers) do
      if valid(helper) then
        vim.cmd("noautocmd call nvim_win_close(" .. helper .. ", v:true)")
      end
    end

    for win, options in pairs(fixed) do
      if valid(win) then
        set_options(win, options)
      end
    end
  end, debug.traceback)
  vim.cmd("noautocmd set splitkeep=" .. splitkeep)

  if not ok then
    error(err)
  end
  if not restored then
    error(restore_err)
  end
end

---Fit editor widths and padding to the current tab, then apply adaptive growth.
---Cache the resulting geometry for resizing; disable positioning if no editors remain.
---@param state centerish.TabState
local function update(state)
  local editors, sidebars = scan(state)
  local has_sidebars = #sidebars.left + #sidebars.right > 0
  if not has_sidebars then
    state.preserved_sidebars = nil
  end
  if not next(editors) then
    local tab = vim.api.nvim_get_current_tabpage()
    padding.close(state, "left")
    padding.close(state, "right")
    tabs[tab] = nil
    return
  end

  local editor_tree = assert(layout.editors(vim.fn.winlayout(), editors))
  local buffers = {}
  for win in pairs(editors) do
    buffers[win] = vim.api.nvim_win_get_buf(win)
  end
  local editors_changed = not vim.deep_equal(editor_tree, state.tree)
    or not vim.deep_equal(buffers, state.buffers)
  local manual, automatic = state.manual_resize, state.automatic_resize
  state.manual_resize, state.automatic_resize = nil, nil
  local screen_resized = state.columns and state.columns ~= vim.o.columns
    or state.lines and state.lines ~= vim.o.lines
  remember_manual_sidebars(state)
  if state.widths and has_sidebars and (editors_changed or screen_resized) then
    preserve_sidebars(state)
  end
  -- Opted-in sidebars keep their settled width across screen and editor changes.
  -- Native editor resizing takes precedence, even when it switches buffers.
  local preserving = false
  local widths, occupied = {}, { left = 0, right = 0 }
  for side, wins in pairs(sidebars) do
    for _, win in ipairs(wins) do
      local sidebar = config.sidebars[vim.bo[vim.api.nvim_win_get_buf(win)].filetype]
      if
        not manual
        and sidebar
        and sidebar.preserve_width
        and state.preserved_sidebars
        and state.preserved_sidebars[win]
      then
        widths[win] = state.preserved_sidebars[win]
        preserving = true
      else
        widths[win] = not manual and state.sidebar_requests and state.sidebar_requests[win]
          or vim.api.nvim_win_get_width(win)
      end
      occupied[side] = occupied[side] + widths[win] + 1
    end
  end

  local bounds = editor_bounds(editors)
  local sidebar_changed = not vim.deep_equal(widths, state.sidebars)
  local stable = state.widths
    and not screen_resized
    and (manual or not state.preserved_sidebars)
    and vim.deep_equal(editor_tree, state.tree)
    and vim.deep_equal(state.layout, vim.fn.winlayout())
  local weights, fixed, targets, minima = {}, {}, {}, {}
  local previous = state.widths
    and vim.deep_equal(editor_tree, state.tree)
    and (screen_resized or (sidebar_changed and not manual))
  for win in pairs(editors) do
    weights[win] = previous and state.widths[win] or vim.api.nvim_win_get_width(win)
    fixed[win] = vim.wo[win].winfixwidth or nil
    targets[win] = math.max(vim.o.winminwidth, fixed[win] and weights[win] or config.width)
    minima[win] = math.max(1, vim.o.winminwidth, fixed[win] and weights[win] or 0)
  end

  local target = layout.editor_width(editor_tree, editors, targets)
  local minimum_span = math.max(vim.o.winminwidth + 1, config.min_padding_width + 1)
  local spans = layout.padding({
    columns = vim.o.columns,
    editor_width = target,
    sidebars = occupied,
    growth = state.growth,
    enabled = config.padding,
    minimum_span = minimum_span,
  })
  -- Sessions may omit fixed-width options or use different configuration.
  -- Translate the saved adjustment from its original target before sizing.
  if state.adjustment and state.target and not state.widths then
    local saved = layout.padding({
      columns = vim.o.columns,
      editor_width = state.target,
      sidebars = occupied,
      growth = state.growth,
      enabled = config.padding,
      minimum_span = minimum_span,
    })
    state.adjustment.left = state.adjustment.left + saved.left - spans.left
    state.adjustment.right = state.adjustment.right + saved.right - spans.right
  end
  if
    stable
    and not preserving
    and (not sidebar_changed or manual)
    and (not automatic or manual)
  then
    remember_resize(state, bounds, spans, target)
  end
  if state.adjustment then
    -- Manual shrinking may go below the target, while reserving minimum and fixed editor widths.
    local minimum = layout.editor_width(editor_tree, editors, minima)
    spans = layout.adjust_padding(spans, state.adjustment, {
      enabled = config.padding,
      available = math.max(0, vim.o.columns - occupied.left - occupied.right - minimum),
      minimum_span = minimum_span,
    })
  end
  local allocated = layout.fit(
    editor_tree,
    weights,
    fixed,
    math.max(1, vim.o.winminwidth),
    vim.o.columns - occupied.left - occupied.right - spans.left - spans.right
  )
  padding.apply(state, spans, sidebars, widths)
  resize_editors(editors, allocated)

  if config.adaptive.enabled and not state.adjustment then
    local current, desired = {}, {}
    for win in pairs(editors) do
      current[win] = vim.api.nvim_win_get_width(win)
      desired[win] = math.max(current[win], math.min(visible_width(win), config.adaptive.max_width))
    end
    desired = layout.constrain_growth(editor_tree, current, desired, fixed)

    local needed = layout.editor_width(editor_tree, editors, desired)
      - layout.editor_width(editor_tree, editors, current)
    local growth = layout.grow(spans, needed, config.adaptive.direction)

    if growth.left + growth.right > 0 then
      state.growth.left = state.growth.left + growth.left
      state.growth.right = state.growth.right + growth.right

      spans = layout.padding({
        columns = vim.o.columns,
        editor_width = target,
        sidebars = occupied,
        growth = state.growth,
        enabled = config.padding,
        minimum_span = minimum_span,
      })
      padding.apply(state, spans, sidebars, widths)

      local available = {}
      for win in pairs(editors) do
        available[win] = vim.api.nvim_win_get_width(win)
      end

      local grown_widths = layout.allocate(
        editor_tree,
        editors,
        current,
        desired,
        layout.editor_width(editor_tree, editors, available),
        fixed
      )

      resize_editors(editors, grown_widths)
    end
  end

  state.widths = {}
  for win in pairs(editors) do
    state.widths[win] = vim.api.nvim_win_get_width(win)
  end
  state.columns = vim.o.columns
  state.lines = vim.o.lines
  state.tree = editor_tree
  state.buffers = buffers
  state.sidebars = widths
  remember_sidebar_geometry(state)
  state.sidebar_requests = nil
  state.manual_sidebar_widths = nil
  if manual and state.preserved_sidebars then
    for win, width in pairs(widths) do
      state.preserved_sidebars[win] = width
    end
  end
  state.layout = vim.fn.winlayout()
  state.target = target
  state.spans = { left = 0, right = 0 }
  state.bounds = editor_bounds(editors)
  for side, pad in pairs(state.pads) do
    state.spans[side] = vim.api.nvim_win_get_width(pad.win) + 1
    session.name(pad.buf, state.owner, side, state.growth, state.adjustment, state.target)
  end
end

---@type (fun())[]
local requests = {}
local request_pending = false

---Schedule the oldest public request after the current layout mutation finishes.
---Schedule its successor before running it so one error cannot strand later requests.
local function schedule_requests()
  if busy or dragging or session_loading() or request_pending or #requests == 0 then
    return
  end

  request_pending = true
  vim.schedule(function()
    request_pending = false
    if busy or dragging or session_loading() then
      return
    end

    local action = assert(table.remove(requests, 1))
    schedule_requests()
    action()
  end)
end

---Run a layout mutation while blocking nested transactions and refresh scheduling.
---Attempt to restore focus, release the guard, then report action and restoration errors.
---@param action fun()
local function transaction(action)
  if busy then
    return
  end

  local focused = vim.api.nvim_get_current_win()
  busy = true
  local ok, err = xpcall(action, debug.traceback)
  local restored, restore_err = xpcall(function()
    if valid(focused) then
      vim.api.nvim_set_current_win(focused)
    end
  end, debug.traceback)
  busy = false
  schedule_requests()
  schedule_updates()

  if not ok then
    if not restored then
      err = err .. "\ncenterish: focus restoration also failed:\n" .. restore_err
    end
    error(err)
  end
  if not restored then
    error(restore_err)
  end
end

---Run work in a tab's current window without emitting tab-entry events.
---Keep ordinary execution in the current tab so user callback focus changes remain visible.
---@param tab integer Valid tabpage handle.
---@param action fun()
local function tab_call(tab, action)
  if tab == vim.api.nvim_get_current_tabpage() then
    action()
  else
    vim.api.nvim_win_call(vim.api.nvim_tabpage_get_win(tab), action)
  end
end

---Refresh an enabled tab without changing the caller's focus.
---@param tab integer Tab that requested the refresh.
local function refresh(tab)
  local state = tabs[tab]
  if state and vim.api.nvim_tabpage_is_valid(tab) and not state.restore_quit then
    transaction(function()
      tab_call(tab, function()
        update(state)
      end)
    end)
  end
end

---Coalesce refreshes by their originating tab and resume after transactions or sessions.
---Schedule remaining tabs first so a failed update cannot strand their refreshes.
schedule_updates = function()
  if busy or dragging or pending or session_loading() or not next(refresh_tabs) then
    return
  end

  pending = true
  vim.schedule(function()
    pending = false
    if busy or dragging or session_loading() then
      return
    end
    local tab = assert(next(refresh_tabs))
    refresh_tabs[tab] = nil
    schedule_updates()
    refresh(tab)
  end)
end

---Remember a configuration refresh even when requested from a layout callback.
local function queue_refresh()
  local tab = vim.api.nvim_get_current_tabpage()
  local state = tabs[tab]
  if state and not state.restore_quit then
    refresh_tabs[tab] = true
    schedule_updates()
  end
end

---Remember sidebar widths before buffer callbacks and their scheduled layout work.
local function prepare_buffer_change()
  if busy or dragging or session_loading() then
    return
  end
  local state = tabs[vim.api.nvim_get_current_tabpage()]
  if not state or state.restore_quit or not state.buffers then
    return
  end
  remember_manual_sidebars(state)
  local editors = scan(state)
  local win = vim.api.nvim_get_current_win()
  if
    not editors[win]
    or not state.buffers[win]
    or state.buffers[win] == vim.api.nvim_win_get_buf(win)
  then
    return
  end
  if state.sidebars and next(state.sidebars) then
    preserve_sidebars(state)
  end
end

---Remember sidebar requests even if later editor resizing temporarily clips them.
---Forward width calls without changing other windows or their handles.
local function install_width_observer()
  local set_width = vim.api.nvim_win_set_width
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.api.nvim_win_set_width = function(win, width)
    local state, tab
    local target = win == 0 and vim.api.nvim_get_current_win() or win
    if not busy and not dragging and not session_loading() and next(tabs) then
      if valid(target) then
        tab = vim.api.nvim_win_get_tabpage(target)
        state = tabs[tab]
        if state and not state.restore_quit then
          remember_sidebar_resize(state, vim.api.nvim_get_current_win())
          remember_manual_sidebars(state)
        else
          state = nil
        end
      end
    end
    set_width(win, width)
    if not state or not valid(target) then
      return
    end
    remember_sidebar_geometry(state)
    local sidebar = config.sidebars[vim.bo[vim.api.nvim_win_get_buf(target)].filetype]
    if sidebar then
      local win_config = vim.api.nvim_win_get_config(target)
      if win_config.relative == "" and not win_config.external then
        state.sidebar_requests = state.sidebar_requests or {}
        state.sidebar_requests[target] = math.max(1, vim.o.winminwidth, width)
      end
    end
    for sidebar_win, requested in pairs(state.sidebar_requests or {}) do
      if
        valid(sidebar_win)
        and (
          not state.sidebars
          or state.sidebars[sidebar_win] ~= requested
          or vim.api.nvim_win_get_width(sidebar_win) ~= requested
        )
      then
        refresh_tabs[assert(tab)] = true
        schedule_updates()
        break
      end
    end
  end
end

---Handle resizes before redraw; coalesce other events and changes made during a drag.
---@param event? vim.api.keyset.create_autocmd.callback_args
local function schedule(event)
  if not busy then
    if event and event.event == "WinResized" and not dragging and not session_loading() then
      refresh(vim.api.nvim_get_current_tabpage())
    else
      queue_refresh()
    end
  end
end

---Distinguish explicit editor resizing from sidebar width changes and focus sizing.
---@param win integer Window receiving the resize input, including a padding separator.
local function mark_manual_resize(win)
  local state = tabs[vim.api.nvim_get_current_tabpage()]
  if state and valid(win) then
    local buf = vim.api.nvim_win_get_buf(win)
    if config.sidebars[vim.bo[buf].filetype] then
      state.manual_sidebars = state.manual_sidebars or {}
      state.manual_sidebars[win] = true
    else
      state.manual_resize = true
    end
  end
end

---Remember focus before Neovim can expand the entered window to winwidth.
---@param state centerish.TabState
---@param win integer Window receiving focus, including a padding navigation target.
local function remember_focus(state, win)
  state.last_win = win
  if vim.api.nvim_win_get_width(win) < vim.o.winwidth then
    state.automatic_resize = true
  end
end

---Find the current window's root-row siblings, excluding owned padding.
---Nested rows cannot move our full-height padding and need no correction.
---@return centerish.TabState? state
---@return vim.fn.winlayout.branch? tree
---@return (vim.fn.winlayout.leaf|vim.fn.winlayout.branch)[]? siblings
---@return integer? win
local function reorder_context()
  local state = tabs[vim.api.nvim_get_current_tabpage()]
  if busy or dragging or session_loading() or not state or state.restore_quit then
    return
  end

  local tree = vim.fn.winlayout()
  if tree[1] ~= "row" then
    return
  end

  ---@cast tree vim.fn.winlayout.branch
  local win = vim.api.nvim_get_current_win()
  local found = false
  ---@type (vim.fn.winlayout.leaf|vim.fn.winlayout.branch)[]
  local siblings = {}
  for _, child in ipairs(tree[2]) do
    local leaf = child[1] == "leaf" and child --[[@as vim.fn.winlayout.leaf]]
    if not leaf or not padding.is_owned(state, leaf[2]) then
      siblings[#siblings + 1] = child
      if child[1] == "leaf" and child[2] == win then
        found = true
      end
    end
  end

  if not found or #siblings == #tree[2] then
    return
  end
  return state, tree, siblings, win
end

---Run native Visual exit and its callbacks before inspecting the rotation context.
---@param command "r"|"R"
---@param count integer
local function rotate(command, count)
  -- Callback errors can be reported after native rotation has already run.
  -- Finish its correction before reporting the error, without leaving a plan.
  local ok, err = pcall(vim.api.nvim_cmd, { cmd = "wincmd", args = { command } }, {})

  local function report_error()
    if not ok then
      local message = err:gsub("^Vim:", "")
      -- Neovim 0.10 lacks nvim_echo's err option.
      ---@diagnostic disable-next-line: deprecated
      vim.api.nvim_err_writeln(message)
      vim.v.errmsg = message
    end
  end

  local state, tree, _, win = reorder_context()
  if state then
    -- Native rotation is allowed during textlock, but its padding repair needs
    -- window APIs. Probe after the prefix expression's own lock has ended.
    local message = vim.v.errmsg
    local allowed = pcall(vim.api.nvim_set_current_win, win)
    vim.v.errmsg = message
    if not allowed then
      state = nil
    end
  end

  if not state or not tree or not win then
    -- A callback may have moved to another tab or split, or evaluation may
    -- forbid correction. Finish the native count in the current row or column.
    local current = vim.api.nvim_get_current_win()

    local function sibling_count(node)
      if node[1] == "leaf" then
        return
      end

      local contains = false
      for _, child in ipairs(node[2]) do
        if child[1] == "leaf" and child[2] == current then
          contains = true
        end
      end

      if contains then
        for _, child in ipairs(node[2]) do
          if child[1] ~= "leaf" then
            return
          end
        end
        return #node[2]
      end

      for _, child in ipairs(node[2]) do
        local found = sibling_count(child)
        if found then
          return found
        end
      end
    end

    local remaining = (math.max(1, count) - 1) % (sibling_count(vim.fn.winlayout()) or 1)
    if remaining > 0 then
      vim.cmd(remaining .. "wincmd " .. command)
    end
    report_error()
    return
  end

  for _, child in ipairs(tree[2]) do
    if child[1] ~= "leaf" then
      report_error()
      return
    end
  end

  -- Undo the one native rotation in the plan, then rotate only non-padding
  -- siblings by the full requested count. No plan survives a failed command.
  local desired = layout.reorder(tree, win, command == "r" and "R" or "r", 1)
  ---@cast desired centerish.FlatRow

  local siblings = {}
  for _, child in ipairs(desired[2]) do
    if not padding.is_owned(state, child[2]) then
      siblings[#siblings + 1] = child
    end
  end

  local ordered = layout.reorder({ "row", siblings }, win, command, count)
  ---@cast ordered centerish.FlatRow

  local index = 0
  for i, child in ipairs(desired[2]) do
    if not padding.is_owned(state, child[2]) then
      index = index + 1
      desired[2][i] = ordered[2][index]
    end
  end

  transaction(function()
    apply_reorder(desired)
  end)
  refresh(vim.api.nvim_get_current_tabpage())
  report_error()
end

---Track native resize input and defer structural layout changes across separator drags.
local function install_resize_input()
  local window_command, prefix_key = false, false
  local control_w = vim.keycode("<C-W>")
  local modifier_prefix = vim.keycode("<M-x>"):sub(1, 2)
  local plug = "<Plug>(CenterishWindowCommand)"
  local rotate_plug = "<Plug>(CenterishRotate)"

  ---@type { command: "r"|"R", count: integer }?
  local rotation

  ---@type table<string, "r"|"R">
  local rotations = {
    r = "r",
    [vim.keycode("<C-R>")] = "r",
    R = "R",
  }

  local function read_window_key()
    local key = vim.fn.getcharstr()
    -- Native window commands use the character and ignore its modifier prefix.
    return key, key:sub(1, 2) == modifier_prefix and key:sub(4) or key
  end

  local function can_execute_commands()
    -- The sandbox allows native CTRL-W input but rejects Ex execution. An empty
    -- command list checks permission; silent! may set errmsg instead of throwing.
    local message = vim.v.errmsg
    local ok, result = pcall(vim.fn.execute, {})
    vim.v.errmsg = message
    return ok and type(result) == "string"
  end

  for _, mode in ipairs({ "n", "x" }) do
    vim.keymap.set(mode, rotate_plug, function()
      local action = rotation
      rotation = nil
      if action then
        -- Keep native rotation and its padding repair in one command, including
        -- temporary Normal mode, before the next queued key can inspect the layout.
        rotate(action.command, action.count)
      end
    end, { desc = "Centerish native rotation" })

    vim.keymap.set(mode, plug, function()
      window_command, prefix_key = false, false
      local digits, key = "", ""

      -- Keep language translation in Neovim's input parser, including its
      -- distinction between typed characters and characters emitted by mappings.
      if vim.o.langmap == "" and reorder_context() then
        local initial = vim.v.count
        local suffix = 0
        local delete, keypad_delete = vim.keycode("<Del>"), vim.keycode("<kDel>")
        local command
        key, command = read_window_key()
        while
          command:match("^[1-9]$")
          or suffix > 0 and (command == "0" or command == delete or command == keypad_delete)
        do
          if command == delete or command == keypad_delete then
            suffix = math.floor(suffix / 10)
          else
            suffix = math.min(999999999, suffix * 10 + tonumber(command))
          end
          key, command = read_window_key()
        end
        digits = suffix > 0 and tostring(suffix) or ""

        if command == "x" or command == vim.keycode("<C-X>") or rotations[command] then
          -- Waiting for input can run timers that change the active tab or layout.
          local state, tree, siblings, win = reorder_context()
          if state and tree and siblings and win and can_execute_commands() then
            local count = math.max(initial, suffix)
            if initial > 0 and suffix > 0 then
              count = initial >= math.floor(999999999 / suffix) and 999999999 or initial * suffix
            end

            -- Give Neovim's count parser the effective count so callbacks see
            -- native v:count/v:count1, including counts entered after CTRL-W.
            local count_prefix = string.rep(
              vim.keycode("<Del>"),
              initial > 0 and #tostring(initial) or 0
            ) .. (count > 0 and tostring(count) or "")

            if rotations[command] then
              local flat = vim.iter(tree[2]):all(function(child)
                return child[1] == "leaf"
              end)
              if flat then
                rotation = { command = rotations[command], count = count }
                return count_prefix .. vim.keycode(rotate_plug)
              end
            else
              local _, target = layout.reorder({ "row", siblings }, win, "x", count)
              for index, child in ipairs(tree[2]) do
                if child[1] == "leaf" and child[2] == target then
                  -- Execute the exchange once, at its physical sibling address.
                  -- Native code retains Visual history, cursor state and callback focus.
                  return count_prefix
                    .. vim.keycode("<Cmd>")
                    .. index
                    .. "wincmd x"
                    .. vim.keycode("<CR>")
                end
              end
            end
          end
        end
      end

      window_command, prefix_key = true, true
      return control_w .. digits .. key
    end, { expr = true, replace_keycodes = false, desc = "Centerish native window command" })

    for _, prefix in ipairs({ "<C-W>", "<C-S-W>" }) do
      local mapped = vim.iter(vim.api.nvim_get_keymap(mode)):any(function(mapping)
        return vim.keycode(mapping.lhs) == vim.keycode(prefix)
      end)
      if not mapped then
        vim.keymap.set(mode, prefix, plug, { remap = true, desc = "Centerish window prefix" })
      end
    end
  end

  vim.on_key(function(key)
    local name = #key > 1 and vim.fn.keytrans(key) or key
    if name:match("^<[%w%-]*LeftMouse>$") then
      local mouse = vim.fn.getmousepos()
      dragging = valid(mouse.winid) and mouse.wincol > vim.api.nvim_win_get_width(mouse.winid)
        or false
      if dragging then
        mark_manual_resize(mouse.winid)
      end
    elseif name:match("^<[%w%-]*LeftRelease>$") and dragging then
      -- Closing or moving padding during a held separator drag invalidates
      -- Neovim's native drag target. Resume only after it processes release.
      dragging = false
      queue_refresh()
      schedule_requests()
      schedule_updates()
    end

    if key == control_w and prefix_key then
      prefix_key = false
      return
    end

    if window_command and key:match("^%d$") then
      return
    end
    if window_command and (key == ">" or key == "<" or key == "|" or key == "=") then
      mark_manual_resize(vim.api.nvim_get_current_win())
    end
    window_command = false
  end, vim.api.nvim_create_namespace("centerish.input"))

  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = group,
    callback = function(event)
      if event.match ~= ":" or vim.v.event.abort then
        return
      end
      local ok, command = pcall(vim.api.nvim_parse_cmd, vim.fn.getcmdline(), {})
      if
        ok
        and (
          command.cmd == "resize"
          or (command.cmd == "wincmd" and vim.tbl_contains({ ">", "<", "|", "=" }, command.args[1]))
        )
      then
        mark_manual_resize(vim.api.nvim_get_current_win())
      end
    end,
  })
end

---Install the layout, focus, quit and session autocommands once.
local function install_events()
  session.install()
  if group then
    return
  end

  group = vim.api.nvim_create_augroup("centerish", { clear = true })
  install_resize_input()
  install_width_observer()

  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "winwidth",
    callback = function()
      if busy or session_loading() then
        return
      end
      local state = tabs[vim.api.nvim_get_current_tabpage()]
      if state and not state.restore_quit then
        local win = vim.api.nvim_get_current_win()
        local width = state.widths and state.widths[win]
        -- OptionSet runs after native resizing. Compare with the last applied
        -- width so the following WinResized does not record a manual adjustment.
        if width and width < vim.o.winwidth and vim.api.nvim_win_get_width(win) > width then
          state.automatic_resize = true
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("QuitPre", {
    group = group,
    callback = function()
      local tab = vim.api.nvim_get_current_tabpage()
      local state = tabs[tab]
      if busy or not state or state.restore_quit then
        return
      end

      local editors, sidebars = scan(state)
      local ordinary = 0
      for win in pairs(editors) do
        if not vim.wo[win].previewwindow then
          ordinary = ordinary + 1
        end
      end
      if editors[vim.api.nvim_get_current_win()] and not vim.wo.previewwindow and ordinary == 1 then
        local final = #vim.api.nvim_list_tabpages() == 1
          and #sidebars.left == 0
          and #sidebars.right == 0
        if final then
          local dismiss
          transaction(function()
            state.restore_quit, dismiss = quit.prepare(state.pads)
          end)
          if state.restore_quit then
            local leaving = vim.api.nvim_create_autocmd("BufLeave", {
              group = group,
              buffer = vim.api.nvim_get_current_buf(),
              once = true,
              callback = function()
                -- A refused quit may unload the old buffer to show an unsaved
                -- one. Remove our extra views before native close_windows().
                transaction(function()
                  dismiss()
                  padding.close(state, "left")
                  padding.close(state, "right")
                end)
              end,
            })
            vim.api.nvim_create_autocmd("SafeState", {
              group = group,
              once = true,
              callback = function()
                pcall(vim.api.nvim_del_autocmd, leaving)
                transaction(function()
                  if state.restore_quit then
                    if not vim.api.nvim_tabpage_is_valid(tab) then
                      state.restore_quit()
                      state.restore_quit = nil
                      return
                    end
                    tab_call(tab, function()
                      state.restore_quit()
                      state.restore_quit = nil
                      if tabs[tab] == state then
                        update(state)
                      end
                    end)
                  end
                end)
              end,
            })
            return
          end
        end

        -- Let the original quit command perform Neovim's normal modified-buffer
        -- checks after removing our otherwise exit-blocking windows.
        transaction(function()
          padding.close(state, "left")
          padding.close(state, "right")
        end)

        -- If quitting is refused, put the layout back without losing growth.
        schedule()
      end
    end,
  })

  vim.api.nvim_create_autocmd({
    "WinNew",
    "WinClosed",
    "VimResized",
    "TabEnter",
    "FileType",
    "WinScrolled",
    "TextChanged",
    "TextChangedI",
    "TextChangedP",
  }, { group = group, callback = schedule })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    nested = true,
    callback = function(event)
      prepare_buffer_change()
      schedule(event)
    end,
  })

  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      local state = tabs[vim.api.nvim_get_current_tabpage()]
      if
        not busy
        and not dragging
        and not session_loading()
        and state
        and not state.restore_quit
      then
        remember_sidebar_resize(state, vim.api.nvim_get_current_win())
      end
    end,
  })

  -- Padding may be created or removed here. Keep its normal lifecycle events
  -- visible to other plugins while our transaction guard prevents recursion.
  vim.api.nvim_create_autocmd("WinResized", { group = group, nested = true, callback = schedule })

  -- Rotating equal-sized windows need not emit a resize or enter event.
  vim.api.nvim_create_autocmd("SafeState", {
    group = group,
    callback = function()
      local state = tabs[vim.api.nvim_get_current_tabpage()]
      if state and not vim.deep_equal(state.layout, vim.fn.winlayout()) then
        schedule()
      end
      if
        not busy
        and not dragging
        and not pending
        and not next(refresh_tabs)
        and not session_loading()
      then
        for _, tab_state in pairs(tabs) do
          tab_state.preserved_sidebars = nil
          tab_state.sidebar_requests = nil
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      if busy then
        return
      end

      local state = tabs[vim.api.nvim_get_current_tabpage()]
      if not state or state.restore_quit or vim.g.SessionLoad or pending_session then
        return
      end

      local win = vim.api.nvim_get_current_win()
      if padding.is_owned(state, win) then
        local wins = vim.tbl_filter(function(candidate)
          local candidate_config = vim.api.nvim_win_get_config(candidate)
          return candidate_config.relative == "" or candidate_config.focusable
        end, vim.api.nvim_tabpage_list_wins(0))
        local index, previous
        for position, candidate in ipairs(wins) do
          if candidate == win then
            index = position
          elseif candidate == state.last_win then
            previous = position
          end
        end
        index = assert(index)
        local direction = previous and index > previous and 1 or -1
        if previous == #wins and index == 1 then
          direction = 1
        elseif previous == 1 and index == #wins then
          direction = -1
        end
        local target
        for offset = 1, #wins do
          local candidate = wins[(index - 1 + direction * offset) % #wins + 1]
          local candidate_config = vim.api.nvim_win_get_config(candidate)
          if
            not padding.is_owned(state, candidate)
            and (candidate_config.relative == "" or candidate_config.focusable)
          then
            target = candidate
            break
          end
        end

        if target then
          remember_focus(state, target)
          vim.api.nvim_set_current_win(target)
        end
      else
        remember_focus(state, win)
      end

      schedule()
    end,
  })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      for tab in pairs(tabs) do
        if not vim.api.nvim_tabpage_is_valid(tab) then
          tabs[tab] = nil
        end
      end
    end,
  })
end

---Adopt saved padding names and rebuild enabled-tab state after a session load.
---Defer layout recovery until native window creation and session hooks finish.
function M._restore_session()
  install_events()
  if pending_session then
    return
  end
  pending_session = true
  ---Wait for session hooks and active layout callbacks before adopting their windows.
  local function restore()
    if busy or vim.g.SessionLoad then
      vim.defer_fn(restore, 1)
      return
    end
    local ok, err = xpcall(function()
      transaction(function()
        local restored = {}
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
          local state, template
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            if vim.api.nvim_win_get_config(win).relative == "" then
              local buf = vim.api.nvim_win_get_buf(win)
              local metadata = session.read(buf)
              if metadata then
                state = state
                  or {
                    pads = {},
                    owner = metadata.owner,
                    growth = metadata.growth,
                    adjustment = metadata.adjustment,
                    target = metadata.target,
                  }
                state.pads[metadata.side] = { win = win, buf = buf, options = {} }
              else
                template = template or win
              end
            end
          end
          if state then
            state.last_win = template
            restored[tab] = state
            for _, pad in pairs(state.pads) do
              padding.style(pad, template)
            end
          end
        end
        tabs = restored
        for tab, state in pairs(tabs) do
          tab_call(tab, function()
            update(state)
          end)
        end
      end)
    end, debug.traceback)
    pending_session = false
    schedule_requests()
    schedule_updates()
    if not ok then
      error(err)
    end
  end
  vim.schedule(restore)
end

---Validate and replace the shared configuration, using defaults for omitted options.
---Schedule an update for the current tab if positioning is already enabled.
---@param opts? centerish.Config
function M.setup(opts)
  config = configuration.resolve(opts)
  install_events()
  queue_refresh()
end

---Run a public operation in its originating tab, preserving the caller's focus.
---Queue requests during layout updates or behind earlier deferred requests.
---@param action fun(tab: integer)
local function request(action)
  local tab = vim.api.nvim_get_current_tabpage()
  if vim.g.SessionLoad and not pending_session then
    M._restore_session()
  end
  local function run()
    if not vim.api.nvim_tabpage_is_valid(tab) then
      return
    end
    transaction(function()
      tab_call(tab, function()
        action(tab)
      end)
    end)
  end

  if busy or dragging or session_loading() or request_pending or #requests > 0 then
    requests[#requests + 1] = run
    schedule_requests()
  else
    run()
  end
end

---Enable the selected tab and update its layout when session and quit handling allow it.
---@param tab integer Current tabpage handle inside a transaction.
local function enable(tab)
  install_events()

  local state = tabs[tab]
    or {
      pads = {},
      growth = { left = 0, right = 0 },
      last_win = vim.api.nvim_get_current_win(),
      owner = session.owner(tab),
    }
  tabs[tab] = state

  if not state.restore_quit and not vim.g.SessionLoad and not pending_session then
    update(state)
  end
end

---Remove the selected tab's owned padding before forgetting its state.
---@param tab integer Current tabpage handle inside a transaction.
local function disable(tab)
  local state = tabs[tab]
  if state then
    if state.restore_quit then
      state.restore_quit()
      state.restore_quit = nil
    end
    padding.close(state, "left")
    padding.close(state, "right")
    tabs[tab] = nil
  end
end

---Enable and refresh positioning in the current tab.
---Repeated calls preserve the tab's remembered adaptive growth.
function M.enable()
  request(enable)
end

---Disable positioning in the current tab, removing owned padding and saved growth.
function M.disable()
  request(disable)
end

---Toggle positioning in the current tab, resetting adaptive growth when disabling.
function M.toggle()
  request(function(tab)
    if tabs[tab] then
      disable(tab)
    else
      enable(tab)
    end
  end)
end

return M

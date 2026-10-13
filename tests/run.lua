vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd("runtime plugin/centerish.lua")

local centerish = require("centerish")

local function equal(actual, expected, message)
  assert(
    vim.deep_equal(actual, expected),
    (message or "unexpected value")
      .. "\nexpected: "
      .. vim.inspect(expected)
      .. "\nactual: "
      .. vim.inspect(actual)
  )
end

local function settle()
  vim.api.nvim_exec_autocmds("SafeState", {})
  vim.wait(60, function()
    return false
  end)
  -- Model returning to input after the scheduled callbacks have finished.
  vim.api.nvim_exec_autocmds("SafeState", {})
  assert(vim.v.errmsg == "", vim.v.errmsg)
end

local function pads(tab)
  local result = {}

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab or 0)) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "centerish" then
      table.insert(result, win)
    end
  end

  table.sort(result, function(a, b)
    return vim.api.nvim_win_get_position(a)[2] < vim.api.nvim_win_get_position(b)[2]
  end)

  return result
end

local function col(win)
  return vim.api.nvim_win_get_position(win)[2]
end

local function reset(opts)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    vim.api.nvim_set_current_tabpage(tab)
    centerish.disable()
  end

  vim.cmd("silent tabonly!")
  vim.cmd("silent only!")
  vim.cmd("enew!")
  vim.o.lines = 40
  vim.o.columns = 240
  vim.cmd("redraw")

  vim.o.equalalways = true
  vim.o.eadirection = "both"
  vim.o.winwidth = 20
  vim.o.winminwidth = 1
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"
  vim.wo.foldcolumn = "0"
  vim.wo.winfixwidth = false
  vim.wo.winfixbuf = false
  vim.wo.wrap = false
  vim.v.errmsg = ""

  centerish.setup(vim.tbl_deep_extend("force", {
    width = 80,
    padding = { left = true, right = true },
  }, opts or {}))
  settle()

  return vim.api.nvim_get_current_win()
end

local function sidebar(side, filetype)
  local editor = vim.api.nvim_get_current_win()
  vim.cmd(side == "left" and "topleft 20vnew" or "botright 20vnew")
  local win = vim.api.nvim_get_current_win()
  vim.bo.buftype = "nofile"
  vim.bo.filetype = filetype or "NvimTree"
  vim.wo.winfixwidth = true
  vim.api.nvim_set_current_win(editor)
  settle()

  return win
end

local tests = {}

tests["manual keyboard and mouse resizing keeps the chosen edges"] = function()
  dofile("tests/resize.lua")()
end

tests["sidebar sizing survives native and scheduled layout changes"] = function()
  dofile("tests/terminal_resize.lua")()
end

tests["padding beside narrow sidebars survives resizing and failed placement"] = function()
  dofile("tests/narrow_sidebar.lua")()
end

tests["adaptive growth follows completion input and automatic focus resizing"] = function()
  dofile("tests/adaptive_input.lua")()
end

tests["sidebar toggling preserves editor position in every rendered frame"] = function()
  dofile("tests/sidebar_ui.lua")()
end

tests["manual resizing overrides adaptive growth until centering is reset"] = function()
  local editor = reset({ min_padding_width = 0, adaptive = { enabled = true } })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("x", 120) })
  centerish.enable()
  settle()
  equal(vim.api.nvim_win_get_width(editor), 120)

  vim.api.nvim_win_set_width(editor, 70)
  vim.api.nvim_exec_autocmds("WinResized", {})
  settle()
  local position = col(editor)
  equal(vim.api.nvim_win_get_width(editor), 70)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("x", 150) })
  vim.api.nvim_exec_autocmds("TextChanged", {})
  settle()
  equal(vim.api.nvim_win_get_width(editor), 70)
  equal(col(editor), position)

  centerish.disable()
  centerish.enable()
  settle()
  equal(vim.api.nvim_win_get_width(editor), 150)
end

tests["manual sizing survives changes to fixed-width settings"] = function()
  local editor = reset()
  centerish.enable()
  settle()
  vim.cmd("10wincmd >")
  vim.api.nvim_exec_autocmds("WinResized", {})
  settle()
  local position = col(editor)

  for _, fixed in ipairs({ true, false }) do
    vim.wo[editor].winfixwidth = fixed
    for _ = 1, 3 do
      vim.api.nvim_exec_autocmds("WinResized", {})
      settle()
      equal(vim.api.nvim_win_get_width(editor), 90)
      equal(col(editor), position)
      equal(vim.wo[editor].winfixwidth, fixed)
    end
  end
end

tests["manual resizing survives terminal resizing without changing other tabs"] = function()
  local editor = reset()
  centerish.enable()
  settle()
  vim.cmd("10wincmd >")
  vim.api.nvim_exec_autocmds("WinResized", {})
  settle()
  local position = col(editor)
  equal(vim.api.nvim_win_get_width(editor), 90)
  local tab = vim.api.nvim_get_current_tabpage()

  for _, columns in ipairs({ 300, 90, 240 }) do
    vim.o.columns = columns
    vim.cmd("redraw")
    vim.api.nvim_exec_autocmds("VimResized", {})
    settle()
    if columns ~= 90 then
      equal(vim.api.nvim_win_get_width(editor), 90)
      equal(col(editor), position + (columns - 240) / 2)
    end
  end

  vim.cmd("tabnew")
  centerish.enable()
  settle()
  equal(vim.api.nvim_win_get_width(0), 80)
  vim.api.nvim_set_current_tabpage(tab)
  settle()
  equal(vim.api.nvim_win_get_width(editor), 90)
  equal(col(editor), position)
  centerish.disable()
  centerish.enable()
  settle()
  equal(vim.api.nvim_win_get_width(editor), 80)
  equal(col(editor), 80)
end

tests["unequal editing splits keep proportions when centering"] = function()
  for _, ea in ipairs({ false, true }) do
    for _, left_width in ipairs({ 48, 199 }) do
      for _, focus_left in ipairs({ false, true }) do
        local left = reset({ min_padding_width = 0 })
        vim.o.equalalways = ea
        vim.cmd("rightbelow vnew")
        local right = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_width(left, left_width)
        local ratio = vim.api.nvim_win_get_width(left) / 239
        vim.api.nvim_set_current_win(focus_left and left or right)
        centerish.enable()
        settle()

        assert(math.abs(vim.api.nvim_win_get_width(left) - ratio * 160) < 1)
        assert(vim.api.nvim_win_get_width(right) > 20)
        equal(vim.o.equalalways, ea)
        equal(vim.api.nvim_get_current_win(), focus_left and left or right)
        equal(vim.wo[left].winfixwidth, false)
        equal(vim.wo[right].winfixwidth, false)
      end
    end
  end
end

tests["resizing and sidebars keep an established split proportion"] = function()
  local left = reset({ min_padding_width = 0 })
  vim.o.columns = 400
  vim.o.equalalways = false
  vim.cmd("rightbelow vnew")
  local right = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(left, 60)
  centerish.enable()
  settle()
  local ratio = vim.api.nvim_win_get_width(left)
    / (vim.api.nvim_win_get_width(left) + vim.api.nvim_win_get_width(right))

  for _, columns in ipairs({ 240, 170, 140, 400 }) do
    vim.o.columns = columns
    vim.cmd("redraw")
    vim.api.nvim_exec_autocmds("VimResized", {})
    settle()
    local total = vim.api.nvim_win_get_width(left) + vim.api.nvim_win_get_width(right)
    assert(math.abs(vim.api.nvim_win_get_width(left) - total * ratio) < 1)
  end

  local before = { vim.api.nvim_win_get_width(left), vim.api.nvim_win_get_width(right) }
  local tree = sidebar("left")
  equal({ vim.api.nvim_win_get_width(left), vim.api.nvim_win_get_width(right) }, before)
  vim.api.nvim_win_set_width(tree, 50)
  vim.api.nvim_exec_autocmds("WinResized", {})
  settle()
  equal({ vim.api.nvim_win_get_width(left), vim.api.nvim_win_get_width(right) }, before)
end

tests["fixed editors keep their width while padding gives way"] = function()
  local left = reset()
  vim.cmd("rightbelow vnew")
  local right = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(left, 199)
  vim.wo[left].winfixwidth = true
  centerish.enable()
  settle()

  equal(#pads(), 0)
  equal(vim.api.nvim_win_get_width(left), 199)
  equal(vim.api.nvim_win_get_width(right), 40)
  equal(vim.wo[left].winfixwidth, true)
  equal(vim.wo[right].winfixwidth, false)
end

tests["mixed stacked and side-by-side editors fit the same column"] = function()
  local first = reset()
  vim.cmd("rightbelow vnew")
  local second = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(first, 48)
  vim.cmd("botright new")
  local third = vim.api.nvim_get_current_win()
  centerish.enable()
  settle()

  equal(vim.api.nvim_win_get_width(third), 161)
  equal(vim.api.nvim_win_get_width(first) + vim.api.nvim_win_get_width(second) + 1, 161)
  assert(vim.api.nvim_win_get_width(first) > 20)
end

tests["moving and rotating windows repairs padding without changing the editor tree"] = function()
  local layout = require("centerish.layout")
  for _, command in ipairs({ "H", "L", "J", "K", "r", "R", "x" }) do
    local first = reset({ min_padding_width = 0 })
    centerish.enable()
    vim.cmd("rightbelow vnew")
    local second = vim.api.nvim_get_current_win()
    settle()
    local original = pads()
    local editors = { [first] = true, [second] = true }
    vim.cmd("wincmd " .. command)
    local expected = layout.editors(vim.fn.winlayout(), editors)
    local focused = vim.api.nvim_get_current_win()
    settle()

    equal(pads(), original, command)
    equal(layout.editors(vim.fn.winlayout(), editors), expected, command)
    local tree = vim.fn.winlayout()
    equal(tree[1], "row", command)
    equal(tree[2][1], { "leaf", original[1] }, command)
    equal(tree[2][#tree[2]], { "leaf", original[2] }, command)
    equal(vim.api.nvim_get_current_win(), focused, command)
  end
end

tests["centered width and idempotent enable"] = function()
  local editor = reset()
  vim.cmd("CenterishEnable")
  settle()

  equal(vim.api.nvim_win_get_width(editor), 80)
  equal(col(editor), 80)

  local original = pads()
  centerish.enable()
  settle()

  equal(pads(), original)
  equal(vim.api.nvim_get_current_win(), editor)
end

tests["callbacks can disable centering without orphaning padding"] = function()
  local editor = reset()
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "centerish",
    once = true,
    callback = centerish.disable,
  })

  centerish.enable()
  settle()

  equal(#pads(), 0)
  equal(vim.fn.winlayout(), { "leaf", editor })
  centerish.enable()
  equal(#pads(), 2)
  centerish.disable()
  settle()
  equal(vim.fn.winlayout(), { "leaf", editor })
end

tests["configuration changes during padding callbacks get a deferred refresh"] = function()
  local editor = reset()
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "centerish",
    once = true,
    callback = function()
      centerish.setup({ width = 80, padding = { left = false, right = false } })
    end,
  })
  centerish.enable()
  settle()
  equal(#pads(), 0)
  equal(vim.fn.winlayout(), { "leaf", editor })
end

tests["callback requests stay ordered and keep their original tab"] = function()
  for _, scenario in ipairs({
    { actions = { "disable", "enable" }, enabled = true },
    { actions = { "toggle", "toggle" }, enabled = true },
    { actions = { "disable", "enable" }, later = "toggle", enabled = false },
  }) do
    local editor = reset()
    local first = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "centerish",
      once = true,
      callback = function()
        for _, action in ipairs(scenario.actions) do
          centerish[action]()
        end
      end,
    })

    centerish.enable()
    if scenario.later then
      centerish[scenario.later]()
    end
    vim.cmd("tabnew")
    local other = vim.api.nvim_get_current_win()
    centerish.enable()
    settle()

    equal(vim.api.nvim_get_current_win(), other)
    equal(#pads(), 2)
    equal(#pads(first), scenario.enabled and 2 or 0)
    vim.api.nvim_set_current_tabpage(first)
    centerish.disable()
    settle()
    equal(vim.fn.winlayout(), { "leaf", editor })
  end
end

tests["queued callback requests skip closed tabs without blocking later requests"] = function()
  reset()
  local first = vim.api.nvim_get_current_tabpage()
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "centerish",
    once = true,
    callback = centerish.disable,
  })
  centerish.enable()
  vim.cmd("tabnew")
  local editor = vim.api.nvim_get_current_win()
  centerish.enable()
  vim.cmd("tabclose 1")
  settle()

  equal(vim.api.nvim_tabpage_is_valid(first), false)
  equal(vim.api.nvim_get_current_win(), editor)
  equal(#pads(), 2)
  centerish.disable()
  settle()
  equal(vim.fn.winlayout(), { "leaf", editor })
end

tests["focus restoration errors preserve failures and allow further operations"] = function()
  for _, fail_action in ipairs({ false, true }) do
    local editor = reset()
    centerish.enable()
    local padding = pads()
    vim.cmd("tabnew")
    local other = vim.api.nvim_get_current_win()
    local second = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_win(editor)
    local closing = vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(padding[1]),
      once = true,
      callback = function()
        vim.api.nvim_set_current_win(other)
        centerish.enable()
        if fail_action then
          error("test layout mutation failure")
        end
      end,
    })
    local entering = vim.api.nvim_create_autocmd("WinEnter", {
      callback = function()
        if vim.api.nvim_get_current_win() == editor then
          error("test focus restoration failure")
        end
      end,
    })

    local ok, err = pcall(centerish.disable)
    pcall(vim.api.nvim_del_autocmd, closing)
    vim.api.nvim_del_autocmd(entering)
    equal(ok, false)
    assert(tostring(err):find("test focus restoration failure", 1, true), tostring(err))
    if fail_action then
      local mutation = assert(tostring(err):find("test layout mutation failure", 1, true))
      local restoration = assert(tostring(err):find("test focus restoration failure", 1, true))
      assert(mutation < restoration, tostring(err))
    end
    vim.v.errmsg = ""
    settle()

    equal(vim.api.nvim_get_current_win(), editor)
    equal(#pads(second), 2)
    centerish.disable()
    equal(vim.fn.winlayout(), { "leaf", editor })
    centerish.enable()
    equal(#pads(), 2)
    centerish.disable()
    settle()
    equal(vim.fn.winlayout(), { "leaf", editor })
  end
end

tests["hiding either padding side preserves the opposite centered margin"] = function()
  local editor = reset()
  centerish.enable()
  settle()
  local centered_left = col(editor)
  local centered_right = col(editor) + vim.api.nvim_win_get_width(editor)

  centerish.setup({ width = 80, padding = { left = true, right = false } })
  settle()

  equal(#pads(), 1)
  equal(col(editor), centered_left)
  equal(vim.api.nvim_win_get_width(editor), 160)

  centerish.setup({ width = 80, padding = { left = false, right = true } })
  settle()

  equal(#pads(), 1)
  equal(col(editor), 0)
  equal(col(editor) + vim.api.nvim_win_get_width(editor), centered_right)
end

tests["terminal resizing uses centered margins for every padding mode"] = function()
  for _, padding in ipairs({
    { left = true, right = false },
    { left = false, right = true },
    { left = true, right = true },
  }) do
    local editor = reset({ padding = padding, min_padding_width = 0 })
    centerish.enable()

    for _, columns in ipairs({ 200, 160, 100, 80, 70, 240 }) do
      vim.o.columns = columns
      vim.cmd("redraw")
      vim.api.nvim_exec_autocmds("VimResized", {})
      settle()

      local spare = math.max(0, columns - 80)
      local left = padding.left and math.floor(spare / 2) or 0
      local right = padding.right and spare - math.floor(spare / 2) or 0
      equal(vim.api.nvim_win_get_width(editor), columns - left - right)
      equal(col(editor), left)
    end
  end
end

tests["left-only padding absorbs a sidebar without moving or resizing the editor"] = function()
  local editor = reset({ padding = { right = false } })
  centerish.enable()
  local tree = sidebar("left")

  equal(col(editor), 80)
  equal(vim.api.nvim_win_get_width(editor), 160)
  equal(vim.api.nvim_win_get_width(tree), 20)

  vim.api.nvim_win_close(tree, true)
  settle()

  equal(col(editor), 80)
  equal(vim.api.nvim_win_get_width(editor), 160)
end

tests["opening and closing a tree preserves editor position and right padding"] = function()
  local editor = reset()
  centerish.enable()
  settle()
  local right = pads()[2]
  local tree = sidebar("left")

  equal(col(editor), 80)
  equal(vim.api.nvim_win_get_width(editor), 80)
  equal(pads()[2], right)
  equal(vim.api.nvim_win_get_width(tree), 20)
  equal(vim.api.nvim_win_get_width(pads()[1]), 58)

  vim.api.nvim_win_close(tree, true)
  settle()

  equal(col(editor), 80)
  equal(vim.api.nvim_win_get_width(editor), 80)
end

tests["enable with an existing tree preserves its identity and width"] = function()
  local editor = reset()
  local tree = sidebar("left", "neo-tree")
  local buf = vim.api.nvim_win_get_buf(tree)

  centerish.enable()
  settle()

  equal(col(tree), 0)
  equal(vim.api.nvim_win_get_buf(tree), buf)
  equal(vim.api.nvim_win_get_width(tree), 20)
  equal(col(editor), 80)
  equal(vim.api.nvim_win_get_width(editor), 80)
end

tests["sidebars without width preservation accept file-switch resizing"] = function()
  for _, side in ipairs({ "left", "right" }) do
    for _, setting in ipairs({ side, { side = side }, { side = side, preserve_width = false } }) do
      local editor = reset({
        sidebars = {
          ["fixed-sidebar"] = { side = "left", preserve_width = true },
          ["test-sidebar"] = setting,
        },
      })
      local fixed = sidebar("left", "fixed-sidebar")
      local tree = sidebar(side, "test-sidebar")
      vim.api.nvim_win_set_width(fixed, 20)
      vim.api.nvim_win_set_width(tree, 20)
      centerish.enable()
      settle()

      for _, width in ipairs({ 40, 15 }) do
        local buf = vim.api.nvim_create_buf(false, false)
        vim.api.nvim_create_autocmd("BufWinEnter", {
          buffer = buf,
          once = true,
          callback = function()
            vim.api.nvim_win_set_width(tree, width)
          end,
        })
        vim.api.nvim_win_set_buf(editor, buf)
        settle()

        equal(vim.api.nvim_win_get_width(tree), width)
        equal(vim.api.nvim_win_get_width(fixed), 20)
        equal(vim.api.nvim_win_get_width(editor), 80)
      end
    end
  end
end

tests["sidebar options reject invalid sides and width preservation"] = function()
  reset()
  for _, setting in ipairs({
    true,
    {},
    { side = "middle" },
    { side = false },
    { side = "left", preserve_width = 0 },
    { side = "right", preserve_width = "true" },
  }) do
    local ok, err = pcall(centerish.setup, { sidebars = { ["test-sidebar"] = setting } })
    equal(ok, false)
    assert(tostring(err):find("sidebar", 1, true))
  end
end

tests["sidebars keep requested widths across file and split changes"] = function()
  for _, preserve in ipairs({ false, true }) do
    for _, ea in ipairs({ false, true }) do
      for _, close_left in ipairs({ false, true }) do
        local left = reset({
          width = 120,
          min_padding_width = 20,
          sidebars = {
            ["test-sidebar"] = preserve and { side = "left", preserve_width = true } or "left",
          },
        })
        vim.o.columns = 400
        vim.o.equalalways = ea
        vim.cmd("redraw")
        vim.cmd("rightbelow vnew")
        local right = vim.api.nvim_get_current_win()
        local tree = sidebar("left", "test-sidebar")
        vim.api.nvim_win_set_width(tree, 40)
        local keep = close_left and right or left
        local close = close_left and left or right
        vim.api.nvim_set_current_win(keep)
        centerish.enable()
        settle()
        equal(vim.api.nvim_win_get_width(tree), 40)

        for _ = 1, 2 do
          -- CodeDiff loads the next file before closing the absent side, then
          -- sizes the remaining pane against the full tab width.
          vim.api.nvim_win_set_buf(keep, vim.api.nvim_create_buf(false, false))
          vim.api.nvim_win_close(close, true)
          vim.api.nvim_win_set_width(tree, 40)
          vim.api.nvim_win_set_width(keep, vim.o.columns - 41)
          settle()

          equal(vim.api.nvim_win_get_width(tree), 40)
          equal(vim.api.nvim_win_get_width(keep), 120)
          equal(vim.api.nvim_get_current_win(), keep)
          equal(vim.wo[tree].winfixwidth, true)

          -- Consecutive added files reuse the same single pane.
          for _ = 1, 2 do
            vim.api.nvim_win_set_buf(keep, vim.api.nvim_create_buf(false, false))
            vim.api.nvim_win_set_width(tree, 40)
            vim.api.nvim_win_set_width(keep, vim.o.columns - 41)
            settle()

            equal(vim.api.nvim_win_get_width(tree), 40)
            equal(vim.api.nvim_win_get_width(keep), 120)
          end

          vim.cmd(close_left and "leftabove vnew" or "rightbelow vnew")
          close = vim.api.nvim_get_current_win()
          local available = vim.api.nvim_win_get_width(keep) + vim.api.nvim_win_get_width(close)
          vim.api.nvim_win_set_width(keep, math.floor(available / 2))
          vim.api.nvim_win_set_width(close, available - math.floor(available / 2))
          vim.api.nvim_win_set_width(tree, 40)
          vim.api.nvim_set_current_win(keep)
          settle()

          equal(vim.api.nvim_win_get_width(tree), 40)
          equal(vim.api.nvim_win_get_width(keep) + vim.api.nvim_win_get_width(close), 240)
        end

        vim.api.nvim_win_set_width(tree, 50)
        vim.api.nvim_exec_autocmds("WinResized", {})
        settle()
        equal(vim.api.nvim_win_get_width(tree), 50)
        vim.api.nvim_win_set_buf(keep, vim.api.nvim_create_buf(false, false))
        vim.api.nvim_win_set_width(tree, 40)
        settle()
        equal(vim.api.nvim_win_get_width(tree), preserve and 50 or 40)
      end
    end
  end
end

tests["buffer switches beside a sidebar keep unequal editor proportions"] = function()
  local left = reset({ min_padding_width = 0 })
  vim.o.columns = 400
  vim.o.equalalways = false
  vim.cmd("rightbelow vnew")
  local right = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(left, 60)
  local tree = sidebar("left")
  centerish.enable()
  settle()

  local widths = { vim.api.nvim_win_get_width(left), vim.api.nvim_win_get_width(right) }
  assert(widths[1] ~= widths[2])
  for _, win in ipairs({ left, right }) do
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, false))
    settle()
    equal({ vim.api.nvim_win_get_width(left), vim.api.nvim_win_get_width(right) }, widths)
    equal(vim.api.nvim_win_get_width(tree), 20)
    equal(vim.api.nvim_get_current_win(), right)
  end
end

tests["buffer switches without sidebars retain explicit Lua editor resizing"] = function()
  local editor = reset({ min_padding_width = 0 })
  centerish.enable()
  settle()
  vim.api.nvim_win_set_width(editor, 90)
  vim.api.nvim_win_set_buf(editor, vim.api.nvim_create_buf(true, false))
  settle()
  equal(vim.api.nvim_win_get_width(editor), 90)
end

tests["right sidebar consumes right padding only"] = function()
  local editor = reset({ sidebars = { outline = "right" } })
  centerish.enable()
  settle()
  sidebar("right", "outline")

  equal(col(editor), 80)
  equal(vim.api.nvim_win_get_width(editor), 80)
  equal(vim.api.nvim_win_get_width(pads()[1]), 79)
  equal(vim.api.nvim_win_get_width(pads()[2]), 58)
end

tests["vertical and horizontal splits remain after disable"] = function()
  local first = reset()
  centerish.enable()

  vim.cmd("vsplit")
  local second = vim.api.nvim_get_current_win()
  settle()

  equal(col(pads()[1]), 0)
  equal(vim.api.nvim_win_get_width(pads()[1]), 38)

  vim.cmd("split")
  local third = vim.api.nvim_get_current_win()
  settle()

  equal(vim.api.nvim_win_get_width(pads()[1]), 38)

  centerish.disable()
  settle()

  equal(#pads(), 0)
  for _, win in ipairs({ first, second, third }) do
    assert(vim.api.nvim_win_is_valid(win), "user window was closed")
  end
  equal(#vim.api.nvim_tabpage_list_wins(0), 3)
end

tests["preexisting stacked windows have full-height padding"] = function()
  reset()
  vim.cmd("split")
  centerish.enable()
  settle()

  equal(vim.fn.winlayout()[1], "row")
  equal(#vim.fn.winlayout()[2], 3)
end

tests["narrow screens remove padding and restore it when space returns"] = function()
  local editor = reset()
  centerish.enable()

  vim.o.columns = 70
  vim.cmd("redraw")
  vim.api.nvim_exec_autocmds("VimResized", {})
  settle()

  equal(#pads(), 0)
  assert(vim.api.nvim_win_is_valid(editor))

  vim.o.columns = 240
  vim.cmd("redraw")
  vim.api.nvim_exec_autocmds("VimResized", {})
  settle()

  equal(#pads(), 2)
  equal(col(editor), 80)
end

tests["adaptive right growth preserves the left edge and does not shrink"] = function()
  local editor = reset({ adaptive = { enabled = true } })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("x", 120) })
  centerish.enable()
  settle()

  equal(col(editor), 80)
  equal(vim.api.nvim_win_get_width(editor), 120)

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "short" })
  vim.api.nvim_exec_autocmds("TextChanged", {})
  settle()

  equal(vim.api.nvim_win_get_width(editor), 120)

  centerish.disable()
  centerish.enable()
  settle()

  equal(vim.api.nvim_win_get_width(editor), 80)
end

tests["adaptive growth stops at the configured maximum"] = function()
  local editor = reset({ adaptive = { enabled = true, max_width = 110 } })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("x", 200) })
  centerish.enable()
  settle()

  equal(vim.api.nvim_win_get_width(editor), 110)
end

tests["adaptive growth never consumes a sidebar or left padding in right mode"] = function()
  local editor = reset({ adaptive = { enabled = true, max_width = 500 } })
  local tree = sidebar("right", "neo-tree")

  centerish.setup({
    width = 80,
    padding = { right = true },
    sidebars = { ["neo-tree"] = "right" },
    adaptive = { enabled = true, max_width = 500 },
  })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("x", 400) })
  centerish.enable()
  settle()

  equal(col(editor), 80)
  equal(vim.api.nvim_win_get_width(tree), 20)
  equal(vim.api.nvim_win_get_width(editor), 139)
  equal(#pads(), 1)
end

tests["symmetric growth consumes both sides equally"] = function()
  local editor = reset({ adaptive = { enabled = true, direction = "both" } })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("x", 120) })
  centerish.enable()
  settle()

  equal(col(editor), 60)
  equal(vim.api.nvim_win_get_width(editor), 120)
  equal(vim.api.nvim_win_get_width(pads()[1]), vim.api.nvim_win_get_width(pads()[2]))
end

tests["offscreen and folded lines do not trigger growth"] = function()
  local editor = reset({ adaptive = { enabled = true } })
  local lines = {}
  for i = 1, 100 do
    lines[i] = "short"
  end

  lines[80] = string.rep("x", 140)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  centerish.enable()
  settle()

  equal(vim.api.nvim_win_get_width(editor), 80)

  vim.wo.foldmethod = "manual"
  vim.cmd("70,90fold")
  vim.api.nvim_win_set_cursor(editor, { 65, 0 })
  vim.cmd("normal! zt")
  vim.api.nvim_exec_autocmds("WinScrolled", {})
  settle()

  equal(vim.api.nvim_win_get_width(editor), 80)

  vim.cmd("normal! zE")
  vim.api.nvim_exec_autocmds("WinScrolled", {})
  settle()

  equal(vim.api.nvim_win_get_width(editor), 140)
end

tests["tabs are independently enabled and disabled"] = function()
  reset()
  centerish.enable()
  local first = vim.api.nvim_get_current_tabpage()

  vim.cmd("tabnew")
  settle()

  equal(#pads(), 0)

  centerish.enable()
  settle()

  equal(#pads(), 2)

  centerish.disable()
  vim.api.nvim_set_current_tabpage(first)
  settle()

  equal(#pads(), 2)
end

tests["moving the last editor into another tab cleans up its origin"] = function()
  for _, with_sidebar in ipairs({ false, true }) do
    reset()
    centerish.enable()
    local origin = vim.api.nvim_get_current_tabpage()
    local tree = with_sidebar and sidebar("left") or nil
    local buf = vim.api.nvim_get_current_buf()
    vim.cmd("wincmd T")
    local editor = vim.api.nvim_get_current_win()
    local destination = vim.api.nvim_get_current_tabpage()
    settle()
    equal(vim.api.nvim_get_current_tabpage(), destination)
    equal(vim.api.nvim_get_current_win(), editor)
    equal(vim.api.nvim_get_current_buf(), buf)
    equal(#pads(), 0)
    equal(vim.api.nvim_tabpage_is_valid(origin), with_sidebar)
    if tree then
      equal(vim.api.nvim_tabpage_list_wins(origin), { tree })
    else
      equal(#vim.api.nvim_list_tabpages(), 1)
    end
  end
end

tests["background refreshes do not repeat tab entry enable hooks"] = function()
  reset()
  vim.o.columns = 400
  vim.o.equalalways = false
  vim.cmd("rightbelow vnew")
  centerish.enable()
  local origin = vim.api.nvim_get_current_tabpage()
  local visits = 0
  local hook = vim.api.nvim_create_autocmd("TabEnter", {
    callback = function()
      visits = visits + 1
      -- Bound a regression's request loop so the test can report the failure.
      if visits <= 10 then
        centerish.enable()
      end
    end,
  })
  vim.cmd("wincmd T")
  local editor = vim.api.nvim_get_current_win()
  local destination = vim.api.nvim_get_current_tabpage()
  local native_visits = visits
  settle()
  vim.api.nvim_del_autocmd(hook)
  equal(visits, native_visits, "background refresh emitted extra tab-entry events")
  assert(native_visits > 0)
  equal(vim.api.nvim_get_current_tabpage(), destination)
  equal(vim.api.nvim_get_current_win(), editor)
  equal(#pads(origin), 2)
  equal(#pads(destination), 2)
end

tests["padding cannot take focus or appear in the buffer list"] = function()
  local editor = reset()
  centerish.enable()
  settle()
  local pad = pads()[1]
  local buf = vim.api.nvim_win_get_buf(pad)

  equal(vim.bo[buf].buflisted, false)

  -- Neovim 0.10 reports an API error when WinEnter redirects a requested
  -- nvim_set_current_win(). Exercise the user's normal navigation command.
  vim.cmd("wincmd h")
  equal(vim.api.nvim_get_current_win(), editor)

  centerish.disable()
  settle()

  equal(vim.api.nvim_buf_is_valid(buf), false)
end

tests["window navigation crosses padding to reach the sidebar"] = function()
  local editor = reset()
  centerish.enable()
  local tree = sidebar("left")

  vim.cmd("wincmd h")
  equal(vim.api.nvim_get_current_win(), tree)

  vim.cmd("wincmd l")
  equal(vim.api.nvim_get_current_win(), editor)
end

tests["window navigation wraps past either padding side"] = function()
  for _, left_padding in ipairs({ false, true }) do
    for _, right_padding in ipairs({ false, true }) do
      local left = reset({ padding = { left = left_padding, right = right_padding } })
      vim.o.columns = 320
      vim.o.equalalways = false
      vim.cmd("rightbelow vnew")
      local right = vim.api.nvim_get_current_win()
      centerish.enable()
      local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor",
        row = 2,
        col = 2,
        width = 5,
        height = 2,
        focusable = false,
      })
      for _, command in ipairs({ "w", "W" }) do
        vim.api.nvim_set_current_win(left)
        for index = 1, 4 do
          vim.cmd("wincmd " .. command)
          equal(vim.api.nvim_get_current_win(), index % 2 == 1 and right or left)
        end
      end
      vim.api.nvim_set_current_win(left)
      vim.cmd("wincmd h")
      equal(vim.api.nvim_get_current_win(), left_padding and right or left)
      vim.api.nvim_set_current_win(right)
      vim.cmd("wincmd l")
      equal(vim.api.nvim_get_current_win(), right_padding and left or right)
      vim.api.nvim_win_close(float, true)
      settle()
    end
  end
end

tests["forward and backward cycles include sidebars while skipping padding"] = function()
  local left = reset({ sidebars = { review_right = "right" } })
  vim.o.columns = 400
  vim.cmd("rightbelow vnew")
  local right = vim.api.nvim_get_current_win()
  centerish.enable()
  local left_tree = sidebar("left")
  local right_tree = sidebar("right", "review_right")
  for _, scenario in ipairs({
    { command = "w", expected = { left, right, right_tree, left_tree } },
    { command = "W", expected = { right_tree, right, left, left_tree } },
  }) do
    vim.api.nvim_set_current_win(left_tree)
    for _ = 1, 2 do
      for _, win in ipairs(scenario.expected) do
        vim.cmd("wincmd " .. scenario.command)
        equal(vim.api.nvim_get_current_win(), win)
      end
    end
  end
end

tests["closing the last editor leaves no padding or fixed empty window"] = function()
  local editor = reset()
  centerish.enable()
  vim.api.nvim_win_close(editor, true)
  settle()

  equal(#pads(), 0)
  equal(#vim.api.nvim_tabpage_list_wins(0), 1)
  equal(vim.wo.winfixbuf, false)
  equal(vim.wo.winfixwidth, false)
  equal(vim.bo.buftype, "")
end

tests["a buffer callback failure during padding reuse restores editor options"] = function()
  local editor = reset()
  vim.wo.number = true
  centerish.enable()
  vim.api.nvim_win_close(editor, true)
  local hook = vim.api.nvim_create_autocmd("BufEnter", {
    once = true,
    callback = function()
      error("test buffer entry failure after reuse")
    end,
  })
  local ok, err = pcall(centerish.disable)
  pcall(vim.api.nvim_del_autocmd, hook)
  equal(ok, false)
  assert(tostring(err):find("test buffer entry failure after reuse", 1, true), tostring(err))
  equal(vim.bo.buftype, "")
  equal(vim.wo.number, true)
  equal(vim.wo.winfixwidth, false)
  equal(vim.wo.winfixbuf, false)
  vim.v.errmsg = ""
  centerish.disable()
  settle()
  equal(#pads(), 0)
  equal(#vim.api.nvim_tabpage_list_wins(0), 1)
  vim.cmd.enew()
end

tests["a wide sidebar uses all left padding before moving the editor"] = function()
  local editor = reset()
  centerish.enable()
  local tree = sidebar("left")

  vim.api.nvim_win_set_width(tree, 100)
  vim.api.nvim_exec_autocmds("WinResized", {})
  settle()

  equal(col(editor), 101)
  equal(vim.api.nvim_win_get_width(tree), 100)
  equal(vim.api.nvim_win_get_width(editor), 80)

  vim.api.nvim_win_set_width(tree, 190)
  vim.api.nvim_exec_autocmds("WinResized", {})
  settle()

  equal(#pads(), 0)
  equal(vim.api.nvim_win_get_width(tree), 190)
end

tests["adaptive growth counts display cells and gutters"] = function()
  local editor = reset({ adaptive = { enabled = true } })
  vim.wo.number = true
  vim.bo.tabstop = 8
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "\t" .. string.rep("界", 50) })
  centerish.enable()
  settle()

  equal(vim.api.nvim_win_get_width(editor), 108 + vim.fn.getwininfo(editor)[1].textoff)
end

tests["floating windows do not change padding"] = function()
  local editor = reset()
  centerish.enable()

  local floating = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 30,
    height = 5,
  })
  settle()

  equal(col(editor), 80)
  equal(vim.api.nvim_win_get_width(editor), 80)

  centerish.disable()
  assert(vim.api.nvim_win_is_valid(floating))
  vim.api.nvim_win_close(floating, true)
end

tests["adaptive growth funds the split that needs it without shrinking its neighbor"] = function()
  reset({ adaptive = { enabled = true } })
  vim.cmd("rightbelow vnew")
  local right = vim.api.nvim_get_current_win()
  vim.cmd("wincmd h")
  local left = vim.api.nvim_get_current_win()
  centerish.enable()
  settle()
  local previous_left = vim.api.nvim_win_get_width(left)
  local previous_right = vim.api.nvim_win_get_width(right)
  local position = col(left)

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("x", previous_left + 20) })
  vim.api.nvim_exec_autocmds("TextChanged", {})
  settle()

  equal(col(left), position)
  equal(vim.api.nvim_win_get_width(left), previous_left + 20)
  equal(vim.api.nvim_win_get_width(right), previous_right)
end

tests["stacked editors share adaptive growth"] = function()
  local first = reset({ adaptive = { enabled = true } })
  vim.cmd("split")
  centerish.enable()
  settle()

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("x", 120) })
  vim.api.nvim_exec_autocmds("TextChanged", {})
  settle()

  equal(vim.api.nvim_win_get_width(first), 120)
  equal(vim.api.nvim_win_get_width(0), 120)
end

tests["adaptive growth preserves fixed windows and uses their flexible neighbor"] = function()
  for _, direction in ipairs({ "right", "both" }) do
    local left = reset({ adaptive = { enabled = true, direction = direction } })
    vim.o.columns = 400
    vim.o.equalalways = false
    vim.cmd("rightbelow vnew")
    local right = vim.api.nvim_get_current_win()
    centerish.enable()
    settle()
    local before = vim.api.nvim_win_get_width(right)
    vim.wo[right].winfixwidth = true
    vim.api.nvim_buf_set_lines(
      vim.api.nvim_win_get_buf(right),
      0,
      -1,
      false,
      { string.rep("x", 120) }
    )
    vim.api.nvim_buf_set_lines(
      vim.api.nvim_win_get_buf(left),
      0,
      -1,
      false,
      { string.rep("x", 101) }
    )
    vim.api.nvim_exec_autocmds("TextChanged", {})
    settle()
    equal(vim.api.nvim_win_get_width(right), before)
    equal(vim.wo[right].winfixwidth, true)
    assert(vim.api.nvim_win_get_width(left) >= 101)
    assert(vim.api.nvim_win_get_width(left) <= 102)
  end
end

tests["adaptive growth cannot expand a column sharing a fixed editor"] = function()
  for _, nested in ipairs({ false, true }) do
    local first = reset({ adaptive = { enabled = true, max_width = 250 } })
    vim.o.columns = 400
    if nested then
      vim.cmd("rightbelow vnew")
    end
    vim.cmd("botright new")
    local fixed = vim.api.nvim_get_current_win()
    centerish.enable()
    settle()
    local before = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype ~= "centerish" then
        before[win] = vim.api.nvim_win_get_width(win)
      end
    end
    vim.wo[fixed].winfixwidth = true
    vim.api.nvim_buf_set_lines(
      vim.api.nvim_win_get_buf(first),
      0,
      -1,
      false,
      { string.rep("x", 230) }
    )
    vim.api.nvim_exec_autocmds("TextChanged", {})
    settle()
    for win, width in pairs(before) do
      equal(vim.api.nvim_win_get_width(win), width)
    end
    equal(vim.wo[fixed].winfixwidth, true)
  end
end

tests["adaptive growth can expand a nested column with one fixed child"] = function()
  local left = reset({ adaptive = { enabled = true, max_width = 250 } })
  vim.o.columns = 400
  vim.cmd("rightbelow vnew")
  local right = vim.api.nvim_get_current_win()
  vim.cmd("botright new")
  local bottom = vim.api.nvim_get_current_win()
  centerish.enable()
  settle()
  local before = vim.api.nvim_win_get_width(left)
  vim.wo[left].winfixwidth = true
  vim.api.nvim_buf_set_lines(
    vim.api.nvim_win_get_buf(right),
    0,
    -1,
    false,
    { string.rep("x", 120) }
  )
  vim.api.nvim_exec_autocmds("TextChanged", {})
  settle()
  equal(vim.api.nvim_win_get_width(left), before)
  equal(vim.api.nvim_win_get_width(right), 120)
  equal(vim.api.nvim_win_get_width(bottom), before + 121)
end

tests["one quit exits with either padding layout"] = function()
  for _, right in ipairs({ false, true }) do
    local result = vim
      .system({
        vim.v.progpath,
        "--clean",
        "--headless",
        "--cmd",
        "lua vim.opt.runtimepath:prepend(" .. string.format("%q", vim.fn.getcwd()) .. ")",
        "-c",
        "lua vim.o.columns = 240; require('centerish').setup({padding={right="
          .. tostring(right)
          .. "}}); require('centerish').enable()",
        "-c",
        "quit",
        "-c",
        "cquit 42",
      }, { text = true })
      :wait(5000)
    equal(result.code, 0, result.stderr)
  end
end

tests["refused quit preserves unsaved text and restores padding"] = function()
  local editor = reset()
  centerish.enable()
  local padding = pads()
  local namespace = vim.api.nvim_create_namespace("test_padding")
  vim.api.nvim_win_set_hl_ns(padding[2], namespace)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })

  local ok = pcall(vim.cmd.quit)
  equal(ok, false)

  vim.v.errmsg = ""
  settle()

  assert(vim.api.nvim_win_is_valid(editor))
  equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "unsaved" })
  equal(vim.bo.modified, true)
  equal(#pads(), 2)
  equal(pads(), padding)
  equal(vim.api.nvim_get_hl_ns({ winid = padding[2] }), namespace)
  equal(vim.wo[padding[1]].previewwindow, false)
  equal(vim.api.nvim_win_get_config(padding[2]).relative, "")
end

tests["final quit does not redraw the editor at the left edge"] = function()
  local check = dofile("tests/quit_ui.lua")
  check(false)
  check(true)
  check(true, "mapping")
  check(true, "namespace")
end

tests["native quits run shutdown hooks once before and after plugin setup"] = function()
  dofile("tests/quit.lua")()
end

tests["final quit preserves the winbar row and active colors"] = function()
  local check = dofile("tests/quit_ui.lua")
  check(false, nil, "winbar")
  check(true, nil, "winbar")
  check(true, "mapping", "winbar")
  check(true, "namespace", "winbar")
  check(true, nil, "dynamic_winbar")
  check(true, "mapping", "dynamic_winbar")
  check(true, "namespace", "dynamic_winbar")
end

tests["final quit preserves explicitly selected winbar colors"] = function()
  local check = dofile("tests/quit_ui.lua")
  check(false, nil, "highlight_winbar")
  check(true, nil, "highlight_winbar")
  check(true, "mapping", "highlight_winbar")
  check(true, "namespace", "highlight_winbar")
end

tests["final quit mirror ignores global floating borders"] = function()
  if vim.fn.exists("+winborder") == 1 then
    local check = dofile("tests/quit_ui.lua")
    check(true, nil, "rounded")
    check(true, nil, "shadow")
  end
end

tests["native quit with a preview window preserves modified buffer checks"] = function()
  dofile("tests/preview.lua")()
end

tests["native sessions restore owned padding and preserve ordinary windows"] = function()
  dofile("tests/session.lua")()
end

tests["a late shutdown edit refuses exit without losing the editor"] = function()
  local editor = reset()
  centerish.enable()
  local hidden = vim.api.nvim_create_buf(true, false)
  local event = vim.api.nvim_create_autocmd("QuitPre", {
    once = true,
    callback = function()
      vim.api.nvim_buf_set_lines(hidden, 0, -1, false, { "unsaved" })
    end,
  })
  local ok = pcall(vim.cmd.quit)
  equal(ok, false)
  pcall(vim.api.nvim_del_autocmd, event)
  vim.v.errmsg = ""
  settle()
  assert(vim.api.nvim_win_is_valid(editor))
  equal(vim.api.nvim_buf_get_lines(hidden, 0, -1, false), { "unsaved" })
  equal(vim.bo[hidden].modified, true)
  equal(#pads(), 2)
  vim.api.nvim_buf_delete(hidden, { force = true })
end

tests["quit closes the current tab without leaving padding behind"] = function()
  reset()
  local first = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  local second = vim.api.nvim_get_current_tabpage()
  centerish.enable()
  vim.cmd("quit")
  settle()

  equal(vim.api.nvim_tabpage_is_valid(second), false)
  equal(vim.api.nvim_get_current_tabpage(), first)
end

tests["minimum padding hides below its threshold and returns at the boundary"] = function()
  local editor = reset({ min_padding_width = 10, padding = { right = false } })
  centerish.enable()

  for _, columns in ipairs({ 102, 101, 102 }) do
    vim.o.columns = columns
    vim.cmd("redraw")
    vim.api.nvim_exec_autocmds("VimResized", {})
    settle()

    if columns == 102 then
      equal(#pads(), 1)
      equal(vim.api.nvim_win_get_width(pads()[1]), 10)
      equal(vim.api.nvim_win_get_width(editor), 91)
    else
      equal(#pads(), 0)
      equal(vim.api.nvim_win_get_width(editor), 101)
    end
  end
end

tests["minimum padding is applied per side after sidebar space is deducted"] = function()
  local editor = reset({ min_padding_width = 60 })
  centerish.enable()
  local tree = sidebar("left")

  equal(#pads(), 1)
  equal(vim.api.nvim_win_get_width(pads()[1]), 79)
  equal(col(editor), 21)
  equal(vim.api.nvim_win_get_width(tree), 20)

  vim.api.nvim_win_close(tree, true)
  settle()

  equal(#pads(), 2)
  equal(col(editor), 80)
end

tests["adaptive growth removes padding that falls below the minimum"] = function()
  local editor = reset({ min_padding_width = 10, adaptive = { enabled = true } })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("x", 150) })
  centerish.enable()
  settle()

  equal(#pads(), 1)
  equal(col(editor), 80)
  equal(vim.api.nvim_win_get_width(editor), 160)
end

tests["minimum padding rejects invalid values"] = function()
  reset()
  for _, value in ipairs({ -1, 1.5, "10", false }) do
    local ok, err = pcall(centerish.setup, { min_padding_width = value })
    equal(ok, false)
    assert(tostring(err):find("min_padding_width", 1, true))
  end
end

local failed = 0
for name, test in vim.spairs(tests) do
  local ok, err = xpcall(test, debug.traceback)
  if ok then
    io.stdout:write("PASS " .. name .. "\n")
  else
    failed = failed + 1
    io.stderr:write("FAIL " .. name .. "\n" .. err .. "\n")
  end
end

if failed > 0 then
  vim.cmd("cquit " .. failed)
end

vim.cmd("qa!")

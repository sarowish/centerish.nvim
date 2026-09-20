-- Drive an attached UI: a successful exit alone cannot detect a final-frame jump.
return function(right, highlight_mode, appearance_mode)
  local expected_column = 80
  local grid, positions, hooks = {}, {}, {}
  local cell_highlights, highlights = {}, {}
  local background
  local watching = false
  local marker = "QUIT_MARKER"

  local function marker_position(text)
    for row, cells in pairs(grid) do
      for col = 1, 240 - #text do
        local matches = true
        for i = 1, #text do
          if cells[col + i - 1] ~= text:sub(i, i) then
            matches = false
            break
          end
        end
        if matches then
          return { row = row, col = col - 1 }
        end
      end
    end
  end
  local wrapped, display_error, appearance, bar, bar_appearance

  local function sample()
    local result = {}
    for _, col in ipairs({ 80, 159, 160, 200 }) do
      local attrs = highlights[cell_highlights[0] and cell_highlights[0][col + 1]] or {}
      result[#result + 1] = { grid[0] and grid[0][col + 1] or " ", attrs.background or background }
    end
    return result
  end

  local function sample_bar()
    local result = {}
    for col = 80, 159 do
      local attrs = highlights[cell_highlights[0] and cell_highlights[0][col + 1]] or {}
      result[#result + 1] = { grid[0] and grid[0][col + 1] or " ", attrs }
    end
    return result
  end

  local child = dofile("tests/child.lua").start({
    name = "quit",
    on_notification = function(name, args)
      if name == "centerish_test_hook" then
        hooks[#hooks + 1] = table.concat(args, " ")
      elseif name == "redraw" then
        for _, event in ipairs(args) do
          if event[1] == "grid_line" then
            for i = 2, #event do
              local line = event[i]
              if line[1] == 1 then
                grid[line[2]] = grid[line[2]] or {}
                cell_highlights[line[2]] = cell_highlights[line[2]] or {}
                local cells = grid[line[2]]
                local col = line[3] + 1
                local hl = 0
                for _, cell in ipairs(line[4]) do
                  hl = cell[2] or hl
                  for _ = 1, cell[3] or 1 do
                    cells[col] = cell[1]
                    cell_highlights[line[2]][col] = hl
                    col = col + 1
                  end
                end
              end
            end
          elseif event[1] == "grid_clear" then
            grid = {}
            cell_highlights = {}
          elseif event[1] == "hl_attr_define" then
            for i = 2, #event do
              highlights[event[i][1]] = event[i][2]
            end
          elseif event[1] == "default_colors_set" then
            background = event[2][2]
          elseif event[1] == "flush" and watching then
            local position = marker_position(marker)
            if position then
              table.insert(positions, position.col)
              if not vim.deep_equal(sample(), appearance) then
                display_error = "colors or separators changed during quit: "
                  .. vim.inspect(sample())
                  .. " expected "
                  .. vim.inspect(appearance)
              end
            else
              display_error = "editor disappeared during quit"
            end
            local observed = marker_position("WRAP_MARKER")
            if not vim.deep_equal(observed, wrapped) then
              display_error = "wrapped text moved during quit"
            end
            if bar and not vim.deep_equal(marker_position("BAR_MARKER"), bar) then
              display_error = "winbar moved or disappeared during quit"
            end
            if bar and not vim.deep_equal(sample_bar(), bar_appearance) then
              display_error = "winbar text or colors changed during quit"
            end
          end
        end
      end
    end,
  })
  local request = child.request

  local ok, err = xpcall(function()
    request("nvim_ui_attach", { 240, 40, { ext_linegrid = true, rgb = true } })

    local setup = [[
      local root, right, highlight_mode, appearance_mode = ...
      vim.opt.runtimepath:prepend(root)
      vim.o.laststatus = 0
      vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x112233 })
      vim.api.nvim_set_hl(0, "NormalNC", { fg = 0xffffff, bg = 0x445566 })
      vim.api.nvim_set_hl(0, "NormalFloat", { fg = 0xffffff, bg = 0x778899 })
      vim.api.nvim_set_hl(0, "WinSeparator", { fg = 0xabcdef, bg = 0x445566 })
      vim.api.nvim_set_hl(0, "WinBar", { fg = 0xffffff, bg = 0x992211 })
      vim.api.nvim_set_hl(0, "WinBarNC", { fg = 0xffffff, bg = 0x116633 })
      if appearance_mode == "winbar" then
        vim.wo.winbar = "BAR_MARKER"
      elseif appearance_mode == "highlight_winbar" then
        vim.wo.winbar = "%#WinBarNC#BAR_MARKER%*%=%{win_getid()}"
      elseif appearance_mode == "dynamic_winbar" then
        vim.w.bar_title = "BAR_MARKER 50% π"
        vim.api.nvim_set_hl(0, "Error", { fg = 0xaabbcc })
        vim.wo.winbar = "%#Error#%{get(w:, 'bar_title', 'WRONG_BAR')}%*%=%{win_getid()}"
      elseif appearance_mode then
        vim.o.winborder = appearance_mode
      end
      vim.opt.fillchars = {
        vert = "!", wbr = appearance_mode == "dynamic_winbar" and "." or " ",
      }
      if highlight_mode == "mapping" then
        vim.api.nvim_set_hl(0, "TestNormal", { fg = 0xffffff, bg = 0x223344 })
        vim.api.nvim_set_hl(0, "TestNormalNC", { fg = 0xffffff, bg = 0x556677 })
        vim.api.nvim_set_hl(0, "TestSeparator", { fg = 0xabcdef, bg = 0x556677 })
        vim.wo.winhighlight = "Normal:TestNormal,NormalNC:TestNormalNC,WinSeparator:TestSeparator"
        vim.api.nvim_set_hl(0, "TestBar", { fg = 0xffffff, bg = 0x883311 })
        vim.api.nvim_set_hl(0, "TestBarNC", { fg = 0xffffff, bg = 0x117733 })
        vim.wo.winhighlight = vim.wo.winhighlight .. ",WinBar:TestBar,WinBarNC:TestBarNC"
      elseif highlight_mode == "namespace" then
        local namespace = vim.api.nvim_create_namespace("test_editor")
        vim.api.nvim_set_hl(namespace, "Normal", { fg = 0xffffff, bg = 0x223344 })
        vim.api.nvim_set_hl(namespace, "WinSeparator", { fg = 0xabcdef, bg = 0x556677 })
        vim.api.nvim_set_hl(namespace, "WinBar", { fg = 0xffffff, bg = 0x774411 })
        vim.api.nvim_set_hl(namespace, "WinBarNC", { fg = 0xffffff, bg = 0x118833 })
        vim.api.nvim_win_set_hl_ns(0, namespace)
      end
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        "QUIT_MARKER", string.rep("x", 120), "WRAP_MARKER",
      })
      vim.bo.modified = false
      for _, label in ipairs({ "before", "after" }) do
        for _, event in ipairs({ "QuitPre", "ExitPre", "VimLeavePre", "VimLeave" }) do
          vim.api.nvim_create_autocmd(event, {
            callback = function()
              vim.rpcnotify(1, "centerish_test_hook", label, event)
              vim.cmd.redraw()
            end,
          })
        end
        if label == "before" then
          require("centerish").setup({ width = 80, padding = { right = right } })
          require("centerish").enable()
        end
      end
    ]]
    request("nvim_exec_lua", {
      setup,
      { vim.fn.getcwd(), right, highlight_mode or vim.NIL, appearance_mode },
    })
    request("nvim_command", { "redraw" })
    assert(marker_position(marker).col == expected_column, "initial UI layout was not drawn")
    wrapped = assert(marker_position("WRAP_MARKER"), "wrapped text was not drawn")
    if
      appearance_mode == "winbar"
      or appearance_mode == "dynamic_winbar"
      or appearance_mode == "highlight_winbar"
    then
      bar = assert(marker_position("BAR_MARKER"), "initial winbar was not drawn")
      bar_appearance = sample_bar()
    end
    appearance = sample()

    watching = true
    request("nvim_input", { ":q\r" })
    assert(
      vim.wait(3000, function()
        return child.finished
      end),
      "quit did not exit: " .. child.stderr
    )
    assert(
      vim.wait(1000, function()
        return child.drained
      end),
      "shutdown UI output did not drain"
    )
    assert(not display_error, display_error)
    assert(child.exitcode == 0, child.stderr)
    assert(
      vim.deep_equal(hooks, {
        "before QuitPre",
        "after QuitPre",
        "before ExitPre",
        "after ExitPre",
        "before VimLeavePre",
        "after VimLeavePre",
        "before VimLeave",
        "after VimLeave",
      }),
      "shutdown hooks were skipped, duplicated or reordered"
    )
    assert(#positions > 0, "no shutdown UI frames were observed")
    for _, col in ipairs(positions) do
      assert(col == expected_column, "editor shifted to column " .. col .. " during quit")
    end
  end, debug.traceback)

  child.close("sigkill")
  assert(ok, err)
end

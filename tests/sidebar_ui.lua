-- Check rendered frames, since stable window geometry can hide a visible jump.
return function()
  local grid, frames, watching = {}, {}, false
  local marker = "CENTERISH_EDITOR_MARKER"

  local function marker_column()
    for _, cells in pairs(grid) do
      for col = 1, 400 - #marker + 1 do
        local found = true
        for index = 1, #marker do
          if cells[col + index - 1] ~= marker:sub(index, index) then
            found = false
            break
          end
        end
        if found then
          return col - 1
        end
      end
    end
  end

  local child = dofile("tests/child.lua").start({
    name = "sidebar",
    on_notification = function(name, args)
      if name == "redraw" then
        for _, event in ipairs(args) do
          if event[1] == "grid_clear" then
            grid = {}
          elseif event[1] == "grid_line" then
            for index = 2, #event do
              local line = event[index]
              if line[1] == 1 then
                grid[line[2]] = grid[line[2]] or {}
                local col = line[3] + 1
                for _, cell in ipairs(line[4]) do
                  for _ = 1, cell[3] or 1 do
                    grid[line[2]][col] = cell[1]
                    col = col + 1
                  end
                end
              end
            end
          elseif event[1] == "flush" and watching then
            local col = marker_column() or -1
            if frames[#frames] ~= col then
              frames[#frames + 1] = col
            end
          end
        end
      end
    end,
  })
  local request = child.request

  local function settle()
    child.settle(100)
  end

  local ok, err = xpcall(function()
    request("nvim_ui_attach", { 400, 40, { ext_linegrid = true, rgb = true } })
    for _, ea in ipairs({ false, true }) do
      request("nvim_exec_lua", {
        [[
        local root, ea = ...
        vim.opt.runtimepath:prepend(root)
        local centerish = require('centerish')
        centerish.disable()
        vim.cmd('silent! only!')
        vim.cmd('enew!')
        vim.o.equalalways = ea
        vim.o.laststatus = 0
        vim.o.winwidth = 20
        vim.o.winminwidth = 1
        vim.wo.number = false
        vim.wo.relativenumber = false
        vim.wo.signcolumn = 'no'
        vim.wo.winfixwidth = false
        vim.wo.winbar = ''
        _G.editor = vim.api.nvim_get_current_win()
        vim.api.nvim_buf_set_lines(0, 0, -1, false, {'CENTERISH_EDITOR_MARKER'})
        centerish.setup({width = 80})
        centerish.enable()

        -- Sidebar libraries commonly create a split before assigning their buffer.
        vim.api.nvim_create_user_command('SidebarToggle', function()
          if _G.sidebar and vim.api.nvim_win_is_valid(sidebar) then
            vim.api.nvim_set_current_win(editor)
            vim.api.nvim_win_close(sidebar, true)
            sidebar = nil
          else
            local buf = vim.api.nvim_create_buf(false, true)
            vim.bo[buf].filetype = 'NvimTree'
            _G.sidebar = vim.api.nvim_win_call(editor, function()
              vim.cmd('topleft 40vsplit')
              return vim.api.nvim_get_current_win()
            end)
            vim.api.nvim_win_set_buf(sidebar, buf)
            vim.wo[sidebar].winfixwidth = true
            vim.api.nvim_set_current_win(sidebar)
          end
        end, {force = true})
      ]],
        { vim.fn.getcwd(), ea },
      })
      settle()
      for toggle = 1, 4 do
        frames, watching = {}, true
        request("nvim_input", { ":SidebarToggle<CR>" })
        settle()
        watching = false
        assert(
          vim.deep_equal(frames, { 160 }),
          "sidebar toggle "
            .. toggle
            .. ", equalalways="
            .. tostring(ea)
            .. " moved the rendered editor: "
            .. vim.inspect(frames)
        )
        local result = request("nvim_exec_lua", {
          [[
          return {width = vim.api.nvim_win_get_width(editor), error = vim.v.errmsg}
        ]],
          {},
        })
        assert(result.error == "", result.error)
        assert(result.width == 80, "sidebar toggle changed the editor width")
      end
    end
  end, debug.traceback)

  child.close()
  assert(ok, err)
end

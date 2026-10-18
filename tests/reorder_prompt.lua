-- Prompt buffers retain their own Insert resumption state through rotation.
return function()
  local cases = {
    { name = "focused prompt in temporary Normal mode", kind = "focused", count = 1 },
    { name = "focused prompt in temporary Normal mode", kind = "focused", count = 2 },
    { name = "focused prompt after returning to Normal mode", kind = "normal", count = 2 },
    { name = "inactive prompt retains Insert resumption", kind = "inactive", count = 2 },
    { name = "inactive prompt during temporary Normal mode", kind = "temporary", count = 2 },
  }

  for _, case in ipairs(cases) do
    for _, command in ipairs({ "r", "R" }) do
      local native
      for _, centered in ipairs({ false, true }) do
        local context = case.name
          .. " editors="
          .. case.count
          .. " command="
          .. command
          .. " centered="
          .. tostring(centered)
        local child = dofile("tests/child.lua").start({ name = context })
        local request, settle = child.request, child.settle
        local ok, err = xpcall(function()
          request("nvim_ui_attach", {
            centered and 400 or case.count * 80 + case.count - 1,
            40,
            { ext_linegrid = true },
          })
          request("nvim_exec_lua", {
            [=[
              local root, case, centered = ...
              vim.opt.runtimepath:prepend(root)
              vim.o.swapfile = false
              _G.editors = { vim.api.nvim_get_current_win() }
              for index = 2, case.count do
                vim.cmd('rightbelow vnew')
                editors[index] = vim.api.nvim_get_current_win()
              end
              vim.api.nvim_set_current_win(editors[1])
              require('centerish').setup({ width = 80, min_padding_width = 0 })
              if centered then require('centerish').enable() end
              if case.count == 1 then
                local previous = vim.api.nvim_open_win(0, false, {
                  relative = 'editor', row = 0, col = 0, width = 1, height = 1,
                  noautocmd = true,
                })
                vim.api.nvim_win_call(previous, function()
                  vim.api.nvim_set_current_win(editors[1])
                end)
                vim.api.nvim_win_close(previous, true)
              else
                vim.api.nvim_set_current_win(editors[2])
                vim.api.nvim_set_current_win(editors[1])
              end
              _G.prompt_window = editors[
                (case.kind == 'inactive' or case.kind == 'temporary') and 2 or 1
              ]
              local buffer = vim.api.nvim_win_get_buf(prompt_window)
              vim.bo[buffer].buftype = 'prompt'
              vim.fn.prompt_setprompt(buffer, 'test> ')
              if prompt_window ~= editors[1] then
                vim.api.nvim_set_current_win(prompt_window)
              end
              _G.events = {}
              for _, event in ipairs({ 'InsertEnter', 'InsertLeave', 'ModeChanged' }) do
                vim.api.nvim_create_autocmd(event, { callback = function(ev)
                  events[#events + 1] = { ev.event, vim.fn.mode(1) }
                end })
              end
              _G.snapshot = function()
                local ids, order, text = {}, {}, {}
                for index, win in ipairs(editors) do
                  ids[win] = index
                  text[index] = vim.api.nvim_buf_get_lines(
                    vim.api.nvim_win_get_buf(win), 0, -1, false
                  )
                end
                for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                  if ids[win] then order[#order + 1] = ids[win] end
                end
                return {
                  mode = vim.fn.mode(1), focused = ids[vim.api.nvim_get_current_win()],
                  previous = ids[vim.fn.win_getid(vim.fn.winnr('#'))] or 0,
                  order = order, text = text, events = events, error = vim.v.errmsg,
                }
              end
            ]=],
            { vim.fn.getcwd(), case, centered },
          })
          settle()
          if case.kind == "normal" then
            request("nvim_input", { "iabc<C-O><C-W>w<C-W>p<Esc>" })
          elseif case.kind == "inactive" or case.kind == "temporary" then
            request("nvim_input", { "ihello<C-O><C-W>p" })
          end
          settle()
          request("nvim_exec_lua", { "events = {}; vim.v.errmsg = ''", {} })
          local prefix = (case.kind == "focused" or case.kind == "temporary") and "i<C-O>" or ""
          request("nvim_input", { prefix .. "<C-W>" .. command })
          settle()
          local result = { request("nvim_exec_lua", { "return snapshot()", {} }) }
          if case.kind == "inactive" or case.kind == "temporary" then
            request("nvim_exec_lua", { "vim.api.nvim_set_current_win(prompt_window)", {} })
            settle()
            result[#result + 1] = request("nvim_exec_lua", { "return snapshot()", {} })
          end
          request("nvim_input", { "abc" })
          settle()
          result[#result + 1] = request("nvim_exec_lua", { "return snapshot()", {} })
          if centered then
            assert(
              vim.deep_equal(result, native),
              context
                .. "\nexpected: "
                .. vim.inspect(native)
                .. "\nactual: "
                .. vim.inspect(result)
            )
          else
            native = result
          end
        end, debug.traceback)
        child.close()
        assert(ok, err)
      end
    end
  end
end

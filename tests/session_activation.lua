-- User-created tabs wait for adoption after native session sourcing returns.
local function check(timing)
  local children = dofile("tests/child.lua")
  local path = vim.fn.tempname() .. ".vim"
  local scenario
  ---@type centerish.test.Child?
  local child
  local ok, err = xpcall(function()
    for _, case in ipairs({ "after_source", "earlier_hook", "later_hook", "replacing_session" }) do
      scenario = case
      local init = string.format(
        [[
        vim.opt.runtimepath:prepend(%q)
        vim.o.columns = 240
        local function hook()
          vim.api.nvim_create_autocmd('SessionLoadPost', {callback=function()
            vim.schedule(vim.cmd.tabnew)
          end})
        end
      ]],
        vim.fn.getcwd()
      )
      if case == "earlier_hook" then
        init = init .. "hook()\n"
      end
      init = init
        .. "require('centerish').setup({width=80,autocmds={enable_on_tab="
        .. vim.inspect(timing)
        .. "}})\n"
      if case == "later_hook" then
        init = init .. "hook()\n"
      end
      child = children.start({
        name = "session activation: " .. case .. " (" .. tostring(timing) .. ")",
        args = { "--clean", "--headless", "--embed", "-i", "NONE", "--cmd", "lua " .. init },
      })
      child.settle()
      child.request("nvim_exec_lua", {
        [[
        local path, case = ...
        vim.cmd.mksession({path, bang=true})
        vim.cmd.source(path)
        assert(vim.g.SessionLoad == nil, 'native session sourcing has not returned')
        if case == 'after_source' or case == 'replacing_session' then vim.cmd.tabnew() end
        if case == 'replacing_session' then vim.cmd.source(path) end
      ]],
        { path, case },
      })
      child.settle()
      local expected = case == "replacing_session" and { 0 } or { 0, 2 }
      local function check()
        local counts = child.request("nvim_exec_lua", {
          [[
          local counts = {}
          for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            local pads = 0
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
              if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'centerish' then pads = pads + 1 end
            end
            counts[#counts + 1] = pads
          end
          assert(vim.v.errmsg == '', vim.v.errmsg)
          return counts
        ]],
          {},
        })
        assert(
          vim.deep_equal(counts, expected),
          "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(counts)
        )
      end
      check()
      child.request("nvim_command", { "enew" })
      child.settle()
      check()
      child.request("nvim_command", { "tabnew" })
      child.settle()
      expected[#expected + 1] = 2
      check()
      child.close()
      child = nil
    end
  end, debug.traceback)
  if child then
    child.close()
  end
  vim.fn.delete(path)
  assert(ok, tostring(scenario) .. ": " .. tostring(err))
end

return function()
  check(true)
  check("immediate")
end

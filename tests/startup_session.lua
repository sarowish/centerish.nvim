-- Session adoption can finish before VimEnter or before a late initial setup.
local function check(timing)
  local path = vim.fn.tempname() .. ".vim"
  local empty_path = vim.fn.tempname() .. ".vim"
  local scenario = "save"
  local children = dofile("tests/child.lua")
  ---@type centerish.test.Child?
  local child
  local ok, err = xpcall(function()
    child = children.start({ name = "startup session save" })
    child.request("nvim_exec_lua", {
      [[
      local root, path, empty_path = ...
      vim.opt.runtimepath:prepend(root)
      vim.o.columns = 240
      local centerish = require('centerish')
      centerish.setup({width=80})
      centerish.enable()
      vim.cmd.tabnew()
      vim.cmd.mksession({path, bang=true})
      for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        vim.api.nvim_set_current_tabpage(tab)
        centerish.disable()
      end
      vim.cmd.mksession({empty_path, bang=true})
    ]],
      { vim.fn.getcwd(), path, empty_path },
    })
    child.close()
    child = nil

    for _, case in ipairs({
      "normal",
      "settled",
      "vimenter",
      "late_setup",
      "unloaded",
      "unloaded_runtime",
      "late_plugin",
      "require_restore",
    }) do
      scenario = case
      local setup = string.format(
        [[require('centerish').setup({width=80,autocmds={enable_on_startup=%s,enable_on_tab=%s}})]],
        vim.inspect(timing),
        vim.inspect(timing)
      )
      local init = "vim.opt.runtimepath:prepend("
        .. string.format("%q", vim.fn.getcwd())
        .. ")\nvim.o.columns=240\n"
      if case == "late_plugin" then
        init = string.format(
          [[
          vim.o.columns = 240
          vim.api.nvim_create_autocmd('VimEnter', {callback=function()
            vim.schedule(function()
              assert(not package.loaded['centerish.session'])
              vim.opt.runtimepath:prepend(%q)
              vim.cmd('runtime plugin/centerish.lua')
              %s
            end)
          end})
        ]],
          vim.fn.getcwd(),
          setup
        )
      elseif case == "require_restore" then
        init = init
          .. string.format(
            [[
          require('centerish')
          assert(not vim.g.loaded_centerish)
          vim.cmd.source(%q)
          vim.api.nvim_create_autocmd('VimEnter', {callback=function()
            vim.schedule(function() %s end)
          end})
        ]],
            empty_path,
            setup
          )
      end
      if case == "vimenter" then
        init = init
          .. string.format(
            [[
          vim.api.nvim_create_autocmd('VimEnter', {callback=function()
            vim.cmd.source(%q)
            vim.wait(20, function() return false end)
          end})
        ]],
            path
          )
      end
      if case == "unloaded" or case == "unloaded_runtime" then
        init = init
          .. "vim.cmd('runtime plugin/centerish.lua')\nassert(not package.loaded.centerish)\n"
      end
      if case == "late_setup" or case == "unloaded" then
        init = init
          .. (case == "late_setup" and "require('centerish')\n" or "")
          .. "vim.api.nvim_create_autocmd('VimEnter', {callback=function() vim.schedule(function() "
          .. (case == "unloaded" and "assert(not package.loaded.centerish); " or "")
          .. setup
          .. " end) end})\n"
      elseif case ~= "unloaded_runtime" and case ~= "late_plugin" and case ~= "require_restore" then
        init = init .. setup
      end
      local args = { "--clean", "--embed", "--headless", "-i", "NONE", "--cmd", "lua " .. init }
      if case ~= "vimenter" and case ~= "unloaded_runtime" and case ~= "require_restore" then
        vim.list_extend(args, {
          "-S",
          (case == "unloaded" or case == "late_plugin") and empty_path or path,
        })
      end
      if case == "settled" or case == "late_setup" then
        vim.list_extend(args, { "-c", "lua vim.wait(20, function() return false end)" })
      end
      child = children.start({
        name = "startup session: " .. case .. " (" .. tostring(timing) .. ")",
        args = args,
      })
      child.settle(80)
      if case == "unloaded_runtime" then
        child.request("nvim_exec_lua", {
          [[
          local path, timing = ...
          assert(not package.loaded.centerish)
          vim.cmd.source(path)
          assert(not package.loaded.centerish)
          require('centerish').setup({width=80,autocmds={enable_on_startup=timing,enable_on_tab=timing}})
        ]],
          { empty_path, timing },
        })
        child.settle(80)
      end
      local state = child.request("nvim_exec_lua", {
        [[
        local counts = {}
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
          local pads = 0
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'centerish' then pads = pads + 1 end
          end
          counts[#counts + 1] = pads
        end
        return {counts=counts,error=vim.v.errmsg}
      ]],
        {},
      })
      assert(state.error == "", state.error)
      assert(
        vim.deep_equal(
          state.counts,
          (
            case == "unloaded"
            or case == "unloaded_runtime"
            or case == "late_plugin"
            or case == "require_restore"
          )
              and { 0, 0 }
            or { 2, 0 }
        ),
        "restored tabs changed: " .. vim.inspect(state.counts)
      )
      child.request("nvim_command", { "tabnew" })
      child.settle(80)
      assert(
        child.request("nvim_exec_lua", { "return #vim.api.nvim_tabpage_list_wins(0)", {} }) == 3,
        "new tabs did not auto-enable after session restoration"
      )
      child.close()
      child = nil
    end
  end, debug.traceback)
  if child then
    child.close()
  end
  vim.fn.delete(path)
  vim.fn.delete(empty_path)
  assert(ok, scenario .. ": " .. tostring(err))
end

return function()
  check(true)
  check("immediate")
end

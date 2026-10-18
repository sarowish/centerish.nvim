-- Compare native exchanges and rotations with and without padding using real input.
return function()
  local scenario = "initialization"
  local child = dofile("tests/child.lua").start({
    name = "reorder",
    context = function()
      return scenario
    end,
  })
  local request, settle = child.request, child.settle
  local setup = [=[
    local root, opts = ...
    local stack = opts.stack or ''
    vim.opt.runtimepath:prepend(root)
    vim.cmd.cd(root)
    vim.o.swapfile = false
    vim.o.virtualedit = opts.virtualedit or ''
    if _G.reorder_callback then
      vim.api.nvim_del_autocmd(reorder_callback)
      _G.reorder_callback = nil
    end
    local centerish = require('centerish')
    centerish.disable()
    vim.cmd('silent! only!')
    vim.cmd('enew!')
    _G.editors = { vim.api.nvim_get_current_win() }
    for index = 2, opts.count do
      if index == 3 and stack == 'left' then
        vim.api.nvim_set_current_win(editors[1])
      end
      vim.cmd(index == 3 and stack ~= '' and 'belowright new' or 'rightbelow vnew')
      editors[index] = vim.api.nvim_get_current_win()
    end
    for index, win in ipairs(editors) do
      if opts.shared then vim.api.nvim_win_set_buf(win, vim.api.nvim_win_get_buf(editors[1])) end
      vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false, { 'abcdefghijk', 'x', 'abcdefghijk' })
      vim.api.nvim_win_set_cursor(win, { 1, index - 1 })
    end
    if stack == '' then vim.api.nvim_win_set_width(editors[1], 55) end
    vim.api.nvim_set_current_win(editors[opts.focus])
    centerish.setup({ width = 80, padding = opts.padding })
    if opts.centered then centerish.enable() end
    vim.api.nvim_set_current_win(editors[opts.focus == 1 and opts.count or 1])
    vim.api.nvim_set_current_win(editors[opts.focus])
    if opts.history == 'closed' then
      local current = vim.api.nvim_get_current_win()
      local previous = vim.api.nvim_open_win(0, false, {
        relative = 'editor', row = 0, col = 0, width = 1, height = 1,
        style = 'minimal', noautocmd = true,
      })
      vim.api.nvim_win_call(previous, function() vim.api.nvim_set_current_win(current) end)
      vim.api.nvim_win_close(previous, true)
    elseif opts.history == 'self' then
      vim.api.nvim_win_call(editors[opts.focus], function()
        vim.api.nvim_set_current_win(editors[opts.focus == 1 and opts.count or 1])
      end)
    end
    if opts.directory == 'window' then
      vim.cmd.lcd(vim.fn.fnamemodify(root, ':h'))
    elseif opts.directory == 'tab' then
      vim.cmd.tcd(vim.fn.fnamemodify(root, ':h'))
    elseif opts.directory == 'global' then
      vim.cmd.cd(vim.fn.fnamemodify(root, ':h'))
    end
    if opts.callback and opts.callback ~= '' then
      local done = false
      _G.reorder_callback = vim.api.nvim_create_autocmd('WinEnter', { callback = function()
        if not done and vim.api.nvim_get_current_win() == editors[2] then
          done = true
          if opts.callback == 'cursor' then
            vim.api.nvim_win_set_cursor(0, { 3, 5 })
          else
            vim.api.nvim_set_current_win(editors[1])
          end
        end
      end })
    end
    vim.keymap.set('n', '<F6>', '2<C-W>x', { remap = true })
    vim.keymap.set('n', '<F7>', '<C-W>2r', { remap = true })
    vim.fn.setreg('a', '')
    vim.v.errmsg = ''
    _G.snapshot = function()
      local ids, pads, geometry, text, cursors = {}, {}, {}, {}, {}
      for index, win in ipairs(editors) do
        ids[win] = index
        geometry[index] = { vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win) }
        text[index] = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
        cursors[index] = vim.api.nvim_win_call(win, vim.fn.getcurpos)
      end
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if not ids[win] then pads[#pads + 1] = win end
      end
      local function normalize(node)
        if node[1] == 'leaf' then return { 'leaf', ids[node[2]] } end
        local children = {}
        for _, child in ipairs(node[2]) do children[#children + 1] = normalize(child) end
        return { node[1], children }
      end
      return {
        tree = normalize(require('centerish.layout').editors(vim.fn.winlayout(), ids)),
        focused = ids[vim.api.nvim_get_current_win()],
        previous = ids[vim.fn.win_getid(vim.fn.winnr('#'))],
        text = text,
        mode = vim.fn.mode(1),
        cursor = vim.api.nvim_win_get_cursor(0),
        cursors = cursors,
        anchor = vim.fn.getpos('v'),
        register = vim.fn.getreg('a'),
        pads = pads,
        geometry = geometry,
        directory = { vim.fn.getcwd(), vim.fn.getcwd(-1, -1), vim.fn.haslocaldir(), vim.uv.cwd() },
        error = vim.v.errmsg,
      }
    end
  ]=]

  local ok, err = xpcall(function()
    request("nvim_ui_attach", { 400, 40, { ext_linegrid = true } })
    local commands = {
      "<C-W>x",
      "<C-W><C-X>",
      "<C-W>x<C-W>x",
      "1<C-W>x",
      "2<C-W>x",
      "3<C-W>x",
      "9<C-W>x",
      "<C-W>2x",
      "<C-W>r",
      "<C-W><C-R>",
      "<C-W>R",
      "2<C-W>r",
      "<C-W>2R",
      "5<C-W>r",
      "<C-W>r<C-W>x",
    }
    local mixed = { "<C-W>x", "2<C-W>x", "3<C-W>x", "<C-W>r", "<C-W>R" }
    for _, layout in ipairs({
      { count = 2, focus = { 1, 2 }, stack = "", commands = commands },
      { count = 3, focus = { 1, 3 }, stack = "", commands = commands },
      { count = 3, focus = { 2 }, stack = "left", commands = mixed },
      { count = 3, focus = { 3 }, stack = "right", commands = mixed },
      { count = 1, focus = { 1 }, stack = "", commands = mixed },
      {
        count = 4,
        focus = { 1 },
        stack = "",
        commands = { "2<C-W>2x", "5<C-W>r", "<C-W>r<C-W>R", "<F6>", "<F7>" },
      },
      {
        count = 3,
        focus = { 1, 3 },
        stack = "",
        commands = {
          "<C-W><C-W>3x",
          { "<C-W><C-W>", "3x" },
          "<C-W>x<C-W>p",
          { "<C-W>x", "<C-W>p" },
          { "<C-W>r", "<C-W>p" },
        },
      },
      {
        count = 3,
        focus = { 2 },
        stack = "",
        commands = {
          "f<C-W>3x",
          { "f<C-W>", "3x" },
          "g<C-W>3x",
          "d<C-W>3x",
          { "d<C-W>", "3x" },
          '"<C-W>3x',
          "qaf<C-W>3xq@a",
          "qa2<C-W>xq@a",
        },
      },
      {
        count = 3,
        focus = { 3 },
        stack = "",
        commands = {
          { "<C-W>", "x" },
          { "<C-W>2", "x" },
          { "<C-W>", "<C-C>", "3x" },
          "<C-W><Esc>3x",
          "<C-W>0x",
          "<C-W>2<Del>x",
          "2<C-W>2<Del>x",
          "<C-W>2<Del>r",
          "<C-W><BS>x",
          "qa<C-W>2xq@a",
          "qa2<C-W>2rq@a",
          "2<C-W>1h3x",
          "2<C-W>2r",
          "<C-W><M-x>",
          "<C-W><C-S-X>",
          "<C-W><M-r>",
          "<C-W><C-S-R>",
          "<C-W><M-2>x",
        },
      },
      {
        count = 2,
        focus = { 2 },
        stack = "",
        commands = { "v<C-W>x", "V<C-W>x", "<C-V><C-W>x", "i<C-O><C-W>x" },
      },
      {
        count = 2,
        focus = { 2 },
        stack = "",
        shared = true,
        commands = { "vl<C-W>x", "V<C-W>x", "<C-V>l<C-W>x", "v$<C-W>x" },
      },
      {
        count = 3,
        focus = { 3 },
        stack = "",
        commands = {
          "v<C-W>r",
          "V<C-W>R",
          "i<C-O><C-W>r",
        },
      },
      {
        count = 2,
        focus = { 1 },
        stack = "",
        shared = true,
        commands = {
          "vll2<C-W>x",
          "Vj2<C-W>x<Esc><C-W>p",
          "Vj2<C-W>x<Esc><C-W>px",
          "<C-V>lj2<C-W>x<Esc><C-W>p",
          "llvhh2<C-W>x<Esc><C-W>p",
          "8ljv2<C-W>x",
          "v$2<C-W>x<Esc>jj",
          "Vj<Esc>gg0vll2<C-W>xgvd",
          "vll<Esc>gg0Vj2<C-W>xgvd",
          "<C-W>rVj<Esc>gg0vll2<C-W>xgvd",
        },
      },
      {
        count = 3,
        focus = { 1 },
        stack = "",
        commands = { "vll2<C-W>xjj", "vll2<C-W>x<C-W>pgvx" },
      },
      {
        count = 3,
        focus = { 1, 3 },
        stack = "",
        shared = true,
        commands = { "vll3<C-W>x", "Vj3<C-W>x", "<C-V>j3<C-W>x" },
      },
      {
        count = 3,
        focus = { 1, 3 },
        stack = "",
        history = "self",
        commands = { "1<C-W>x", "<C-W>r<C-W>p", "<C-W>R<C-W>p" },
      },
      {
        count = 2,
        focus = { 1 },
        stack = "",
        shared = true,
        virtualedit = "block",
        commands = { "j<C-V>5l2<C-W>x", "j<C-V>5l2<C-W>x<Esc><C-W>p" },
      },
      {
        count = 2,
        focus = { 1 },
        stack = "",
        shared = true,
        virtualedit = "all",
        commands = { "j5lv2<C-W>x<Esc>jj" },
      },
      {
        count = 3,
        focus = { 1 },
        stack = "",
        history = "closed",
        commands = { "<C-W>r<C-W>p", "<C-W>R<C-W>p" },
      },
      {
        count = 3,
        focus = { 1, 3 },
        stack = "",
        shared = true,
        callback = "cursor",
        commands = { "<C-W>x", "vll2<C-W>x" },
      },
      {
        count = 3,
        focus = { 1, 3 },
        stack = "",
        shared = true,
        callback = "focus",
        commands = { "<C-W>x", "2<C-W>x", "vll2<C-W>x" },
      },
      {
        count = 1,
        focus = { 1 },
        stack = "",
        directory = "window",
        commands = { "<C-W>r", "<C-W>R" },
      },
      {
        count = 3,
        focus = { 1 },
        stack = "",
        history = "self",
        directory = "window",
        commands = { "<C-W>r", "<C-W>R", "<C-W>R<C-W>p" },
      },
      {
        count = 3,
        focus = { 1 },
        stack = "",
        history = "closed",
        directory = "window",
        commands = { "<C-W>r", "<C-W>R" },
      },
      {
        count = 3,
        focus = { 1, 3 },
        stack = "",
        directory = "tab",
        commands = { "<C-W>r", "<C-W>R" },
      },
      {
        count = 3,
        focus = { 1 },
        stack = "",
        directory = "global",
        commands = { "<C-W>R" },
      },
    }) do
      for _, focus in ipairs(layout.focus) do
        for _, command in ipairs(layout.commands) do
          for _, padding in ipairs({
            { left = true, right = true },
            { left = true, right = false },
            { left = false, right = true },
          }) do
            local native
            for _, centered in ipairs({ false, true }) do
              local opts = {
                count = layout.count,
                focus = focus,
                padding = padding,
                centered = centered,
                stack = layout.stack,
                shared = layout.shared or false,
                history = layout.history or "",
                virtualedit = layout.virtualedit or "",
                callback = layout.callback or "",
                directory = layout.directory or "",
              }
              scenario = vim.inspect(command) .. " " .. vim.inspect(opts)
              request("nvim_exec_lua", { setup, { vim.fn.getcwd(), opts } })
              settle()
              local before = request("nvim_exec_lua", { "return snapshot()", {} })
              -- Native rotation rejects a row containing another split. Dismiss its prompt
              -- so the comparison can check that Centerish preserves the same error.
              for _, keys in ipairs(type(command) == "table" and command or { command }) do
                request("nvim_input", { keys .. (layout.stack == "left" and "<CR>" or "") })
                settle()
              end
              local after = request("nvim_exec_lua", { "return snapshot()", {} })
              if after.mode ~= "n" then
                request("nvim_input", { "<Esc>" })
                settle(20)
              end
              assert(
                vim.deep_equal(after.geometry, before.geometry),
                scenario .. ": operation resized editing windows"
              )
              if centered then
                assert(
                  vim.deep_equal(after.tree, native.tree),
                  scenario .. ": editor order changed"
                )
                assert(
                  after.focused == native.focused,
                  scenario
                    .. ": operation focus changed "
                    .. tostring(after.focused)
                    .. " ~= "
                    .. tostring(native.focused)
                )
                local keys = type(command) == "table" and table.concat(command) or command
                if not keys:find("<C%-W><C%-W>") then
                  assert(after.previous == native.previous, scenario .. ": previous window changed")
                end
                assert(vim.deep_equal(after.text, native.text), scenario .. ": buffer text changed")
                assert(
                  vim.deep_equal(after.directory, native.directory),
                  scenario .. ": directory or directory scope changed"
                )
                assert(after.register == native.register, scenario .. ": recorded macro changed")
                assert(after.mode == native.mode, scenario .. ": mode changed")
                assert(vim.deep_equal(after.cursor, native.cursor), scenario .. ": cursor changed")
                assert(
                  vim.deep_equal(after.cursors, native.cursors),
                  scenario
                    .. ": window cursor or preferred column changed\nexpected: "
                    .. vim.inspect(native.cursors)
                    .. "\nactual: "
                    .. vim.inspect(after.cursors)
                )
                if after.mode == "v" or after.mode == "V" or after.mode == "\22" then
                  assert(
                    vim.deep_equal(after.anchor, native.anchor),
                    scenario .. ": selection changed"
                  )
                end
                assert(after.error == native.error, scenario .. ": native error changed")
                assert(
                  vim.deep_equal(after.pads, before.pads),
                  scenario .. ": padding was recreated"
                )
              else
                native = after
              end
            end
          end
        end
      end
    end
    -- Ex input stays native, including when setup has installed input handling
    -- but centering is disabled.
    for _, centered in ipairs({ false, true }) do
      scenario = "native Ex input centered=" .. tostring(centered)
      request("nvim_exec_lua", {
        setup,
        {
          vim.fn.getcwd(),
          {
            count = 3,
            focus = 1,
            padding = { left = true, right = true },
            centered = centered,
          },
        },
      })
      settle()
      request("nvim_exec_lua", {
        [=[
          vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'abcdefghijk', 'x', 'abcdefghijk' })
          _G.ex_tree, _G.ex_focus = vim.fn.winlayout(), vim.api.nvim_get_current_win()
        ]=],
        {},
      })
      request("nvim_input", { "8lj:let g:seen=1<CR>j" })
      settle()
      request("nvim_exec_lua", {
        [=[
          assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 3, 8 }), 'Ex reset cursor column')
          assert(vim.fn.getcurpos()[5] == 9, 'Ex reset preferred column')
          assert(vim.g.seen == 1, 'Ex command did not execute')
        ]=],
        {},
      })
      for _, command in ipairs({ "2wincmd x", "5wincmd r" }) do
        request("nvim_input", { ":silent! sandbox " .. command .. "<CR>" })
        settle()
        request("nvim_exec_lua", {
          [=[
            assert(vim.v.errmsg:find('E48:', 1, true), 'Missing native sandbox error')
            assert(vim.deep_equal(vim.fn.winlayout(), ex_tree), 'Rejected Ex changed layout')
            assert(vim.api.nvim_get_current_win() == ex_focus, 'Rejected Ex changed focus')
            vim.v.errmsg = ''
          ]=],
          {},
        })
      end
      request("nvim_input", { ":.wincmd x<CR>" })
      settle()
      request("nvim_exec_lua", {
        "assert(vim.fn.histget(':', -1) == '.wincmd x', 'Ex command history was rewritten')",
        {},
      })
      request("nvim_input", { "<C-W>l" })
      settle()
      request("nvim_exec_lua", { "ex_focus = vim.api.nvim_get_current_win()", {} })
      request("nvim_input", { "@:" })
      settle()
      request("nvim_exec_lua", {
        [=[
          assert(vim.deep_equal(vim.fn.winlayout(), ex_tree), 'Ex replay changed layout')
          assert(vim.api.nvim_get_current_win() == ex_focus, 'Ex replay changed focus')
          assert(vim.v.errmsg == '', vim.v.errmsg)
        ]=],
        {},
      })
    end
  end, debug.traceback)

  child.close()
  assert(ok, err)

  -- Each case starts before setup so existing mappings exercise installation,
  -- rather than replacing Centerish's already-installed prefix afterwards.
  for _, mapping in ipairs({
    "global",
    "buffer",
    "specific",
    "noremap",
    "remap",
    "plug",
    "langmap_rotation",
    "langmap_exchange",
  }) do
    local mapped = dofile("tests/child.lua").start({ name = "window mapping " .. mapping })
    local r, s = mapped.request, mapped.settle
    local passed, failure = xpcall(function()
      r("nvim_ui_attach", { 400, 40, { ext_linegrid = true } })
      r("nvim_exec_lua", {
        [=[
          local root, mapping = ...
          vim.opt.runtimepath:prepend(root)
          vim.o.swapfile = false
          _G.editors = { vim.api.nvim_get_current_win() }
          for i = 2, 3 do
            vim.cmd('rightbelow vnew')
            editors[i] = vim.api.nvim_get_current_win()
          end
          vim.api.nvim_set_current_win(editors[1])
          _G.calls = 0
          if mapping == 'global' or mapping == 'buffer' or mapping == 'specific' then
            vim.keymap.set('n', mapping == 'specific' and '<C-W>x' or '<C-W>', function()
              calls = calls + 1
            end, { buffer = mapping == 'buffer' and 0 or nil })
          elseif mapping == 'plug' then
            vim.keymap.set('n', '<C-W>', '<Plug>(CenterishWindowCommand)')
          else
            vim.keymap.set('n', '<F8>', '2<C-W>x', { remap = mapping == 'remap' })
          end
          require('centerish').setup({ width = 80 })
          require('centerish').enable()
          if mapping == 'langmap_rotation' then vim.o.langmap = 'xr' end
          if mapping == 'langmap_exchange' then vim.o.langmap = 'rx' end
        ]=],
        { vim.fn.getcwd(), mapping },
      })
      s()
      local keys = mapping == "specific" and "<C-W>x"
        or mapping == "plug" and "2<C-W>x"
        or mapping == "langmap_rotation" and "<C-W>x"
        or mapping == "langmap_exchange" and "<C-W>r"
        or (mapping == "global" or mapping == "buffer") and "<C-W>"
        or "<F8>"
      r("nvim_input", { keys })
      s()
      local result = r("nvim_exec_lua", {
        [=[
          local order = {}
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            for i, editor in ipairs(editors) do
              if win == editor then order[#order + 1] = i end
            end
          end
          return {
            order = order, calls = calls, error = vim.v.errmsg,
            focus = vim.api.nvim_get_current_win() == editors[1],
          }
        ]=],
        {},
      })
      local corrected = mapping == "remap" or mapping == "plug" or mapping == "langmap_exchange"
      assert(vim.deep_equal(result.order, corrected and { 2, 1, 3 } or { 1, 2, 3 }), mapping)
      assert(
        result.calls
          == ((mapping == "global" or mapping == "buffer" or mapping == "specific") and 1 or 0),
        mapping
      )
      assert(result.error == "", result.error)
      if mapping:match("^langmap_") then
        assert(
          result.focus == (mapping == "langmap_rotation"),
          mapping .. ": translated command changed"
        )
      end
    end, debug.traceback)
    mapped.close()
    assert(passed, failure)
  end
end

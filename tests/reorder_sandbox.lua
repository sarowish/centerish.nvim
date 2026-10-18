-- Restricted execution keeps native window commands, including padding.
return function()
  local cases = {
    -- Both three editors and five physical windows return to their original order.
    { name = "permitted execution", keys = "3lV15<C-W>r2l", sandbox = false },
    { name = "empty prior error", keys = "3l<C-W>2r2l", errmsg = "" },
    { name = "exchange", keys = "3l<C-W>x", focus = 3 },
    { name = "counted exchange", keys = "3l<C-W>2x" },
    { name = "multiplied exchange", keys = "3l2<C-W>2x" },
    { name = "deleted exchange count", keys = "3l2<C-W>2<Del>x" },
    { name = "rotation", keys = "3l<C-W>r2l" },
    { name = "counted rotation", keys = "3l2<C-W>2r2l" },
    { name = "reverse rotation", keys = "3l<C-W>2R2l" },
    { name = "visual rotation", keys = "3lV<C-W>2r2l" },
    { name = "exchange macro", keys = "3l@a2l", macro = "<C-W>2x" },
    { name = "rotation macro", keys = "3l@a2l", macro = "2<C-W>2r" },
    { name = "recording around rotation", keys = "3l<C-W>2r2l", recording = true },
    { name = "statusline rotation", keys = "3l<C-W>r2l", evaluation = true },
    {
      name = "statusline terminal reverse rotation",
      keys = "3l<C-W>R2l",
      evaluation = true,
      terminal = true,
    },
    { name = "statusline initial count", keys = "3l2<C-W>r2l", evaluation = true },
    {
      name = "statusline terminal suffix count",
      keys = "3l<C-W>2R2l",
      evaluation = true,
      terminal = true,
    },
    {
      name = "statusline terminal multiplied count",
      keys = "3l2<C-W>2r2l",
      evaluation = true,
      terminal = true,
    },
    { name = "statusline visual rotation", keys = "3lV<C-W>2r2l", evaluation = true },
  }
  for _, silent in ipairs({ false, true }) do
    for _, case in ipairs(cases) do
      local expected
      for _, native in ipairs({ true, false }) do
        local context = case.name
          .. " silent="
          .. tostring(silent)
          .. " native="
          .. tostring(native)
        local child = dofile("tests/child.lua").start({ name = context })
        local request, settle = child.request, child.settle
        local ok, err = xpcall(function()
          request("nvim_ui_attach", { 400, 40, { ext_linegrid = true } })
          request("nvim_exec_lua", {
            [=[
              local root, case, native = ...
              vim.opt.runtimepath:prepend(root)
              vim.o.swapfile = false
              _G.editors = { vim.api.nvim_get_current_win() }
              for index = 2, 3 do
                vim.cmd('rightbelow vnew')
                editors[index] = vim.api.nvim_get_current_win()
              end
              for _, win in ipairs(editors) do
                vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false,
                  { 'abcdefghijk', 'abcdefghijk', 'abcdefghijk' })
              end
              vim.api.nvim_set_current_win(editors[case.focus or 1])
              require('centerish').setup({ width = 80 })
              require('centerish').enable()
              if case.terminal then
                vim.api.nvim_win_call(editors[2], function()
                  local channel = vim.api.nvim_open_term(0, {})
                  vim.api.nvim_chan_send(channel, 'terminal content\r\nsecond line')
                end)
              end
              if native then
                for _, mode in ipairs({ 'n', 'x' }) do
                  vim.keymap.set(mode, '<C-W>', '<C-W>')
                end
              end
              vim.api.nvim_set_current_win(editors[3])
              vim.api.nvim_set_current_win(editors[case.focus or 1])
              _G.role = function(win)
                for index, editor in ipairs(editors) do
                  if win == editor then return tostring(index) end
                end
                if vim.api.nvim_win_is_valid(win) then
                  local metadata = require('centerish.session').read(vim.api.nvim_win_get_buf(win))
                  if metadata then return metadata.side end
                end
                return 'other'
              end
              _G.seen = {}
              local function observe(event)
                seen[#seen + 1] = {
                  event.event, role(vim.api.nvim_get_current_win()),
                  vim.v.count, vim.v.count1, vim.v.prevcount,
                }
              end
              vim.api.nvim_create_autocmd('WinEnter', { callback = observe })
              vim.api.nvim_create_autocmd('ModeChanged', { pattern = 'V:n', callback = observe })
              _G.helper_events = {}
              if case.evaluation then
                vim.cmd('lcd /tmp')
                vim.api.nvim_create_autocmd({
                  'WinNew', 'WinClosed', 'BufWinEnter', 'BufWinLeave', 'OptionSet',
                }, { callback = function(ev) helper_events[#helper_events + 1] = ev.event end })
              end
              vim.fn.setreg('a', vim.keycode(case.macro or ''))
              vim.fn.histadd(':', 'sandbox history sentinel')
              vim.v.errmsg = case.errmsg or 'previous error'
            ]=],
            { vim.fn.getcwd(), case, native },
          })
          settle()
          if case.recording then
            request("nvim_input", { "qa" })
            settle()
          end
          request("nvim_exec_lua", {
            [=[
              local case, silent = ...
              local command = (silent and 'silent! ' or '')
                .. ((case.sandbox == false or case.evaluation) and '' or 'sandbox ')
                .. 'normal ' .. vim.keycode(case.keys)
              if case.evaluation then
                _G.restricted_evaluation = function()
                  vim.cmd(command)
                  return 0
                end
                vim.api.nvim_eval_statusline('%{v:lua.restricted_evaluation()}', { maxwidth = 80 })
                _G.restricted_evaluation = nil
              else
                vim.cmd(command)
              end
            ]=],
            { case, silent },
          })
          settle()
          if case.recording then
            request("nvim_input", { "q" })
            settle()
          end
          local actual = request("nvim_exec_lua", {
            [=[
              local function normalize(node)
                if node[1] == 'leaf' then return { 'leaf', role(node[2]) } end
                local children = {}
                for _, child in ipairs(node[2]) do children[#children + 1] = normalize(child) end
                return { node[1], children }
              end
              local cursors, text = {}, {}
              for index, win in ipairs(editors) do
                cursors[index] = vim.api.nvim_win_call(win, vim.fn.getcurpos)
                text[index] = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
              end
              return {
                tree = normalize(vim.fn.winlayout()),
                focus = role(vim.api.nvim_get_current_win()),
                previous = role(vim.fn.win_getid(vim.fn.winnr('#'))),
                mode = vim.fn.mode(1), cursors = cursors, text = text,
                seen = seen, error = vim.v.errmsg, register = vim.fn.getreg('a'),
                recording = vim.fn.reg_recording(), history = vim.fn.histget(':', -1),
                messages = vim.api.nvim_exec2('messages', { output = true }).output,
                helper_events = helper_events,
                windows = #vim.api.nvim_list_wins(), buffers = #vim.api.nvim_list_bufs(),
                directory = { vim.fn.getcwd(), vim.fn.haslocaldir(), vim.uv.cwd() },
              }
            ]=],
            {},
          })
          assert(
            actual.error == (case.errmsg or "previous error"),
            context .. ": previous error changed"
          )
          assert(actual.messages == "", context .. ": unexpected message " .. actual.messages)
          assert(
            actual.history == "sandbox history sentinel",
            context .. ": command history changed"
          )
          if native then
            expected = actual
          else
            assert(
              vim.deep_equal(actual, expected),
              context
                .. "\nexpected: "
                .. vim.inspect(expected)
                .. "\nactual: "
                .. vim.inspect(actual)
            )
          end
        end, debug.traceback)
        child.close()
        assert(ok, err)
      end
    end
  end
end

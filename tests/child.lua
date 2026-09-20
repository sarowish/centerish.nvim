local M = {}

---@class centerish.test.ChildOptions
---@field name string Suite name included in request failures.
---@field context? fun(): string Current scenario included in request failures.
---@field on_notification? fun(name: string, args: any[]) Observe child notifications.

---@class centerish.test.Child
---@field finished boolean Whether the child has exited.
---@field drained boolean Whether its output stream has ended.
---@field exitcode? integer Child exit status.
---@field stderr string Captured error output.
---@field request fun(method: string, args: any[]): any Send a request and wait for its reply.
---@field settle fun(delay?: integer) Process child events for a short interval.
---@field close fun(signal?: string) Stop the child and close its process and pipes.

---Start an embedded Neovim with synchronous requests and optional notification observation.
---@param opts centerish.test.ChildOptions
---@return centerish.test.Child
function M.start(opts)
  local uv = vim.uv
  local input = assert(uv.new_pipe(false))
  local output = assert(uv.new_pipe(false))
  local errors = assert(uv.new_pipe(false))
  local child = { finished = false, drained = false, stderr = "" }
  local replies, sequence = {}, 0
  local decoder = vim.mpack.Unpacker()
  local process = assert(uv.spawn(vim.v.progpath, {
    args = { "--clean", "--embed", "--headless", "-i", "NONE" },
    stdio = { input, output, errors },
  }, function(code)
    child.exitcode = code
    child.finished = true
  end))

  output:read_start(function(err, data)
    assert(not err, err)
    if not data then
      child.drained = true
      return
    end
    local pos = 1
    while pos <= #data do
      local message
      message, pos = decoder(data, pos)
      if message and message[1] == 1 then
        replies[message[2]] = message
      elseif message and message[1] == 2 and opts.on_notification then
        opts.on_notification(message[2], message[3])
      end
    end
  end)
  errors:read_start(function(_, data)
    if data then
      child.stderr = child.stderr .. data
    end
  end)

  ---Include the suite and its current scenario in process failures.
  ---@return string
  local function context()
    return opts.name .. (opts.context and ": " .. opts.context() or "")
  end

  ---Wait for a reply while processing native input, redraws, and notifications.
  ---@param method string
  ---@param args any[]
  ---@return any
  function child.request(method, args)
    sequence = sequence + 1
    local id = sequence
    input:write(vim.mpack.encode({ 0, id, method, args }))
    assert(
      vim.wait(3000, function()
        return replies[id] ~= nil or child.finished
      end),
      context() .. " RPC timed out (" .. method .. ")"
    )
    local response = assert(replies[id], context() .. " child stopped: " .. child.stderr)
    replies[id] = nil
    assert(response[3] == vim.NIL, vim.inspect(response[3]))
    return response[4]
  end

  ---Allow native redraw events and scheduled layout updates to finish.
  ---@param delay? integer Wait duration in milliseconds. Defaults to 80.
  function child.settle(delay)
    vim.wait(delay or 80, function()
      return child.finished
    end)
  end

  ---Stop a running child, then release its pipes and process handle.
  ---@param signal? string Termination signal. Defaults to sigterm.
  function child.close(signal)
    if not child.finished then
      process:kill(signal or "sigterm")
      vim.wait(1000, function()
        return child.finished
      end)
    end
    for _, handle in ipairs({ input, output, errors, process }) do
      if not handle:is_closing() then
        handle:close()
      end
    end
  end

  return child
end

return M

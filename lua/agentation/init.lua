local uv = vim.uv or vim.loop

local M = {}

local state = {
  isPageConnected = false,
  isRouterConnected = false,
  server = nil,
  boundPort = nil,
  lastHeartbeatAt = nil,
  lastRouterHeartbeatAt = nil,
  watchdog = nil,
  routerHeartbeat = nil,
  routerStartInFlight = false,
  routerStartAttempted = false,
  sessionId = nil,
  projectId = nil,
  repoId = nil,
}

local config = {
  auto_start = true,
  host = "127.0.0.1",
  port = 8777,
  root = nil,
  heartbeat_timeout_ms = 15000,
  allow_absolute_paths = false,
  router_url = nil,
  router_token = nil,
  router_register_interval_ms = 5000,
  router_auto_start = false,
  router_bin = "agentation",
  router_start_args = { "start" },
  project_id = nil,
  repo_id = nil,
  session_id = nil,
  display_name = nil,
  statusline_enabled = true,
  statusline_auto_append = true,
  statusline_label = "AGT",
}

local function notify(message, level)
  vim.schedule(function()
    vim.notify(message, level)
  end)
end

local function hasActivePageConnection()
  if not state.lastHeartbeatAt then
    return false
  end

  return uv.now() - state.lastHeartbeatAt <= config.heartbeat_timeout_ms
end

local function hasActiveRouterConnection()
  if not state.lastRouterHeartbeatAt then
    return false
  end

  local timeout = math.max(config.router_register_interval_ms * 3, 3000)
  return uv.now() - state.lastRouterHeartbeatAt <= timeout
end

local function buildStatuslineText()
  if not config.statusline_enabled then
    return ""
  end

  local bridgeState = state.server and "+" or "-"
  local pageState = (state.isPageConnected and hasActivePageConnection()) and "+" or "-"

  local routerState = "!"
  if config.router_url and config.router_url ~= "" then
    routerState = (state.isRouterConnected and hasActiveRouterConnection()) and "+" or "-"
  end

  return string.format("%s B%s P%s R%s", config.statusline_label, bridgeState, pageState, routerState)
end

local function refreshStatusline()
  vim.g.agentation_statusline = buildStatuslineText()
  vim.schedule(function()
    pcall(vim.cmd, "redrawstatus")
  end)
end

function M.statusline()
  return vim.g.agentation_statusline or buildStatuslineText()
end

local function closeClient(client)
  if not client or client:is_closing() then
    return
  end

  client:shutdown(function()
    if not client:is_closing() then
      client:close()
    end
  end)
end

local function decodeURIComponent(value)
  local spaced = value:gsub("+", " ")
  return spaced:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
end

local function parseQuery(path)
  local query = path:match("%?(.*)$")
  local result = {}
  if not query then
    return result
  end

  for pair in query:gmatch("[^&]+") do
    local key, value = pair:match("([^=]+)=?(.*)")
    if key then
      result[decodeURIComponent(key)] = decodeURIComponent(value)
    end
  end

  return result
end

local function getRoot()
  if config.root and config.root ~= "" then
    return vim.fn.fnamemodify(config.root, ":p")
  end
  return vim.fn.getcwd()
end

local function resolvePath(path)
  local normalizedPath = vim.fs.normalize(path)
  if normalizedPath:find("%z") then
    return nil, "path contains invalid null byte"
  end

  if normalizedPath:match("^/") or normalizedPath:match("^[A-Za-z]:[\\/]") then
    if not config.allow_absolute_paths then
      return nil, "absolute paths are disabled"
    end
    return normalizedPath, nil
  end

  if normalizedPath == ".." or normalizedPath:match("^%.%.[/\\]") then
    return nil, "path traversal is not allowed"
  end

  local root = vim.fs.normalize(getRoot())
  local fullPath = vim.fs.normalize(vim.fs.joinpath(root, normalizedPath))
  if fullPath ~= root and not vim.startswith(fullPath, root .. "/") then
    return nil, "path is outside configured root"
  end

  return fullPath, nil
end

local function jumpToLocation(path, line, column)
  local fullPath, resolveError = resolvePath(path)
  if not fullPath then
    notify("Agentation open rejected: " .. resolveError, vim.log.levels.WARN)
    return
  end

  local didEdit, editError = pcall(function()
    vim.cmd.edit(vim.fn.fnameescape(fullPath))
  end)
  if not didEdit then
    notify("Agentation failed to open file: " .. tostring(editError), vim.log.levels.ERROR)
    return
  end

  local lineCount = vim.api.nvim_buf_line_count(0)
  local targetLine = math.max(tonumber(line) or 1, 1)
  targetLine = math.min(targetLine, math.max(lineCount, 1))

  local targetColumn = math.max((tonumber(column) or 1) - 1, 0)
  local lineText = vim.api.nvim_buf_get_lines(0, targetLine - 1, targetLine, true)[1] or ""
  targetColumn = math.min(targetColumn, #lineText)

  local didSetCursor, cursorError = pcall(function()
    vim.api.nvim_win_set_cursor(0, { targetLine, targetColumn })
  end)
  if not didSetCursor then
    notify("Agentation failed to set cursor: " .. tostring(cursorError), vim.log.levels.ERROR)
  end
end

local function respond(client, status, body)
  local payload = body or ""
  local response = table.concat({
    "HTTP/1.1 " .. status,
    "Content-Type: application/json",
    "Access-Control-Allow-Origin: *",
    "Access-Control-Allow-Methods: GET, OPTIONS",
    "Access-Control-Allow-Headers: *",
    "Content-Length: " .. #payload,
    "Connection: close",
    "",
    payload,
  }, "\r\n")

  client:write(response, function()
    closeClient(client)
  end)
end

local function setPageConnected(isConnected)
  if state.isPageConnected == isConnected then
    return
  end

  state.isPageConnected = isConnected
  refreshStatusline()

  if isConnected then
    notify("Agentation webpage connected", vim.log.levels.INFO)
    return
  end

  notify("Agentation webpage disconnected", vim.log.levels.WARN)
end

local function ensureWatchdog()
  if state.watchdog then
    return
  end

  local timer = uv.new_timer()
  if not timer then
    notify("Agentation failed to create watchdog timer", vim.log.levels.ERROR)
    return
  end

  timer:start(1000, 1000, function()
    if state.isPageConnected and not hasActivePageConnection() then
      setPageConnected(false)
    end

    if state.isRouterConnected and not hasActiveRouterConnection() then
      setRouterConnected(false)
    end
  end)
  state.watchdog = timer
end

local function getGitRoot(path)
  local matches = vim.fs.find(".git", {
    path = path,
    upward = true,
    stop = vim.loop.os_homedir(),
  })
  if #matches == 0 then
    return nil
  end

  return vim.fs.dirname(matches[1])
end

local function getRepoId(gitRoot)
  if not gitRoot then
    return nil
  end

  local command = { "git", "-C", gitRoot, "config", "--get", "remote.origin.url" }
  local output = vim.fn.system(command)
  if vim.v.shell_error ~= 0 then
    return nil
  end

  local remoteUrl = vim.trim(output)
  if remoteUrl == "" then
    return nil
  end

  return vim.fn.sha256(remoteUrl):sub(1, 16)
end

local function ensureIdentity()
  local root = vim.fs.normalize(getRoot())
  local gitRoot = getGitRoot(root)

  if not state.sessionId then
    if config.session_id and config.session_id ~= "" then
      state.sessionId = config.session_id
    else
      local seed = tostring(uv.hrtime()) .. tostring(math.random())
      state.sessionId = vim.fn.sha256(seed):sub(1, 16)
    end
  end

  if not state.projectId then
    if config.project_id and config.project_id ~= "" then
      state.projectId = config.project_id
    else
      local basePath = gitRoot or root
      local realPath = uv.fs_realpath(basePath) or basePath
      state.projectId = vim.fn.sha256(realPath):sub(1, 16)
    end
  end

  if not state.repoId then
    if config.repo_id and config.repo_id ~= "" then
      state.repoId = config.repo_id
    else
      state.repoId = getRepoId(gitRoot)
    end
  end
end

local function parseHttpUrl(rawUrl)
  local scheme, host, port, path = rawUrl:match("^(https?)://([^:/]+):?(%d*)(/?.*)$")
  if not scheme or scheme ~= "http" then
    return nil
  end
  if not host or host == "" then
    return nil
  end

  local parsedPort = tonumber(port)
  if not parsedPort then
    parsedPort = 80
  end

  local parsedPath = path or ""
  if parsedPath == "" then
    parsedPath = "/"
  end

  if not parsedPath:match("^/") then
    parsedPath = "/" .. parsedPath
  end

  return {
    host = host,
    port = parsedPort,
    path = parsedPath,
  }
end

local function routerRoutePath(route)
  local routerUrl = config.router_url
  if not routerUrl or routerUrl == "" then
    return nil
  end

  local parsed = parseHttpUrl(routerUrl)
  if not parsed then
    return nil
  end

  local prefix = parsed.path
  if prefix == "/" then
    prefix = ""
  end
  return parsed, prefix .. route
end

local function setRouterConnected(isConnected)
  if isConnected then
    state.lastRouterHeartbeatAt = uv.now()
  end

  local didChange = state.isRouterConnected ~= isConnected
  state.isRouterConnected = isConnected

  if didChange then
    refreshStatusline()
  end
end

local function startRouterProcess(options)
  options = options or {}

  if not config.router_auto_start and not options.force then
    return false, "router_auto_start is disabled"
  end

  local routerBin = config.router_bin
  if not routerBin or routerBin == "" then
    return false, "router_bin is empty"
  end

  if state.routerStartInFlight then
    return false, "router start is already in progress"
  end

  if state.routerStartAttempted and not options.force then
    return false, "router start already attempted"
  end
  state.routerStartAttempted = true

  if vim.fn.executable(routerBin) ~= 1 then
    return false, "command not found ('" .. routerBin .. "'). Set router_bin or add it to PATH."
  end

  local command = { routerBin }
  local startArgs = config.router_start_args
  if type(startArgs) == "table" and #startArgs > 0 then
    for _, value in ipairs(startArgs) do
      table.insert(command, tostring(value))
    end
  else
    table.insert(command, "start")
  end

  state.routerStartInFlight = true

  local function finish(success)
    state.routerStartInFlight = false
    if success then
      return
    end

    setRouterConnected(false)
  end

  if vim.system then
    local didStart, systemError = pcall(function()
      vim.system(command, { text = true }, function(result)
        finish(result.code == 0)
      end)
    end)

    if not didStart then
      state.routerStartInFlight = false
      return false, tostring(systemError)
    end

    return true
  end

  vim.schedule(function()
    local _ = vim.fn.system(command)
    finish(vim.v.shell_error == 0)
  end)

  return true
end

local function probeRouterHealth(onResult)
  local parsed, requestPath = routerRoutePath("/health")
  if not parsed then
    onResult(false)
    return
  end

  local client = uv.new_tcp()
  if not client then
    onResult(false)
    return
  end

  local resolved = false
  local timeout = uv.new_timer()

  local function resolve(success)
    if resolved then
      return
    end
    resolved = true

    if timeout and not timeout:is_closing() then
      timeout:stop()
      timeout:close()
    end

    closeClient(client)
    onResult(success)
  end

  if timeout then
    timeout:start(1000, 0, function()
      resolve(false)
    end)
  end

  client:connect(parsed.host, parsed.port, function(connectError)
    if connectError then
      resolve(false)
      return
    end

    local request = table.concat({
      "GET " .. requestPath .. " HTTP/1.1",
      "Host: " .. parsed.host .. ":" .. parsed.port,
      "Connection: close",
      "",
      "",
    }, "\r\n")

    client:write(request, function(writeError)
      if writeError then
        resolve(false)
        return
      end

      local chunks = {}
      client:read_start(function(readError, chunk)
        if readError then
          resolve(false)
          return
        end

        if chunk then
          table.insert(chunks, chunk)
          local response = table.concat(chunks)
          local statusLine = response:match("^(.-)\r\n")
          if statusLine then
            local statusCode = tonumber(statusLine:match("^HTTP/%d%.%d%s+(%d+)%s*"))
            resolve(statusCode and statusCode >= 200 and statusCode < 300 or false)
          end
          return
        end

        resolve(false)
      end)
    end)
  end)
end

local function sendRouterJson(route, payload, onResult)
  local parsed, requestPath = routerRoutePath(route)
  if not parsed then
    if onResult then
      onResult(false)
    end
    return
  end

  local body = vim.json.encode(payload)
  local headers = {
    "POST " .. requestPath .. " HTTP/1.1",
    "Host: " .. parsed.host .. ":" .. parsed.port,
    "Content-Type: application/json",
    "Content-Length: " .. #body,
    "Connection: close",
  }

  if config.router_token and config.router_token ~= "" then
    table.insert(headers, "X-Agentation-Token: " .. config.router_token)
  end

  local request = table.concat(headers, "\r\n") .. "\r\n\r\n" .. body

  local client = uv.new_tcp()
  if not client then
    if onResult then
      onResult(false)
    end
    return
  end

  local didResolve = false
  local function resolve(success)
    if didResolve then
      return
    end
    didResolve = true
    if onResult then
      onResult(success)
    end
  end

  client:connect(parsed.host, parsed.port, function(connectError)
    if connectError then
      resolve(false)
      closeClient(client)
      return
    end

    client:write(request, function(writeError)
      if writeError then
        resolve(false)
        closeClient(client)
        return
      end

      local chunks = {}
      client:read_start(function(readError, chunk)
        if readError then
          resolve(false)
          closeClient(client)
          return
        end

        if chunk then
          table.insert(chunks, chunk)
          local response = table.concat(chunks)
          local statusLine = response:match("^(.-)\r\n")
          if statusLine then
            local statusCode = tonumber(statusLine:match("^HTTP/%d%.%d%s+(%d+)%s*"))
            resolve(statusCode and statusCode >= 200 and statusCode < 300 or false)
            client:read_stop()
            closeClient(client)
          end
          return
        end

        resolve(false)
        closeClient(client)
      end)
    end)
  end)
end

local function routerRegisterPayload()
  ensureIdentity()

  local root = vim.fs.normalize(getRoot())
  local displayName = config.display_name
  if not displayName or displayName == "" then
    displayName = vim.fn.fnamemodify(root, ":t")
  end

  return {
    sessionId = state.sessionId,
    projectId = state.projectId,
    repoId = state.repoId,
    root = root,
    displayName = displayName,
    endpoint = string.format("http://%s:%d", config.host, state.boundPort or config.port),
  }
end

local function registerWithRouter(options)
  options = options or {}
  local notifyOnError = options.notify_on_error == true

  if not config.router_url or config.router_url == "" then
    return
  end

  probeRouterHealth(function(isHealthy)
    vim.schedule(function()
      if not isHealthy then
        setRouterConnected(false)

        local _, startError = startRouterProcess({
          force = options.force_router_start == true,
        })

        if notifyOnError then
          local message = "Agentation router is unavailable at " .. config.router_url
          if startError and startError ~= "" and startError ~= "router start already attempted" and startError ~= "router start is already in progress" then
            message = message .. ": " .. startError
          end
          notify(message, vim.log.levels.WARN)
        end
        return
      end

      sendRouterJson("/register", routerRegisterPayload(), function(success)
        setRouterConnected(success)

        if notifyOnError and not success then
          notify("Agentation failed to register with router at " .. config.router_url, vim.log.levels.WARN)
        end
      end)
    end)
  end)
end

local function unregisterFromRouter()
  if not config.router_url or config.router_url == "" then
    return
  end
  if not state.sessionId then
    return
  end

  sendRouterJson("/unregister", {
    sessionId = state.sessionId,
  }, function(_)
    setRouterConnected(false)
  end)
end

local function ensureRouterHeartbeat()
  if not config.router_url or config.router_url == "" then
    return
  end
  if state.routerHeartbeat then
    return
  end

  local timer = uv.new_timer()
  if not timer then
    notify("Agentation failed to create router heartbeat timer", vim.log.levels.ERROR)
    return
  end

  timer:start(0, config.router_register_interval_ms, vim.schedule_wrap(function()
    registerWithRouter()
  end))

  state.routerHeartbeat = timer
end

local function stopRouterHeartbeat()
  if state.routerHeartbeat and not state.routerHeartbeat:is_closing() then
    state.routerHeartbeat:stop()
    state.routerHeartbeat:close()
  end
  state.routerHeartbeat = nil
end

local function handleRequest(client, request)
  local method, rawPath = request:match("^(%u+)%s+([^%s]+)")
  if not method or not rawPath then
    respond(client, "400 Bad Request", '{"error":"bad request"}')
    return
  end

  if method == "OPTIONS" then
    respond(client, "204 No Content", "")
    return
  end

  if method ~= "GET" then
    respond(client, "405 Method Not Allowed", '{"error":"method not allowed"}')
    return
  end

  local route = rawPath:match("^[^?]+")
  if route == "/ping" then
    state.lastHeartbeatAt = uv.now()
    setPageConnected(true)
    respond(client, "204 No Content", "")
    return
  end

  if route ~= "/open" then
    respond(client, "404 Not Found", '{"error":"not found"}')
    return
  end

  local query = parseQuery(rawPath)
  if not query.path or query.path == "" then
    respond(client, "400 Bad Request", '{"error":"missing path"}')
    return
  end

  vim.schedule(function()
    jumpToLocation(query.path, query.line, query.column)
  end)

  state.lastHeartbeatAt = uv.now()
  setPageConnected(true)
  respond(client, "204 No Content", "")
end

local function startServer(options)
  options = options or {}

  if state.server then
    ensureWatchdog()
    ensureRouterHeartbeat()
    registerWithRouter({
      notify_on_error = options.notify_router_errors == true,
      force_router_start = options.force_router_start == true,
    })
    refreshStatusline()
    return true
  end

  local server = uv.new_tcp()
  if not server then
    notify("Agentation failed to create TCP server", vim.log.levels.ERROR)
    return false
  end

  local didBind, bindError = pcall(function()
    server:bind(config.host, config.port)
  end)
  if not didBind then
    notify("Agentation failed to bind server: " .. tostring(bindError), vim.log.levels.ERROR)
    if not server:is_closing() then
      server:close()
    end
    return false
  end

  local didListen, listenError = pcall(function()
    server:listen(128, function(error)
      if error then
        notify("Agentation bridge listener error: " .. tostring(error), vim.log.levels.ERROR)
        return
      end

      local client = uv.new_tcp()
      if not client then
        return
      end

      server:accept(client)
      local chunks = {}
      client:read_start(function(readError, chunk)
        if readError then
          closeClient(client)
          return
        end

        if chunk then
          table.insert(chunks, chunk)
          local request = table.concat(chunks)
          if request:find("\r\n\r\n", 1, true) then
            client:read_stop()
            handleRequest(client, request)
          end
          return
        end

        closeClient(client)
      end)
    end)
  end)

  if not didListen then
    notify("Agentation failed to listen: " .. tostring(listenError), vim.log.levels.ERROR)
    if not server:is_closing() then
      server:close()
    end
    return false
  end

  local socketInfo = server:getsockname()
  state.boundPort = socketInfo and socketInfo.port or config.port
  state.server = server
  ensureWatchdog()
  ensureRouterHeartbeat()
  registerWithRouter({
    notify_on_error = options.notify_router_errors == true,
    force_router_start = options.force_router_start == true,
  })
  refreshStatusline()

  return true
end

function M.start(options)
  startServer(options)
end

function M.stop()
  unregisterFromRouter()
  stopRouterHeartbeat()
  setRouterConnected(false)

  if state.server then
    if not state.server:is_closing() then
      state.server:close()
    end
    state.server = nil
    state.boundPort = nil
  end

  if state.watchdog and not state.watchdog:is_closing() then
    state.watchdog:stop()
    state.watchdog:close()
  end
  state.watchdog = nil
  state.lastHeartbeatAt = nil
  state.isPageConnected = false
  state.routerStartInFlight = false
  state.routerStartAttempted = false
  refreshStatusline()
end

function M.status()
  if not state.server then
    vim.notify("Agentation bridge not running")
    return
  end

  local url = string.format("http://%s:%d", config.host, state.boundPort or config.port)
  local statusMessage
  if state.isPageConnected and hasActivePageConnection() then
    statusMessage = "Agentation bridge connected to webpage on\n" .. url
  else
    statusMessage = "Agentation bridge listening on\n" .. url .. "\n(no webpage connected)"
  end

  if config.router_url and config.router_url ~= "" then
    ensureIdentity()
    statusMessage = statusMessage
      .. string.format(
        "\nRouter: %s\nProject ID: %s\nRepo ID: %s\nSession ID: %s",
        config.router_url,
        state.projectId,
        state.repoId or "n/a",
        state.sessionId
      )
  end

  vim.notify(statusMessage)
end

local function ensureStatuslineAttachment()
  if not config.statusline_enabled or not config.statusline_auto_append then
    return
  end

  local component = "%{%v:lua.require('agentation').statusline()%}"
  local statusline = vim.o.statusline or ""

  if statusline == "" then
    vim.o.statusline = "%f %h%m%r %= %l:%c %P " .. component
    return
  end

  if statusline:match("^%%!") then
    return
  end

  if statusline:find("require('agentation').statusline", 1, true) then
    return
  end

  vim.o.statusline = statusline .. " " .. component
end

function M.setup(options)
  config = vim.tbl_deep_extend("force", config, options or {})
  refreshStatusline()
  ensureStatuslineAttachment()

  vim.api.nvim_create_user_command("AgentationStart", function()
    M.start({
      notify_router_errors = true,
      force_router_start = true,
    })
  end, {})
  vim.api.nvim_create_user_command("AgentationStop", function()
    M.stop()
  end, {})
  vim.api.nvim_create_user_command("AgentationStatus", function()
    M.status()
  end, {})

  local group = vim.api.nvim_create_augroup("AgentationBridge", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.stop()
    end,
  })

  if config.auto_start then
    M.start({
      notify_router_errors = false,
      force_router_start = false,
    })
  end
end

return M

--!nonstrict

-- List of adapters for checking and installing updates.  Each adapter is a table with the following fields:
-- {
--     name = "adapter name",
--     enabled = true or false,
--     dependencies = {"list", "of", "dependencies"},
--     check_command = "command to run to check for updates",
--     update_package_command = "command to run to update a single package". Use {package_name} as a placeholder for the package name.
--                              If this field is empty, the adapter does not support updating single packages.
--     update_all_command = "command to run to update all packages",
--     phase = "ready" or "checking" or "updating". This field is filled in by the service and is not part of the adapter definition,
--     error_msg = "error message if any". This field is filled in by the service and is not part of the adapter definition,
--     total = number of updates available. This field is filled in by the service and is not part of the adapter definition,
--     updates = {"list", "of", "updates"}. This field is filled in by the service and is not part of the adapter definition,
-- }
local adapters = {}

local startup_time = os.time()
local last_check_time = nil

-- The adapter that should be rechecked after an update is completed.
-- This is used to recheck for updates after an update is completed, so that the user can see if there are any new updates available.
local recheck_adapter = nil

-- Table with pending and finished tasks for checking updates.
-- task structure:
-- {
--     cmd = "command to run",
--     adapter = "adapter name",
--     phase = "check",
--     state = "waiting" or "running" or "done" or "error",
--     error_msg = "error message if any"
-- }
local task_checking = {
    pending = {},
    finished = {}
}

-- Table with pending and finished tasks for installing updates.
-- 
local task_updating = {
    pending = {},
    finished = {}
}

local state = "idle"
local total_updates = 0

local function cfg(key)
    return noctalia.getConfig(key)
end

local function log(msg)
    noctalia.log("[system-updater] " .. msg)
end

local function err(msg)
    noctalia.log("[ERR][system-updater] " .. msg)
end

-- Load the adapters from the plugin's adapters directory.  Each adapter is a JSON file with a name and a check command.
local function load_adapters()
    local str = noctalia.readFile(noctalia.pluginDir() .. "/adapters/adapters.json")
    local out = noctalia.json.decode(str)
    for name, adapter in out do
        adapter.phase = "ready"
        adapter.error_msg = ""
        adapter.info = ""
        adapter.show_actions = {}
        adapter.total = 0
        adapter.updates = {}
    end
    return out
end

-- Publish the current state to the plugin's state store.  This is used by the widget and panel to display the current state of the system updater.
function publish_state()
    local items = {}
    for name, adapter in pairs(adapters) do
        if adapter.enabled then
            table.insert(items, {
                name = name,
                error_msg = adapter.error_msg,
                total = adapter.total,
                updates = adapter.updates,
                info = adapter.info,
                actions = adapter.show_actions,
            })
        end
    end
    noctalia.state.set("state", {
        state = state,
        total = total_updates,
        adapters = items,
        task_checking = task_checking,
        task_updating = task_updating,
        last_check_time = last_check_time,
    })
end

local start_check_queue
local start_update_queue

local function next_check_task()
    table.insert(task_checking.finished, task_checking.pending[1])
    table.remove(task_checking.pending, 1)
    start_check_queue()
end

local function next_update_task()
    table.insert(task_updating.finished, task_updating.pending[1])
    table.remove(task_updating.pending, 1)
    start_update_queue()
end

-- Start the next command in the run queue, if any.  This is called after each command completes, and will start the next command in the queue.
start_check_queue = function()
    if #task_checking.pending == 0 then
        state = "idle"
        total_updates = 0
        for _, adapter in pairs(adapters) do
            total_updates = total_updates + adapter.total
        end
        publish_state()
        return
    end
    local cmd = task_checking.pending[1].cmd
    local adapter = task_checking.pending[1].adapter
    task_checking.pending[1].state = "running"
    publish_state()
    noctalia.runAsync(cmd, function (result)
        if result.timedOut or result.exitCode ~= 0 then
            task_checking.pending[1].state = "error"
            if result.timedOut then
                table.insert(adapters[adapter].error_msg, {
                    phase = task_checking.pending[1].phase,
                    message = noctalia.tr("error_timeout")
                })
                task_checking.pending[1].error_msg = noctalia.tr("error_timeout")
            else
                table.insert(adapters[adapter].error_msg, {
                    phase = task_checking.pending[1].phase,
                    message = result.stderr
                })
                task_checking.pending[1].error_msg = result.stderr
            end
            adapters[adapter].total = 0
        else
            task_checking.pending[1].state = "done"
            local data = noctalia.json.decode(result.stdout) or {info = "", updates = {}}
            adapters[adapter].updates = data.updates
            adapters[adapter].info = data.info or ""
            adapters[adapter].show_actions = data.actions or {}
            adapters[adapter].total = #adapters[adapter].updates
        end
        publish_state()
        next_check_task()
    end, 60000)
end

-- Start a check for updates.  This will run the check command for each enabled adapter.
local function start_check(adapter_name)
    if adapters == nil then
        err("Adapters are empty")
        return
    end
    if state ~= "idle" then
        err("System updater is busy")
        return
    end

    table.clear(task_checking.pending)
    table.clear(task_checking.finished)
    total_updates = 0

    for name, adapter in pairs(adapters) do
        if adapter.enabled and (adapter_name == nil or adapter_name == name) then
            adapters[name].error_msg = {}
            table.insert(task_checking.pending, {
                cmd = string.gsub(adapter.check_command, "{plugin_dir}", noctalia.pluginDir()),
                adapter = name,
                phase = "check",
                state = "waiting",
                error_msg = ""
            })
        end
    end

    if #task_checking.pending > 0 then
        state = "checking"
        last_check_time = os.time()
        publish_state()
        start_check_queue()
    else
        state = "idle"
        publish_state()
    end
end

local function starts_with(str: string, prefix: string): boolean
    return string.sub(str, 1, #prefix) == prefix
end

-- Start the next command in the run queue, if any.  This is called after each command completes, and will start the next command in the queue.
start_update_queue = function()
    if #task_updating.pending == 0 then
        state = "idle"
        start_check(recheck_adapter)
        return
    end

    local cmd = task_updating.pending[1].cmd
    local adapter = task_updating.pending[1].adapter
    task_updating.pending[1].state = "running"
    publish_state()
    log("Running update command: " .. cmd)
    noctalia.runStream(cmd, function(line: string)
        local start_prefix = "tordex/system-updater:pid:"
        local done_prefix = "tordex/system-updater:done:"

        if starts_with(line, start_prefix) then
            local pid = tonumber(string.sub(line, #start_prefix + 1))
            task_updating.pending[1].pid = pid
            log("Update task started with PID " .. tostring(pid))
            publish_state()
        elseif starts_with(line, done_prefix) then
            local exitCode = tonumber(string.sub(line, #done_prefix + 1))
            log("Update task finished with exit code " .. tostring(exitCode))
            if exitCode ~= 0 then
                task_updating.pending[1].state = "error"
                table.insert(adapters[adapter].error_msg, {
                    phase = "update",
                    message = task_updating.pending[1].stdout
                })
            else
                task_updating.pending[1].state = "done"
            end
            publish_state()
            next_update_task()
        else
            log("Update log: " .. line)
            task_updating.pending[1].stdout = task_updating.pending[1].stdout .. line .. "\n"
            publish_state()
        end
    end)
end

local function wrap_update_command(cmd)
    return "echo tordex/system-updater:pid:$$;(" .. cmd .. ") 2>&1;echo tordex/system-updater:done:$?"
end

local function start_update(adapter_name, package)
    log("Starting update: adapter=" .. (adapter_name or "all") .. " package=" .. (package or "all"))
    if adapters == nil then
        err("Adapters are empty")
        return
    end
    if state ~= "idle" then
        err("System updater is busy")
        return
    end

    table.clear(task_updating.pending)
    table.clear(task_updating.finished)
    recheck_adapter = adapter_name

    if adapter_name ~= nil and package ~= nil then
        -- Update a single package using the specified adapter
        log("Updating package " .. package .. " using adapter " .. adapter_name)
        local adapter = adapters[adapter_name]
        if adapter ~= nil and adapter.enabled then
            local cmd = string.gsub(adapter.update_package_command, "{package_name}", package)
            cmd = string.gsub(cmd, "{plugin_dir}", noctalia.pluginDir())
            if cmd == nil or cmd == "" then
                err("Adapter " .. adapter_name .. " does not support updating single packages")
                return
            end
            adapters[adapter_name].error_msg = {}
            cmd = wrap_update_command(cmd)
            table.insert(task_updating.pending, {
                cmd = cmd,
                adapter = adapter_name,
                package = package,
                state = "waiting",
                stdout = "",
                pid = nil
            })
        end
    else
        -- Update all packages for all or specified enabled adapters
        log("Updating all packages for adapters" .. (adapter_name ~= nil and (" " .. adapter_name) or "") .. " package: " .. (package ~= nil and package or "nil"))
        for name, adapter in pairs(adapters) do
            log("command: " .. adapter.update_all_command .. " adapter_name: " .. (adapter_name or "nil"))
            if adapter.enabled and adapter.total > 0 and adapter.update_all_command ~= nil and (adapter_name == nil or name == adapter_name) then
                local cmd = string.gsub(adapter.update_all_command, "{plugin_dir}", noctalia.pluginDir())
                if cmd == nil or cmd == "" then
                    err("Adapter " .. name .. " does not support updating all packages")
                    continue
                end
                adapters[name].error_msg = {}
                cmd = wrap_update_command(cmd)
                table.insert(task_updating.pending, {
                    cmd = cmd,
                    adapter = name,
                    package = package,
                    state = "waiting",
                    stdout = "",
                    pid = nil
                })
            end
        end
    end

    if #task_updating.pending > 0 then
        state = "updating"
        publish_state()
        start_update_queue()
    else
        state = "idle"
        publish_state()
    end
end

function handle(action, adapter, package)
    if action == "check" then
        start_check(adapter)
    elseif action == "update" then
        start_update(adapter, package)
    end
end

-- Scriptable control:
--   noctalia msg plugin tordex/system-updater:service all check
--   noctalia msg plugin tordex/system-updater:service all update
function onIpc(event, _payload)
    handle(event, nil, nil)
end


noctalia.state.watch("request", function(value)
    handle(value.action, value.adapter, value.package)
end)

noctalia.state.watch("adapter_action", function(value)
    log("Received adapter action request: adapter=" .. value.adapter .. " action=" .. value.action)
    local adapter = value.adapter
    local cmd = adapters[adapter].actions[value.action].command
    local check_after = adapters[adapter].actions[value.action].check_after
    state = "action"
    publish_state()
    noctalia.runAsync(cmd, function (result)
        if result.timedOut or result.exitCode ~= 0 then
            table.insert(adapters[adapter].error_msg, {
                phase = "action",
                message = result.stderr
            })
            state = "idle"
            publish_state()
        else
            if check_after then
                state = "idle"
                start_check(adapter)
            else
                state = "idle"
                publish_state()
            end
        end
    end, 60000)
end)

function update()
    local auto_check_minutes = cfg("auto_check_minutes") or 0
    if auto_check_minutes > 10 then
        if last_check_time == nil and startup_time ~= nil then
            local now = os.time()
            -- If the system updater has never checked for updates, we check for updates 5 minutes after startup.
            if os.difftime(now, startup_time) >= 5 * 60 then
                startup_time = nil
                start_check()
            end
        elseif last_check_time ~= nil then
            local now = os.time()
            if os.difftime(now, last_check_time) >= 60 * auto_check_minutes then
                last_check_time = now
                start_check()
            end
        end
    end
end

noctalia.setUpdateInterval(1000)
adapters = load_adapters()
publish_state()

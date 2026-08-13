--!nonstrict
-- task structure:
-- {
--     cmd = "command to run",
--     adapter = "adapter name",
--     phase = "refresh" or "check",
--     state = "waiting" or "running" or "done" or "error",
--     error_msg = "error message if any"
-- }

local adapters = {}
local scheduled_tasks = {}
local finished_tasks = {}

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

-- Load the adapters from the plugin's adapters directory.  Each adapter is a JSON file with a name, a check command, and an optional refresh command.
local function load_adapters()
    local str = noctalia.readFile(noctalia.pluginDir() .. "/adapters/adapters.json")
    local out = noctalia.json.decode(str)
    for name, adapter in pairs(out) do
        adapter.phase = "ready"
        adapter.error_msg = ""
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
                updates = adapter.updates
            })
        end
    end
    noctalia.state.set("state", {
        state = state,
        total = total_updates,
        adapters = items,
        scheduled_tasks = scheduled_tasks,
        finished_tasks = finished_tasks
    })
end

local start_queue

local function next_task()
    table.insert(finished_tasks, scheduled_tasks[1])
    table.remove(scheduled_tasks, 1)
    start_queue()
end

-- Start the next command in the run queue, if any.  This is called after each command completes, and will start the next command in the queue.
start_queue = function()
    if #scheduled_tasks == 0 then
        log("Update check complete. Total updates: " .. tostring(total_updates))
        state = "idle"
        total_updates = 0
        for _, adapter in pairs(adapters) do
            total_updates = total_updates + adapter.total
        end
        publish_state()
        return
    end
    local cmd = scheduled_tasks[1].cmd
    local adapter = scheduled_tasks[1].adapter
    scheduled_tasks[1].state = "running"
    publish_state()
    log(adapter .. "[" .. scheduled_tasks[1].phase .. "]")
    noctalia.runAsync(cmd, function (result)
        if result.timedOut or result.exitCode ~= 0 then
            err(adapter .. "[" .. scheduled_tasks[1].phase .. "]" .. ": timeout=" .. tostring(result.timedOut) .. " exitCode=" .. tostring(result.exitCode) .. " err: " .. tostring(result.stderr))
            scheduled_tasks[1].state = "error"
            if result.timedOut then
                table.insert(adapters[adapter].error_msg, {
                    phase = scheduled_tasks[1].phase,
                    message = noctalia.tr("error_timeout")
                })
                scheduled_tasks[1].error_msg = noctalia.tr("error_timeout")
            else
                table.insert(adapters[adapter].error_msg, {
                    phase = scheduled_tasks[1].phase,
                    message = result.stderr
                })
                scheduled_tasks[1].error_msg = result.stderr
            end
            adapters[adapter].total = 0
        else
            scheduled_tasks[1].state = "done"
            adapters[adapter].updates = noctalia.json.decode(result.stdout) or {}
            adapters[adapter].total = #adapters[adapter].updates
            log(adapter .. "[" .. scheduled_tasks[1].phase .. "]" .. ": updates: " .. tostring(adapters[adapter].total))
        end
        publish_state()
        next_task()
    end, 60000)
end

-- Start a check for updates.  This will run the refresh command for each enabled adapter, followed by the check command for each enabled adapter.
local function start_check(adapter_name)
    log("Starting update check")
    if adapters == nil then
        err("Adapters are empty")
        return
    end

    table.clear(scheduled_tasks)
    table.clear(finished_tasks)
    total_updates = 0

    for name, adapter in pairs(adapters) do
        if adapter.enabled and (adapter_name == nil or adapter_name == name) then
            adapters[name].error_msg = {}
            if adapter.refresh_command ~= "" then
                table.insert(scheduled_tasks, {
                    cmd = string.gsub(adapter.refresh_command, "{plugin_dir}", noctalia.pluginDir()),
                    adapter = name,
                    phase = "refresh",
                    state = "waiting",
                    error_msg = ""
                })
            end
            table.insert(scheduled_tasks, {
                cmd = string.gsub(adapter.check_command, "{plugin_dir}", noctalia.pluginDir()),
                adapter = name,
                phase = "check",
                state = "waiting",
                error_msg = ""
            })
        end
    end

    if #scheduled_tasks > 0 then
        state = "checking"
        publish_state()
        start_queue()
    else
        state = "idle"
        publish_state()
    end
end

local function start_update(adapter_name, package)
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

noctalia.setUpdateInterval(1000)
adapters = load_adapters()

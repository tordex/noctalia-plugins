--!nonstrict

local adapters = {}
local checking_pending_tasks = {}
local finished_tasks = {}

-- Table with pending and finished tasks for checking updates.
-- task structure:
-- {
--     cmd = "command to run",
--     adapter = "adapter name",
--     phase = "refresh" or "check",
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
        task_checking = task_checking,
        task_updating = task_updating,
    })
end

local start_check_queue

local function next_task()
    table.insert(task_checking.finished, task_checking.pending[1])
    table.remove(task_checking.pending, 1)
    start_check_queue()
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
            adapters[adapter].updates = noctalia.json.decode(result.stdout) or {}
            adapters[adapter].total = #adapters[adapter].updates
        end
        publish_state()
        next_task()
    end, 60000)
end

-- Start a check for updates.  This will run the refresh command for each enabled adapter, followed by the check command for each enabled adapter.
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
            if adapter.refresh_command ~= "" then
                table.insert(task_checking.pending, {
                    cmd = string.gsub(adapter.refresh_command, "{plugin_dir}", noctalia.pluginDir()),
                    adapter = name,
                    phase = "refresh",
                    state = "waiting",
                    error_msg = ""
                })
            end
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
        publish_state()
        start_check_queue()
    else
        state = "idle"
        publish_state()
    end
end

local function start_update(adapter_name, package)
    log("Starting update")
    if adapters == nil then
        err("Adapters are empty")
        return
    end
    if state ~= "idle" then
        err("System updater is busy")
        return
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

noctalia.setUpdateInterval(1000)
adapters = load_adapters()

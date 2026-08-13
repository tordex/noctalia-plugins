--!nonstrict

local SKIN_PKG_TITLE_FONT_SIZE = 14
local SKIN_PKG_DESCRIPTION_FONT_SIZE = 11
local SKIN_PKG_VERSION_FONT_SIZE = 12
local SKIN_PKG_ICON_SIZE = 48

local SKIN_ADAPTER_TITLE_FONT_SIZE = 16

local SKIN_ERRMSG_ICON_SIZE = 24
local SKIN_ERRMSG_FONT_SIZE = 14

local SKIN_TASK_FONT_SIZE = 16
local SKIN_TASK_ICON_SIZE = 20

local SKIN_TITLE_FONT_SIZE = 16
local SKIN_HEAD_LINE_FONT_SIZE = 16

local state = nil

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function phaseOf()
    return state ~= nil and state.state or "idle"
end

local function totalOf()
    return state ~= nil and tonumber(state.total) or 0
end

local function busy()
    local phase = phaseOf()
    return phase == "checking"
end

local function headline()
    local phase = phaseOf()
    if phase == "checking" then
        return tr("status_checking"), "secondary"
    else
        if totalOf() > 0 then
            return noctalia.trp("status_idle", totalOf(), {}), "primary"
        else
            return tr("status_clean"), "on_surface"
        end
    end
end

local function request(action, adapter, package_id)
    noctalia.state.set("request", {
        action = action,
        adapter = adapter,
        package_id = package_id,
    })
end

local function packageRow(item, adapter_name)
    local children = {
        ui.label({ text = item.name, fontSize = SKIN_PKG_TITLE_FONT_SIZE, color = "on_surface", flexGrow = 1, maxLines = 1, fontWeight = "bold" }),
    }
    if item.description ~= "" then
        table.insert(children, ui.label({ text = item.description, fontSize = SKIN_PKG_DESCRIPTION_FONT_SIZE, color = "on_surface_variant", flexGrow = 1, maxLines = 2 }))
    end

    if item.from_version ~= "" and item.to_version ~= "" then
        table.insert(children, ui.label({ text = item.from_version .. " → " .. item.to_version, fontSize = SKIN_PKG_VERSION_FONT_SIZE, color = "secondary", flexGrow = 1, maxLines = 1, fontWeight = "bold" }))
    elseif item.from_version ~= "" then
        table.insert(children, ui.label({ text = item.from_version, fontSize = SKIN_PKG_VERSION_FONT_SIZE, color = "secondary", flexGrow = 1, maxLines = 1, fontWeight = "bold" }))
    elseif item.to_version ~= "" then
        table.insert(children, ui.label({ text = item.to_version, fontSize = SKIN_PKG_VERSION_FONT_SIZE, color = "secondary", flexGrow = 1, maxLines = 1, fontWeight = "bold" }))
    end

    local row_childs  ={}
    if item.icon ~= "" and item.icon ~= nil then
        table.insert(row_childs, ui.image({ path = item.icon, width = SKIN_PKG_ICON_SIZE, height = SKIN_PKG_ICON_SIZE, fit = "stretch" }))
    else
        table.insert(row_childs, ui.glyph({ name = "package", size = SKIN_PKG_ICON_SIZE, color = "on_surface" }))
    end
    table.insert(row_childs, ui.column({ flexGrow = 1 }, children))
    table.insert(row_childs,
        ui.button({ 
                    glyph = "download",
                    variant = "ghost",
                    tooltip = tr("tip_update_package"),
                    onClick = function()
                        request("update", adapter_name, item.id)
                    end,
                })  
)

    return ui.row({
        paddingH = 8,
        paddingV = 8,
        borderWidth = 1,
        fill = "surface_variant",
        border = "outline",
        radius = 12,
        align = "start",
        gap = 8
    }, row_childs)
end

local function adapterRow(adapter)
    local title_children = {}
    table.insert(title_children, ui.label({ text = adapter.name, fontSize = SKIN_ADAPTER_TITLE_FONT_SIZE, color = "primary", flexGrow = 0, maxLines = 1 }))
    if adapter.total > 0 then
        table.insert(title_children, ui.label({ text = "[" .. tostring(adapter.total) .. "]", fontSize = SKIN_ADAPTER_TITLE_FONT_SIZE, flexGrow = 1, color = "primary", maxLines = 1 }))
    else
        table.insert(title_children, ui.spacer({ flexGrow = 1 }))
    end
    table.insert(title_children, ui.button({ 
        glyph = "refresh", 
        variant = "ghost",
        tooltip = tr("tip_check_adapter", { adapter = adapter.name }),
        onClick = function()
            request("check", adapter.name)
        end,
    }))
    if adapter.total > 0 then
        table.insert(title_children, ui.button({ 
            glyph = "download", 
            variant = "ghost",
            tooltip = tr("tip_update_adapter", { adapter = adapter.name }),
            onClick = function()
                request("update", adapter.name)
            end,
        }))
    end

    local children = {}

    table.insert(children, ui.row({ gap = 8, align = "center" }, title_children))

    if #adapter.error_msg > 0 then
        for _, msg in ipairs(adapter.error_msg) do
            table.insert(children, ui.row({
                paddingH = 8,
                paddingV = 8,
                borderWidth = 1,
                fill = "error",
                border = "on_error",
                radius = 10,
                align = "start",
                gap = 8
            },
            {
                ui.glyph({ name = "alert-circle", size = SKIN_ERRMSG_ICON_SIZE, color = "on_error" }),
                ui.label({ text = msg.message, fontSize = SKIN_ERRMSG_FONT_SIZE, color = "on_error", flexGrow = 1, maxLines = 1 }),
                ui.button({ 
                    glyph = "clipboard",
                    variant = "default",
                    tooltip = tr("tip_copy_to_clipboard"),
                    onClick = function()
                        noctalia.copyToClipboard(msg.message, "text/plain")
                    end,
                })
            }))
        end
    end

    for _, package in ipairs(adapter.updates) do
        table.insert(children, packageRow(package))
    end

    return ui.column({
        gap = 8
    }, children)
end

local function taskRow(task)
    local state_options = {
        waiting = {
            glyph = "hourglass",
            bk_color = "surface_variant",
            text_color = "on_surface_variant"
        },
        running = {
            glyph = "player-play",
            bk_color = "hover",
            text_color = "on_hover"
        },
        done = {
            glyph = "check",
            bk_color = "surface_variant",
            text_color = "on_surface_variant"
        },
        error = {
            glyph = "x",
            bk_color = "error",
            text_color = "on_error"
        }
    }

    local children = {
        ui.label({ text = task.adapter .. " [" .. task.phase .. "]", fontSize = SKIN_TASK_FONT_SIZE, color = state_options[task.state].text_color, flexGrow = 1, maxLines = 1, fontWeight = "bold" }),
    }

    if task.error_msg ~= "" then
        table.insert(children, ui.label({ text = task.error_msg, fontSize = SKIN_ERRMSG_FONT_SIZE, color = state_options[task.state].text_color, flexGrow = 1, maxLines = 2 }))
    end

    return ui.row({
        paddingH = 8,
        paddingV = 8,
        borderWidth = 1,
        fill = state_options[task.state].bk_color,
        border = "outline",
        radius = 12,
        align = "start",
        gap = 4
    }, {
        ui.glyph({ name = state_options[task.state].glyph, size = SKIN_TASK_ICON_SIZE, color = state_options[task.state].text_color }),
        ui.column({ flexGrow = 1 }, children)
    })
end

local function render()

    local text, color = headline()
    local phase = phaseOf()
    local hasUpdates = totalOf() > 0 and phase == "idle"

    local children = {
        -- Every child of the header carries a stable key, so the reconciler
        -- matches roles instead of guessing by position and type.
        ui.row({ key = "header", gap = 8, align = "center" }, {
            ui.label({
                key = "title",
                text = tr("title"),
                fontSize = SKIN_TITLE_FONT_SIZE,
                fontWeight = "bold",
                color = "on_surface",
            }),
            ui.spacer({ key = "gap", flexGrow = 1 }),
            ui.button({
                key = "header-check" .. (busy() and "-off" or ""),
                glyph = "refresh",
                variant = "ghost",
                enabled = not busy(),
                tooltip = tr("tip_check"),
                onClick = function()
                    request("check")
                end,
            }),
            -- Opens the settings window on this plugin's own page (the host
            -- supplies the plugin id, so a plugin can only ever open its own).
            -- The panel closes on the way; the engine keeps running.
            ui.button({
                key = "settings",
                glyph = "settings",
                variant = "ghost",
                tooltip = tr("tip_settings"),
                onClick = function()
                    noctalia.openSettings()
                end,
            }),
            ui.button({
                key = "close",
                glyph = "close",
                variant = "ghost",
                tooltip = tr("tip_close"),
                onClick = function()
                    panel.close()
                end,
            }),
        }),
        ui.label({ text = text, color = color, maxLines = 2, fontSize = SKIN_HEAD_LINE_FONT_SIZE }),
    }


    local rows = {}
    local stickToBottom = false
    if state.state == "idle" then
        for _, adapter in pairs(state.adapters) do
            table.insert(rows, adapterRow(adapter))
        end
    elseif state.state == "checking" then
        for _, task in ipairs(state.finished_tasks) do
            table.insert(rows, taskRow(task))
        end
        for _, task in ipairs(state.scheduled_tasks) do
            table.insert(rows, taskRow(task))
        end
        stickToBottom = true
    end

    table.insert(children, ui.scroll({ flexGrow = 1, gap = 6, stickToBottom = stickToBottom }, rows))

    -- The action buttons are always at the bottom, so they are easy to reach.
    -- They are disabled when the system updater is busy checking for updates or applying updates.
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
        ui.spacer({ flexGrow = 1 }),
        ui.button({
            key = "check" .. (busy() and "-off" or ""),
            glyph = "refresh",
            text = tr("action_check"),
            variant = "default",
            enabled = not busy(),
            tooltip = tr("tip_check"),
            onClick = function()
                request("check")
            end,
        }),
        ui.button({
            key = "update" .. (hasUpdates and not busy() and "" or "-off"),
            glyph = "download",
            text = tr("action_update"),
            variant = "primary",
            enabled = hasUpdates and not busy(),
            tooltip = tr("tip_update"),
            onClick = function()
                request("update")
            end,
        }),
    }))

    panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children))
end

function onOpen(_context)
    state = noctalia.state.get("state")
    render()
end

noctalia.state.watch("state", function(value)
    if type(value) ~= "table" then
        return
    end

    state = value
    render()
end)

render()

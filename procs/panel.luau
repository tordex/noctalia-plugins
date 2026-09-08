--!nonstrict

-- Data from the nvtop command, which is updated in real-time.
local g_data = nil
-- The PID of the nvtop process, which is used to terminate the process when the panel is closed.
local procs_pid = -1

local g_order_by_context = "mem"

-- Forward declaration of the render function to allow it to be called from other functions.
local render

-- Render a single row of GPU info with a label, value, and glyph.
local function gpu_info_row(label, value, glyph)
    return ui.row({
        gap = 8,
    },{
        ui.glyph({
            name = glyph,
            color = "on_surface",
        }),
        ui.label({
            text = label .. ":",
            color = "on_surface",
        })
    }), ui.label({
            text = value,
            flexGrow = 1,
            fontWeight = "bold",
            color = "on_surface",
        })
end

-- Format memory size in bytes to a human-readable string in M or G.
local function format_memory_size(size_in_bytes, show_B)
    show_B = show_B or false
    if size_in_bytes == nil then
        return "0" .. (show_B and " B" or "")
    end
    
    local size_in_units = size_in_bytes
    if size_in_units < 1024 then
        return tostring(size_in_bytes) .. (show_B and " B" or "")
    end
    
    size_in_units = size_in_units / 1024
    if size_in_units < 1024 then
        return string.format("%.2f K", size_in_units)
    end

    size_in_units = size_in_units / 1024
    if size_in_units < 1024 then
        return string.format("%.2f M", size_in_units)
    end

    size_in_units = size_in_units / 1024
    return string.format("%.2f G", size_in_units)
end

-- Render a message when there is no data available.
local function render_no_data_message()
    if g_data == nil then
        panel.render(ui.row({
            key = "no-data-row",
            fill = "surface_variant",
            border = "outline",
            padding = 16,
            radius = 12,
            gap = 8,
        },{
            ui.glyph({
                key = "no-data-glyph",
                name = "info-triangle"
            }),
            ui.label({
                key = "no-data-label",
                text = noctalia.tr("procs.nodata"),
            })
        }))
        return true
    end
    return false
end

local function render_system_info_row(glyph, text)
    return ui.row({
        gap = 8,
    },{
        ui.glyph({
            name = glyph,
            color = "on_surface_variant",
            size = 12,
        }),
        ui.label({
            text = text,
            color = "on_surface_variant",
            maxLines = 1,
            fontSize = 12,
        }),
    })
end

local function render_system_info()
    local children = {}

    if g_data.distro_info.pretty_name ~= nil then
        table.insert(children, render_system_info_row("device-desktop", g_data.distro_info.pretty_name))
    else
        table.insert(children, render_system_info_row("device-desktop", noctalia.tr("procs.system_info.unknown")))
    end

    if g_data.system_stats.kernel_version ~= nil then
        table.insert(children, render_system_info_row("copy", g_data.system_stats.kernel_version))
    end

    if g_data.system_stats.cpu_name ~= nil then
        table.insert(children, render_system_info_row("cpu", g_data.system_stats.cpu_name))
    end

    if g_data.system_stats.board ~= nil then
        table.insert(children, render_system_info_row("artboard", g_data.system_stats.board))
    end

    if g_data.system_stats.uptime ~= nil then
        local uptime_seconds = g_data.system_stats.uptime
        local uptime_days = math.floor(uptime_seconds / (24 * 3600))
        local uptime_hours = math.floor((uptime_seconds % (24 * 3600)) / 3600)
        local uptime_minutes = math.floor((uptime_seconds % 3600) / 60)
        local uptime_str = string.format("%dd %dh %dm", uptime_days, uptime_hours, uptime_minutes)

        table.insert(children, render_system_info_row("clock", uptime_str))
    end

    return ui.column({
        gap = 4,
        flexGrow = 1,
    }, children)
end

-- Render the system information.
local function render_info()
    local children = {}

    if g_data.distro_info.icon_path ~= nil then
        table.insert(children, ui.image({
            key = "img-distro",
            path = g_data.distro_info.icon_path,
            width = 110,
            height = 110,
        }))
    end

    table.insert(children, render_system_info())

    if g_data ~= nil and g_data["system_stats"] ~= nil then
        local system_stats = g_data["system_stats"]
        if system_stats["cpu_graph_path"] ~= nil and noctalia.fileExists(system_stats["cpu_graph_path"]) then
            table.insert(children, ui.image({
                key = "img-cpu-" .. tonumber(noctalia.nowMs()),
                path = system_stats["cpu_graph_path"],
                width = 110,
                height = 110,
            }))
        end
        if system_stats["mem_graph_path"] ~= nil and noctalia.fileExists(system_stats["mem_graph_path"]) then
            table.insert(children, ui.image({
                key = "img-mem-" .. tonumber(noctalia.nowMs()),
                path = system_stats["mem_graph_path"],
                width = 110,
                height = 110,
            }))
        end
    end

    return ui.row({
        gap = 8,
        padding = 8,
        radius = 12,
        border = "outline",
        fill = "surface_variant",
        borderWidth = 1,
    }, children)
end

-- Define the process data columns to display in the panel.
local processes_data = {
    {
        data_key = "name",
        label = noctalia.tr("procs.process.name.label"),
        tip = noctalia.tr("procs.process.name.tip"),
        flexGrow = 4,
        textAlign = "start",
        process_value = function(value) return value end,
        sort_value = function(value) return value end
    },
    {
        data_key = "pid",
        label = noctalia.tr("procs.process.pid.label"),
        tip = noctalia.tr("procs.process.pid.tip"),
        flexGrow = 2,
        textAlign = "end",
        process_value = function(value) return tostring(value or "") end,
        sort_value = function(value) return value end
    },
    {
        data_key = "cpu",
        label = noctalia.tr("procs.process.cpu.label"),
        tip = noctalia.tr("procs.process.cpu.tip"),
        flexGrow = 1.5,
        textAlign = "end",
        process_value = function(value) return tostring(value) .. "%" end,
        sort_value = function(value) return value end
    },
    {
        data_key = "mem",
        label = noctalia.tr("procs.process.mem.label"),
        tip = noctalia.tr("procs.process.mem.tip"),
        flexGrow = 2.0,
        textAlign = "end",
        process_value = function(value) return format_memory_size(value) end,
        sort_value = function(value) return value end
    },
    {
        data_key = "swap",
        label = noctalia.tr("procs.process.swap.label"),
        tip = noctalia.tr("procs.process.swap.tip"),
        flexGrow = 2.0,
        textAlign = "end",
        process_value = function(value) return format_memory_size(value) end,
        sort_value = function(value) return value end
    },
    {
        data_key = "io_read",
        label = noctalia.tr("procs.process.io_read.label"),
        tip = noctalia.tr("procs.process.io_read.tip"),
        flexGrow = 2.0,
        textAlign = "end",
        process_value = function(value) return format_memory_size(value, true) .. "/s" end,
        sort_value = function(value) return value end
    },
    {
        data_key = "io_write",
        label = noctalia.tr("procs.process.io_write.label"),
        tip = noctalia.tr("procs.process.io_write.tip"),
        flexGrow = 2.0,
        textAlign = "end",
        process_value = function(value) return format_memory_size(value, true) .. "/s" end,
        sort_value = function(value) return value end
    },
}

local processes_data_transfer = {}
for _, column in ipairs(processes_data) do
    processes_data_transfer[column.data_key] = column.sort_value
end

local function get_processes_data()
    return processes_data
end

local function get_processes_data_transfer()
    return processes_data_transfer
end

local function get_order_by(context, is_app)
    local clear_context = context
    if context:sub(1, 1) == "-" then
        clear_context = context:sub(2)
    end
    for _, column in ipairs(get_processes_data()) do
        if column.data_key == clear_context then
            local ret = column.data_key
            if context:sub(1, 1) == "-" then
                ret = "-" .. column.data_key
            end
            if is_app and ret == "pid" then
                ret = "-" .. "name"
            elseif is_app and ret == "-pid" then
                ret = "-" .. "-name"
            end
            return ret
        end
    end
    return "mem"
end

local function values_are_equal(a, b)
    if a == nil and b == nil then
        return true
    elseif a == nil or b == nil then
        return false
    end

    if type(a) == "number" and type(b) == "number" then
        return a == b
    else
        return tostring(a) == tostring(b)
    end
end

local function compare_values(a, b, reverse)
    if a == nil and b == nil then
        return false
    elseif a == nil then
        return not reverse
    elseif b == nil then
        return reverse
    end

    if type(a) == "number" and type(b) == "number" then
        if reverse then
            return a > b
        else
            return a < b
        end
    else
        if reverse then
            return tostring(a) > tostring(b)
        else
            return tostring(a) < tostring(b)
        end
    end
end

-- Sort the processes based on the selected column and order (ascending or descending).
local function sort_processes(processes, is_app)
    local order_by = get_order_by(g_order_by_context, is_app)
    local reverse = true
    if order_by:sub(1, 1) == "-" then
        order_by = order_by:sub(2)
        reverse = false
    end

    local data = get_processes_data_transfer()

    table.sort(processes, function(a, b)
        local a_value = data[order_by](a[order_by])
        local b_value = data[order_by](b[order_by])
        local a_value2 = data["name"](a["name"])
        local b_value2 = data["name"](b["name"])

        if a_value == nil and b_value == nil then
            return false
        elseif a_value == nil then
            return not reverse
        elseif b_value == nil then
            return reverse
        end

        if values_are_equal(a_value, b_value) then
            return compare_values(a_value2, b_value2, reverse)
        end

        return compare_values(a_value, b_value, reverse)
    end)
end

local function sort_all_processes()
    sort_processes(g_data["processes"], false)
    sort_processes(g_data["applications"], true)
    for _, app_data in pairs(g_data["applications"]) do
        sort_processes(app_data["processes"], false)
    end
end

-- Render the header row for the process list, with sortable columns.
local function render_processes_header()
    local children = {}
    local order_by = get_order_by(g_order_by_context, false)
    for _, column in ipairs(get_processes_data()) do
        local sort_indicator = ""
        if order_by == column.data_key then
            sort_indicator = "▼ "
        elseif order_by == "-" .. column.data_key then
            sort_indicator = "▲ "
        end
        table.insert(children, ui.button({
            text = sort_indicator .. column.label,
            tooltip = column.tip,
            flexGrow = column.flexGrow,
            variant = "ghost",
            controlSize = "sm",
            fontSize = 10,
            selected = order_by == column.data_key or order_by == "-" .. column.data_key,
            onClick = function()
                if column.data_key == g_order_by_context then
                    g_order_by_context = "-" .. column.data_key
                else
                    g_order_by_context = column.data_key
                end
                sort_all_processes()
                render()
            end
        }))
    end
    return ui.row({
        gap = 8,
        fill = "surface_variant",
        radius = 8,
    }, children)
end

local hover_row_key = nil
local expanded_key = nil
local apps_expand_state = {}
local apps_expanded = true
local all_processes_expanded = true

local function toggle_app_expand_state(app_id)
    if apps_expand_state[app_id] == nil then
        apps_expand_state[app_id] = true
    else
        apps_expand_state[app_id] = not apps_expand_state[app_id]
    end
end

local function is_app_expanded(app_id)
    return apps_expand_state[app_id] == true
end

local function render_processes_type_header(is_app)
    local children = {}
    local expanded
    if is_app then
        expanded = apps_expanded
    else
        expanded = all_processes_expanded
    end

    local header_text = ""
    local row_key = "header"
    if is_app then
        header_text = noctalia.tr("procs.applications_header")
        row_key = row_key .. "-app"
    else
        header_text = noctalia.tr("procs.processes_header")
        row_key = row_key .. "-all"
    end

    if expanded then
        table.insert(children, ui.glyph({
            name = "chevron-down",
            color = "on_surface_variant",
        }))
    else
        table.insert(children, ui.glyph({
            name = "chevron-right",
            color = "on_surface_variant",
        }))
    end

    table.insert(children, ui.label({
        text = header_text,
        fontWeight = "bold",
        maxLines = 1,
        flexGrow = 1,
        color = "secondary",
    }))

    return ui.row({
            key = row_key,
            gap = 8,
            padding = 1,
            radius = 2,
            onClick = function()
                if is_app then
                    apps_expanded = not apps_expanded
                else
                    all_processes_expanded = not all_processes_expanded
                end
                render()
            end
        }, children)
end

-- Render the list of processes for the selected GPU, with sortable columns.
local function render_processes(processes, is_app, level)
    level = level or 0
    local key_prefix = is_app and "app-" or "all-"
    local children = {}
    local order_by = get_order_by(g_order_by_context, is_app)
    local default_hover_fill = noctalia.getConfig("process_hover_background") or "surface_variant"
    local default_hover_color = noctalia.getConfig("process_hover_color") or "on_surface_variant"
    for _, process in ipairs(processes) do
        local process_children = {}
        local process_key = key_prefix .. "proc-row-" .. (process.pid or process.name or "")
        local is_hovered = hover_row_key == process_key
        for col_idx, column in ipairs(get_processes_data()) do
            local fill = (is_hovered or (expanded_key ~= nil and expanded_key == process_key)) and default_hover_fill or "surface"
            local color = (is_hovered or (expanded_key ~= nil and expanded_key == process_key)) and default_hover_color or "on_surface"
            local fontWeight = "medium"
            if order_by == column.data_key or order_by == "-" .. column.data_key then
                if not is_hovered then
                    fill = noctalia.getConfig("sort_column_background") or "surface_variant"
                    color = noctalia.getConfig("sort_column_color") or "on_surface_variant"
                end
                fontWeight = "bold"
            end

            local label_box = {}

            if col_idx == 1 then
                table.insert(label_box, 
                    ui.box({
                        opacity = 0.0,
                        width = 16 * level * (col_idx == 1 and 1 or 0),
                    }))
                table.insert(label_box, 
                    ui.image({
                        path = process.icon,
                        width = 16,
                        height = 16,
                    }))
            end
            table.insert(label_box, 
                ui.label({
                    text = column.process_value(process[column.data_key]),
                    maxLines = 1,
                    flexGrow = 1,
                    color = process[column.data_key] and color or color .. "/0.4",
                    textAlign = column.textAlign,
                    fontWeight = fontWeight,
                })
            )

            table.insert(process_children, ui.column({
                flexGrow = column.flexGrow,
                paddingH = 2,
                fill = fill,
            }, {
                ui.row({
                    flexGrow = 1,
                    gap = 4,
                }, label_box)
            }))
        end

        if expanded_key ~= nil and expanded_key == process_key then
            table.insert(children, ui.column({
                radius = 2,
                border = "outline",
                borderWidth = 1,
                padding = 1,
                fill = default_hover_fill
            }, {
                ui.row({
                    key = process_key,
                    gap = 8,
                    onClick = function()
                        expanded_key = nil
                        render()
                    end
                }, process_children),
                ui.label({
                    text = table.concat(process.cmdline, " "),
                    flexGrow = 1,
                    maxLines = 4,
                    fontSize = 12,
                    color = default_hover_color,
                }),
                ui.row({
                    key = process_key .. "-expanded",
                    gap = 8,
                    padding = 4,
                    radius = 2,
                    fill = default_hover_fill,
                }, {
                    ui.button({
                        text = noctalia.tr("procs.process_buttons.kill.label"),
                        tooltip = noctalia.tr("procs.process_buttons.kill.tip"),
                        glyph = "square-x",
                        variant = "destructive",
                        controlSize = "sm",
                        onClick = function()
                            noctalia.runAsync({"kill", tostring(process.pid)})
                            expanded_key = nil
                            render()
                        end
                    }),
                    ui.button({
                        text = noctalia.tr("procs.process_buttons.force_kill.label"),
                        tooltip = noctalia.tr("procs.process_buttons.force_kill.tip"),
                        glyph = "skull",
                        variant = "destructive",
                        controlSize = "sm",
                        onClick = function()
                            noctalia.runAsync({"kill", "-9", tostring(process.pid)})
                            expanded_key = nil
                            render()
                        end
                    }),
                    ui.spacer({flexGrow = 1}),
                    ui.button({
                        text = noctalia.tr("procs.process_buttons.copy_pid.label"),
                        tooltip = noctalia.tr("procs.process_buttons.copy_pid.tip"),
                        glyph = "clipboard",
                        variant = "default",
                        controlSize = "sm",
                        onClick = function()
                            noctalia.copyToClipboard(process.pid, "text/plain")
                            expanded_key = nil
                            render()
                        end
                    }),
                    ui.button({
                        text = noctalia.tr("procs.process_buttons.copy_cmdline.label"),
                        tooltip = noctalia.tr("procs.process_buttons.copy_cmdline.tip"),
                        glyph = "clipboard",
                        variant = "default",
                        controlSize = "sm",
                        onClick = function()
                            noctalia.copyToClipboard(table.concat(process.cmdline, " "), "text/plain")
                            expanded_key = nil
                            render()
                        end
                    }),
                    ui.button({
                        text = noctalia.tr("procs.process_buttons.cancel.label"),
                        tooltip = noctalia.tr("procs.process_buttons.cancel.tip"),
                        glyph = "cancel",
                        variant = "primary",
                        controlSize = "sm",
                        onClick = function()
                            expanded_key = nil
                            render()
                        end
                    })
                })
            }))
        else
            table.insert(children, ui.row({
                key = process_key,
                gap = 8,
                padding = 1,
                radius = 2,
                border = "outline",
                borderWidth = (is_hovered or (expanded_key ~= nil and expanded_key == process_key)) and 1 or 0,
                fill = (is_hovered or (expanded_key ~= nil and expanded_key == process_key)) and default_hover_fill or "surface",
                onHover = function(state, key)
                    local old_state = hover_row_key
                    if state == "true" then
                        hover_row_key = process_key
                    else
                        hover_row_key = nil
                    end
                    if old_state ~= hover_row_key then
                        render()
                    end
                end,
                onClick = function()
                    if is_app then
                        toggle_app_expand_state(process.app_id)
                        render()
                    elseif expanded_key == nil or expanded_key ~= process_key then
                        expanded_key = process_key
                        render()
                    end
                end
            }, process_children))
        end
        if is_app and is_app_expanded(process.app_id) then
            local app_processes_children = render_processes(process.processes, false, level + 1)
            table.move(app_processes_children, 1, #app_processes_children, #children + 1, children)
        end

    end

    return children
end

local function render_header_block()
    return {
        ui.row({ key = "header", gap = 8, align = "center" }, {
            ui.label({
                key = "title",
                text = noctalia.tr("title"),
                fontSize = 16,
                fontWeight = "bold",
                color = "on_surface",
            }),
            ui.spacer({ key = "gap", flexGrow = 1 }),
            ui.button({
                key = "settings",
                glyph = "settings",
                variant = "ghost",
                tooltip = noctalia.tr("tip_settings"),
                onClick = function()
                    noctalia.openSettings()
                end,
            }),
            ui.button({
                key = "close",
                glyph = "close",
                variant = "ghost",
                tooltip = noctalia.tr("tip_close"),
                onClick = function()
                    panel.close()
                end,
            }),
        }),
    }
end

local function render_processes_block()
    local rows
    local children = {}

    table.insert(children, render_processes_type_header(true))
    if apps_expanded then
        rows = render_processes(g_data["applications"], true, 1)
        table.move(rows, 1, #rows, #children + 1, children)
    end

    table.insert(children, render_processes_type_header(false))
    if all_processes_expanded then
        rows = render_processes(g_data["processes"], false, 1)
        table.move(rows, 1, #rows, #children + 1, children)
    end

    return children
end

-- Render the entire panel
render = function()
    if render_no_data_message() then
        return
    end

    local children = render_header_block()

    table.insert(children, render_info())
    table.insert(children, 
        ui.column({
                fill = "surface_variant",
                border = "outline",
                borderWidth = 1,
                flexGrow = 1,
                radius = 12,
                padding = 4
            }, {
                render_processes_header(),
                ui.scroll({ 
                    flexGrow = 1, 
                    border = "outline",
                    borderWidth = 1,
                    fill = "surface",
                    radius = 10,
                }, render_processes_block())
            })    
    )

    panel.render(ui.column({
        flexGrow = 1,
        gap = 6,
    }, children))
end

-- Helper function to check if a string starts with a given prefix.
local function starts_with(str: string, prefix: string): boolean
    return string.sub(str, 1, #prefix) == prefix
end

local function run_processes_stream()
    local cmd = "python " .. noctalia.pluginDir() .. "/procs.py " .. tostring(noctalia.getConfig("delay"))
    noctalia.runStream(cmd,
        function(line)
            if line:find("tordex/procs:pid:") then
                procs_pid = tonumber(line:match("tordex/procs:pid:(%d+)"))
            elseif starts_with(line, "tordex/procs:ready:") then
                local filename = line:match("tordex/procs:ready:(.+)")
                noctalia.readFileAsync(filename, function(content, err)
                    if content then
                        local decoded = noctalia.json.decode(content) or nil
                        if decoded then
                            g_data = decoded
                            sort_all_processes()
                            render()
                        end
                    end
                end)
            end
        end)
end

-- Stop the procs process if it is running, and reset the PID to -1.
local function stop_processes_stream()
    if procs_pid ~= -1 then
        local cmd = "pkill -SIGINT -p " .. tostring(procs_pid)
        noctalia.runAsync(cmd)
        procs_pid = -1
    end
end

-- Handle the panel opening event, and check for a context key to sort the process list by.
function onOpen(context)
    noctalia.log("[procs] Panel opened with context: " .. tostring(context))
    if context ~= nil and context ~= "" then
        g_order_by_context = context:lower()
        sort_all_processes()
        render()
    end
    stop_processes_stream()
    run_processes_stream()
    render()
end

-- Handle the panel closing event, and stop the nvtop process.
function onClose()
    stop_processes_stream()
end

render()

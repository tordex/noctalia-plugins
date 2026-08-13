--!nonstrict

local services = {}

local function onStopClicked(service)
  noctalia.state.set("stop", service)
end

local function onConnectClicked(service)
  noctalia.state.set("toggle-vpn", service)
end

local function onRestartClicked(service)
  noctalia.state.set("restart", service)
end

local function render()
  local rows = {}

  for service, config in services do
    local srv_glyph = (config.is_user) and "user" or "terminal-2"
    local tun_state = (config.tun_state == "active")
    local srv_color = (config.state == "active") and "#00EE00" or "error"
    local stop_enabled = (config.state == "active")
    table.insert(rows, 
      ui.row({ align = "center", justify = "space_between", gap = 8 }, 
      {
        ui.glyph({ name = srv_glyph, size = 16 }),
        ui.label({ text = tostring(config.port), color = srv_color, flexGrow = 2 }),
        ui.label({ text = config.label, color = srv_color, flexGrow = 2 }),
        ui.label({ text = config.state, color = srv_color, flexGrow = 4 }),
        ui.button({ glyph = "stop", 
                    controlSize = "sm", 
                    tooltip = "Stop service " ..tostring(service),
                    onClick = function() onStopClicked(service) end, 
                    enabled = stop_enabled }),
        ui.button({ glyph = "reload", 
                    controlSize = "sm", 
                    tooltip = "Restart service " .. tostring(service),
                    onClick = function() onRestartClicked(service) end }),
        ui.toggle({ checked = tun_state, 
                    onChange = function() onConnectClicked(service) end, 
                    enabled = stop_enabled }),
      })
    )
  end

  panel.render(
      ui.column({ flexGrow = 1, padding = 8}, 
      {
        ui.label({ text = "Manage VPN Services", fontWeight = "medium", fontSize = 18, color = "on_surface_variant" }),
        ui.scroll({ flexGrow = 1}, 
        {
          ui.column({ gap = 8 }, rows)
        })
      })
  )
end

noctalia.state.watch("states", function(value)
  services = value or {}
  render()
end)


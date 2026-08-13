--!nonstrict

local is_connected = false
local vpn_label = "VPN"
local port = 0

local function render()
  -- Stack along the bar: a row in a horizontal bar, a column in a side bar.
  local container = barWidget.isVertical() and ui.column or ui.row
  if is_connected then
    barWidget.render(container({ gap = 6, align = "center" }, {
      ui.glyph({ name = "plug-connected", color = "on_surface" }),
      ui.label({ text = vpn_label, color = "on_surface" }),
      ui.label({ text = tostring(port), color = "on_surface" }),
    }))
  else
    barWidget.render(container({ gap = 6, align = "center" }, {
      ui.glyph({ name = "plug-connected-x", color = "on_surface" }),
    }))
  end
end

-- Live updates from the plugin's background service (ticker.luau).
noctalia.state.watch("states", function(services)
  local l_is_connected = false
  local l_vpn_label = "VPN"
  local l_port = 0
  for service, config in services do
    if config.tun_state == "active" then
      l_is_connected = true
      l_vpn_label = config.label
      l_port = config.port
      break
    end
  end
  if l_is_connected ~= is_connected or l_vpn_label ~= vpn_label or l_port ~= port then
    is_connected = l_is_connected
    vpn_label = l_vpn_label
    port = l_port
    noctalia.log("VPN state changed: " .. tostring(is_connected) .. " label: " .. vpn_label .. " port: " .. tostring(port))
    render()
  end
end)

function update()
  noctalia.setUpdateInterval(1000)
  render()
end

function onClick()
  noctalia.togglePanel("tordex/manage-vpn:panel")
end
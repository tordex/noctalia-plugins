--!nonstrict
-- Prefer the user-configured data_path setting; fall back to the plugin's
-- own persistent data directory when unset.

local services = {
  ["ssh-vpn"] = {
        label = "DE",
        port = 8888,
        is_user = false,
        state = "unknown",
        tun_state = "unknown",
      },
  ["ssh-ca-vpn"] = {
        label = "UK",
        port = 8885,
        is_user = true,
        state = "unknown",
        tun_state = "unknown",
      },
  ["ssh-fi-vpn"] = {
        label = "FI",
        port = 8883,
        is_user = true,
        state = "unknown",
        tun_state = "unknown",
      },
  ["ssh-us-vpn"] = {
        label = "US",
        port = 8885,
        is_user = true,
        state = "unknown",
        tun_state = "unknown",
      },
  ["ssh-msk-vpn"] = {
        label = "RU",
        port = 8889,
        is_user = true,
        state = "unknown",
        tun_state = "unknown",
      },
}

noctalia.setUpdateInterval(1000)

function update()
  for service, config in services do
    local cmd
    if config.is_user then
      cmd = "systemctl --user is-active " .. service .. ".service"
    else
      cmd = "systemctl is-active " .. service .. ".service"
    end

    noctalia.runAsync(cmd, function(result)
      local srv = service
      local port = config.port
      local newState = "unknown"
      if result.stdout:match("inactive") then
        newState = "inactive"
      elseif result.stdout:match("failed") then
        newState = "failed"
      else
        newState = "active"
      end
      services[srv].state = newState
      
      local cmdTun = "systemctl is-active badvpn-tun2socks@" .. tostring(port) .. ".service"
      noctalia.runAsync(cmdTun, function(result)
        local newState = "unknown"
        if result.stdout:match("inactive") then
          newState = "inactive"
        elseif result.stdout:match("active") then
          newState = "active"
        else
          newState = "inactive"
        end
        services[srv].tun_state = newState
      end, 20000)

    end, 20000)

    noctalia.state.set("states", services)
  end
end

noctalia.state.watch("stop", function(service)
  if service then
    local cmd
    if services[service].is_user then
      cmd = "systemctl --user stop " .. service .. ".service"
    else
      cmd = "pkexec systemctl stop " .. service .. ".service"
    end
    noctalia.runAsync(cmd, function(result)
      update()
    end, 60000)
  end
end)

noctalia.state.watch("restart", function(service)
  if service then
    local cmd
    if services[service].is_user then
      cmd = "systemctl --user restart " .. service .. ".service"
    else
      cmd = "pkexec systemctl restart " .. service .. ".service"
    end
    noctalia.runAsync(cmd, function(result)
      update()
    end, 60000)
  end
end)

noctalia.state.watch("toggle-vpn", function(service)
  local bash_cmd;
  if services[service].tun_state == "active" then
    bash_cmd = "/home/tordex/scripts/vpnctl.sh stop " .. tostring(services[service].port)
  else
    bash_cmd = "/home/tordex/scripts/vpnctl.sh start " .. tostring(services[service].port)
    for srv, config in services do
      if config.tun_state == "active" and srv ~= service then
        bash_cmd = "/home/tordex/scripts/vpnctl.sh stop " .. tostring(config.port) .. ";" .. bash_cmd
        break
      end
    end
  end

  local cmd = "pkexec bash -c \"" .. bash_cmd .. "\""
  noctalia.log("Executing command: " .. cmd)
  noctalia.runAsync(cmd, function(result)
    update()
    noctalia.togglePanel("tordex/manage-vpn:panel")
  end, 60000)
end)

-- Soft AP binding enforcement.
-- Keeps a client on the bound mesh node / band by kicking it from wrong APs.
-- Bindings are stored in /etc/fwx_ap_bind.json (local edits) and merged with
-- peers' /tmp/fwx_peer/<ip>.bindings.json published by fwx_sync.sh.

local json = require "luci.jsonc"

local BIND_FILE = "/etc/fwx_ap_bind.json"
local PEER_DIR = "/tmp/fwx_peer"
local STATE_FILE = "/tmp/fwx_bind.state"
local KICK_INTERVAL = 60
local BAN_TIME = 20000
local DRY = (arg and arg[1] == "-n") or os.getenv("FWX_BIND_DRY") == "1"

local function log(msg)
	os.execute(string.format("logger -t fwx_bind '%s' 2>/dev/null", msg:gsub("'", "")))
end

local function read_file(path)
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end
	local data = fd:read("*a")
	fd:close()
	return data
end

local function load_json(path)
	local raw = read_file(path)
	if not raw or raw == "" then
		return nil
	end
	local ok, parsed = pcall(json.parse, raw)
	if ok then
		return parsed
	end
	return nil
end

local function own_ip()
	local fd = io.popen("uci -q get network.lan.ipaddr 2>/dev/null")
	if not fd then
		return nil
	end
	local ip = fd:read("*l")
	fd:close()
	ip = ip and ip:match("^(%d+%.%d+%.%d+%.%d+)")
	if ip then
		return ip
	end
	return nil
end

local function merge_bindings()
	local merged = {}
	local files = {}

	local local_data = load_json(BIND_FILE)
	if local_data and type(local_data.bindings) == "table" then
		files[#files + 1] = local_data.bindings
	end

	local dir = io.popen("ls -1 " .. PEER_DIR .. "/*.bindings.json 2>/dev/null")
	if dir then
		for path in dir:lines() do
			local data = load_json(path)
			if data and type(data.bindings) == "table" then
				files[#files + 1] = data.bindings
			end
		end
		dir:close()
	end

	for _, set in ipairs(files) do
		for mac, item in pairs(set) do
			if type(item) == "table" then
				local key = string.upper(tostring(mac))
				local ts = tonumber(item.ts) or 0
				if not merged[key] or ts >= (tonumber(merged[key].ts) or 0) then
					merged[key] = item
				end
			end
		end
	end

	return merged
end

local function station_macs(ifname)
	local macs = {}
	local fd = io.popen("iw dev " .. ifname .. " station dump 2>/dev/null")
	if not fd then
		return macs
	end
	for line in fd:lines() do
		local mac = line:match("^Station%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
		if mac then
			macs[mac:lower()] = true
		end
	end
	fd:close()
	return macs
end

local function load_state()
	local state = {}
	local raw = read_file(STATE_FILE)
	if not raw then
		return state
	end
	for mac, ts in raw:gmatch("([^%s]+)%s+(%d+)") do
		state[mac] = tonumber(ts)
	end
	return state
end

local function save_state(state)
	local fd = io.open(STATE_FILE, "w")
	if not fd then
		return
	end
	for mac, ts in pairs(state) do
		fd:write(string.format("%s %d\n", mac, ts))
	end
	fd:close()
end

local function host_reachable(ip)
	local ok = os.execute("ping -c 1 -W 1 -q " .. ip .. " >/dev/null 2>&1")
	return ok == 0 or ok == true
end

local function band_of(ifname)
	if ifname:match("^phy0") then
		return "2g"
	elseif ifname:match("^phy1") then
		return "5g"
	end
	return "auto"
end

local function kick(ifname, mac)
	local cmd = string.format(
		"ubus call hostapd.%s del_client '{\"addr\":\"%s\",\"deauth\":true,\"ban_time\":%d,\"reason\":5}' >/dev/null 2>&1",
		ifname, string.upper(mac), BAN_TIME)
	if DRY then
		log(string.format("dry-run: would kick %s from %s", mac, ifname))
		return true
	end
	local ok = os.execute(cmd)
	return ok == 0 or ok == true
end

local function main()
	local self_ip = own_ip()
	if not self_ip then
		log("skip: cannot determine own ip")
		return
	end

	local bindings = merge_bindings()
	local state = load_state()
	local now = os.time()
	local changed = false

	for _, ifname in ipairs({ "phy0-ap0", "phy1-ap0" }) do
		local macs = station_macs(ifname)
		for mac in pairs(macs) do
			local b = bindings[string.upper(mac)]
			if b and not b.deleted and b.node and b.node ~= "" then
				local band = band_of(ifname)
				local wrong = false

				if b.node ~= self_ip then
					wrong = true
				elseif b.band == "2g" or b.band == "5g" then
					if b.band ~= band then
						wrong = true
					end
				end

				if wrong then
					local target_ok = (b.node == self_ip) or host_reachable(b.node)
					local last = state[mac] or 0
					if target_ok and (now - last) >= KICK_INTERVAL then
						if kick(ifname, mac) then
							state[mac] = now
							changed = true
							log(string.format("kick %s from %s %s (target %s/%s)",
								mac, ifname, band, b.node, b.band or "auto"))
						end
					elseif not target_ok then
						log(string.format("skip kick %s: target %s unreachable", mac, b.node))
					end
				end
			end
		end
	end

	if changed then
		save_state(state)
	end
end

main()

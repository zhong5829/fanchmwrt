module("luci.controller.user", package.seeall)
local utl = require "luci.util"

local SYNC_PEER_DIR = "/tmp/fwx_peer"
local SYNC_STALE_SEC = 30
local SYNC_DEFAULT_PAGE_SIZE = 15

local function sync_to_num(value, fallback)
	local num = tonumber(value)
	if num == nil then
		return fallback or 0
	end
	return num
end

local function sync_is_blank(value)
	if value == nil then
		return true
	end
	value = tostring(value)
	return value == "" or value == "*" or value == "--" or value == "0.0.0.0" or value == "::"
end

-- Mesh point / repeater uplink vifs report their backhaul peer through
-- "iwinfo assoclist"; those MACs are infrastructure, not terminals.
local function sync_is_infra_user(user)
	local ifname = string.lower(tostring(user.wifi_ifname or ""))
	return ifname:find("mesh", 1, true) ~= nil
end

-- Fill missing local fields with a peer node's view; never overwrite local data.
local function sync_merge_user(dst, src)
	if sync_to_num(src.online) == 1 then
		dst.online = 1
		if sync_to_num(src.active) == 1 then
			dst.active = 1
		end
	end
	if sync_is_blank(dst.ip) and not sync_is_blank(src.ip) then
		dst.ip = src.ip
	end
	if sync_is_blank(dst.hostname) and not sync_is_blank(src.hostname) then
		dst.hostname = src.hostname
	end
	if sync_is_blank(dst.nickname) and not sync_is_blank(src.nickname) then
		dst.nickname = src.nickname
	end
	if sync_is_blank(dst.app) and not sync_is_blank(src.app) then
		dst.app = src.app
		dst.app_id = src.app_id
	end
	if sync_is_blank(dst.url) and not sync_is_blank(src.url) then
		dst.url = src.url
	end
	if (type(dst.applist) ~= "table" or #dst.applist == 0) and type(src.applist) == "table" and #src.applist > 0 then
		dst.applist = src.applist
	end
	if sync_to_num(dst.session) < sync_to_num(src.session) then
		dst.session = src.session
	end
	if sync_to_num(dst.up_rate) < sync_to_num(src.up_rate) then
		dst.up_rate = src.up_rate
	end
	if sync_to_num(dst.down_rate) < sync_to_num(src.down_rate) then
		dst.down_rate = src.down_rate
	end
	if sync_to_num(dst.today_up_bytes) < sync_to_num(src.today_up_bytes) then
		dst.today_up_bytes = src.today_up_bytes
	end
	if sync_to_num(dst.today_down_bytes) < sync_to_num(src.today_down_bytes) then
		dst.today_down_bytes = src.today_down_bytes
	end
	if sync_to_num(dst.today_active_time) < sync_to_num(src.today_active_time) then
		dst.today_active_time = src.today_active_time
	end
	if sync_to_num(dst.rssi) == 0 and sync_to_num(src.rssi) ~= 0 then
		dst.rssi = src.rssi
	end
	if sync_is_blank(dst.band) and not sync_is_blank(src.band) then
		dst.band = src.band
	end
	if sync_is_blank(dst.wifi_ifname) and not sync_is_blank(src.wifi_ifname) then
		dst.wifi_ifname = src.wifi_ifname
	end
	if sync_to_num(dst.is_wireless) == 0 and sync_to_num(src.is_wireless) == 1 then
		dst.is_wireless = 1
		dst.terminal_type = src.terminal_type
	end
end

function merge_sync_users(local_list, peer_lists)
	local merged, order = {}, {}

	for _, user in ipairs(local_list or {}) do
		if type(user) == "table" and not sync_is_blank(user.mac) and not sync_is_infra_user(user) then
			local key = string.upper(tostring(user.mac))
			if merged[key] == nil then
				merged[key] = user
				order[#order + 1] = key
			else
				sync_merge_user(merged[key], user)
			end
		end
	end

	for _, peer_list in ipairs(peer_lists or {}) do
		for _, user in ipairs(peer_list or {}) do
			if type(user) == "table" and not sync_is_blank(user.mac) and not sync_is_infra_user(user) then
				local key = string.upper(tostring(user.mac))
				if merged[key] == nil then
					-- Only pull in devices a peer currently sees online.
					if sync_to_num(user.online) == 1 then
						merged[key] = user
						order[#order + 1] = key
					end
				else
					sync_merge_user(merged[key], user)
				end
			end
		end
	end

	local list = {}
	for _, key in ipairs(order) do
		list[#list + 1] = merged[key]
	end
	return list
end

function sort_sync_users(list)
	table.sort(list, function(a, b)
		local a_rank = (sync_to_num(a.online) == 1 and (sync_to_num(a.active) == 1 and 0 or 1) or 2)
		local b_rank = (sync_to_num(b.online) == 1 and (sync_to_num(b.active) == 1 and 0 or 1) or 2)
		if a_rank ~= b_rank then
			return a_rank < b_rank
		end
		if a_rank < 2 then
			return sync_to_num(a.online_time) > sync_to_num(b.online_time)
		end
		return sync_to_num(a.offline_time) > sync_to_num(b.offline_time)
	end)
end

local function load_sync_peer_lists()
	local lists = {}
	local ok, fs = pcall(require, "nixio.fs")
	if not ok or not fs then
		return lists
	end
	local json = require "luci.jsonc"
	local now = os.time()
	local ok_dir, dir = pcall(fs.dir, SYNC_PEER_DIR)
	if not ok_dir or not dir then
		return lists
	end
	for name in dir do
		if name:match("%.json$") then
			local path = SYNC_PEER_DIR .. "/" .. name
			local stat = fs.stat(path)
			if stat and stat.mtime and (now - stat.mtime) <= SYNC_STALE_SEC then
				local fd = io.open(path, "r")
				if fd then
					local raw = fd:read("*a")
					fd:close()
					local parsed = json.parse(raw)
					local data = parsed and (parsed.data or parsed)
					if data and type(data.list) == "table" then
						lists[#lists + 1] = data.list
					end
				end
			end
		end
	end
	return lists
end

local AP_BIND_FILE = "/etc/fwx_ap_bind.json"

local function read_json_file(path)
	local fd = io.open(path, "r")
	if not fd then
		return nil
	end
	local raw = fd:read("*a")
	fd:close()
	local ok, parsed = pcall(require("luci.jsonc").parse, raw)
	if ok then
		return parsed
	end
	return nil
end

function load_effective_bindings()
	local merged = {}
	local sets = {}

	local local_data = read_json_file(AP_BIND_FILE)
	if local_data and type(local_data.bindings) == "table" then
		sets[#sets + 1] = local_data.bindings
	end

	local dir = io.popen("ls -1 " .. SYNC_PEER_DIR .. "/*.bindings.json 2>/dev/null")
	if dir then
		for path in dir:lines() do
			local data = read_json_file(path)
			if data and type(data.bindings) == "table" then
				sets[#sets + 1] = data.bindings
			end
		end
		dir:close()
	end

	for _, set in ipairs(sets) do
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

local function save_local_binding(mac, node, band, deleted)
	local data = read_json_file(AP_BIND_FILE) or {}
	if type(data.bindings) ~= "table" then
		data.bindings = {}
	end
	data.bindings[string.upper(mac)] = {
		node = node or "",
		band = band or "auto",
		ts = os.time(),
		deleted = deleted and true or false
	}
	local tmp = AP_BIND_FILE .. ".tmp"
	local fd = io.open(tmp, "w")
	if not fd then
		return false
	end
	fd:write(require("luci.jsonc").stringify(data))
	fd:close()
	os.rename(tmp, AP_BIND_FILE)
	return true
end

local function own_lan_ip()
	local fd = io.popen("uci -q get network.lan.ipaddr 2>/dev/null")
	if not fd then
		return nil
	end
	local ip = fd:read("*l")
	fd:close()
	return ip and ip:match("^(%d+%.%d+%.%d+%.%d+)")
end

local function build_bind_nodes()
	local nodes = {}
	local self_ip = own_lan_ip()
	local seen = {}
	local peers = {}
	local fd = io.popen("uci -q get fwx_sync.sync.peers 2>/dev/null")
	if fd then
		local line = fd:read("*l")
		fd:close()
		for ip in (line or ""):gmatch("%S+") do
			peers[#peers + 1] = ip
		end
	end
	if #peers == 0 then
		peers = { "192.168.110.1", "192.168.110.2", "192.168.110.3" }
	end
	for _, ip in ipairs(peers) do
		if not seen[ip] then
			seen[ip] = true
			local last = ip:match("%.(%d+)$")
			local label
			if last == "1" then
				label = "主路由 (" .. ip .. ")"
			else
				label = "Node" .. (last or ip) .. " (" .. ip .. ")"
			end
			if ip == self_ip then
				label = label .. " 本机"
			end
			nodes[#nodes + 1] = { ip = ip, label = label }
		end
	end
	return nodes
end

function annotate_ap_bindings(list)
	local bindings = load_effective_bindings()
	for _, user in ipairs(list or {}) do
		local b = bindings[string.upper(tostring(user.mac or ""))]
		if b and not b.deleted and b.node and b.node ~= "" then
			user.bind_node = b.node
			user.bind_band = b.band or "auto"
		else
			user.bind_node = ""
			user.bind_band = ""
		end
	end
end

function set_ap_bind()
	luci.http.prepare_content("application/json")
	local mac = normalize_mac(luci.http.formvalue("mac"))
	local node = luci.http.formvalue("node") or ""
	local band = luci.http.formvalue("band") or "auto"
	if not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
		luci.http.write_json({ code = 1, message = "invalid mac" })
		return
	end
	if band ~= "auto" and band ~= "2g" and band ~= "5g" then
		band = "auto"
	end
	local valid_node = false
	for _, item in ipairs(build_bind_nodes()) do
		if item.ip == node then
			valid_node = true
			break
		end
	end
	if not valid_node then
		luci.http.write_json({ code = 1, message = "invalid node" })
		return
	end
	if save_local_binding(mac, node, band, false) then
		luci.http.write_json({ code = 0, message = "success" })
	else
		luci.http.write_json({ code = 1, message = "save failed" })
	end
end

function del_ap_bind()
	luci.http.prepare_content("application/json")
	local mac = normalize_mac(luci.http.formvalue("mac"))
	if not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
		luci.http.write_json({ code = 1, message = "invalid mac" })
		return
	end
	if save_local_binding(mac, "", "auto", true) then
		luci.http.write_json({ code = 0, message = "success" })
	else
		luci.http.write_json({ code = 1, message = "save failed" })
	end
end

function index()
	local page
	entry({"admin", "fwx_user"}, alias("admin", "fwx_user", "list"), _("User List"), 13).dependent = true
	entry({"admin", "fwx_user", "list"}, cbi("user/user_list", {hideapplybtn=true, hidesavebtn=true, hideresetbtn=true}),
	 _("User List"), 13).leaf = true
	
	entry({"admin", "fwx_user", "detail"}, cbi("user/user_detail", {hideapplybtn=true, hidesavebtn=true, hideresetbtn=true}), _("User Detail")).leaf = true
	entry({"admin", "fwx", "user_status"}, call("user_status"), nil).leaf = true
	entry({"admin", "fwx", "dev_visit_list"}, call("get_dev_visit_list"), nil).leaf = true
	entry({"admin", "fwx", "dev_visit_time"}, call("get_dev_visit_time"), nil).leaf = true
	entry({"admin", "fwx", "app_class_visit_time"}, call("get_app_class_visit_time"), nil).leaf = true
	entry({"admin", "fwx", "get_class_list"}, call("get_class_list"), nil).leaf = true
	entry({"admin", "fwx", "get_all_users"}, call("get_all_users"), nil).leaf = true
	entry({"admin", "fwx", "set_ap_bind"}, call("set_ap_bind"), nil).leaf = true
	entry({"admin", "fwx", "del_ap_bind"}, call("del_ap_bind"), nil).leaf = true
	entry({"admin", "fwx", "get_system_base_info"}, call("get_system_base_info"), nil).leaf = true
	entry({"admin", "fwx", "get_mac_blacklist"}, call("get_mac_blacklist"), nil).leaf = true
	entry({"admin", "fwx", "add_mac_blacklist"}, call("add_mac_blacklist"), nil).leaf = true
	entry({"admin", "fwx", "del_mac_blacklist"}, call("del_mac_blacklist"), nil).leaf = true
	entry({"admin", "fwx", "get_parental_control_detail"}, call("get_parental_control_detail"), nil).leaf = true
	entry({"admin", "fwx", "set_nickname"}, call("set_nickname"), nil).leaf = true
	entry({"admin", "fwx", "get_hourly_stats"}, call("get_hourly_stats"), nil).leaf = true
	entry({"admin", "fwx", "get_user_daily_summary"}, call("get_user_daily_summary"), nil).leaf = true
	entry({"admin", "fwx", "get_user_basic_info"}, call("get_user_basic_info"), nil).leaf = true
	entry({"admin", "fwx", "get_online_offline_records"}, call("get_online_offline_records"), nil).leaf = true
	entry({"admin", "fwx", "get_user_parental_control_rules"}, call("get_user_parental_control_rules"), nil).leaf = true
end

function get_hostname_by_mac(dst_mac)
    leasefile="/tmp/dhcp.leases"
    local fd = io.open(leasefile, "r")
	if not fd then return end
    while true do
        local ln = fd:read("*l")
        if not ln then
            break
        end
        local ts, mac, ip, name, duid = ln:match("^(%d+) (%S+) (%S+) (%S+) (%S+)")
        if  dst_mac == mac then
            fd:close()
            return name
        end
    end
	fd:close()
    return ""
end


function get_app_name_by_id(appid)
	local class_fd = io.popen("find /tmp/appfilter/ -type f -name *.class |xargs cat |grep "..appid.."|awk '{print $2}'")
	if class_fd then
		local name = class_fd:read("*l")
		class_fd:close()
		return name
	end
	return ""
end

function cmp_func(a,b)
	return a.latest_time > b.latest_time
end

function normalize_mac(mac)
	if not mac then
		return ""
	end
	return tostring(mac):gsub("^%s+", ""):gsub("%s+$", ""):upper()
end

function call_fwx_common(api, data)
	local req_obj = {}
	req_obj.api = api
	req_obj.data = data or {}
	return utl.ubus("fwx", "common", req_obj)
end

function user_status()
	local json = require "luci.jsonc"
	luci.http.prepare_content("application/json")
	local fd = io.open("/proc/net/af_client","r")
	status_buf=fd:read('*a')
	fd:close()
	user_array=json.parse(status_buf)
	
	local req_obj = {}
	req_obj.api = "visit_list"
	req_obj.data = {}
	local visit_obj = utl.ubus("fwx", "common", req_obj)
	
	local user_array = {}
	if visit_obj and visit_obj.code == 2000 and visit_obj.data and visit_obj.data.dev_list then
		user_array = visit_obj.data.dev_list
	end
	local history={}
	for i, v in pairs(user_array) do
		visit_array=user_array[i].visit_info
		for j,s in pairs(visit_array) do
			print(user_array[i].mac, user_array[i].ip,visit_array[j].appid, visit_array[j].latest_time)
			total_time=visit_array[j].latest_time - visit_array[j].first_time;
			history[#history+1]={
				mac=user_array[i].mac,
				ip=user_array[i].ip,
				hostname=get_hostname_by_mac(user_array[i].mac),
				appid=visit_array[j].appid,
				appname=get_app_name_by_id(visit_array[j].appid),
				total_num=0,
				drop_num=0,
				latest_action=visit_array[j].latest_action,
				latest_time=os.date("%Y/%m/%d %H:%M:%S", visit_array[j].latest_time),
				first_time=os.date("%Y/%m/%d %H:%M:%S", visit_array[j].first_time),
				total_time=total_time
			}
		end
	end
	table.sort(history, cmp_func)
	luci.http.write_json(history);
end

function get_class_list()
	luci.http.prepare_content("application/json")

	local req_obj = {}
	req_obj.CopyRight = "www.fanchmwrt.com"
	req_obj.api = "class_list"
	req_obj.data = {}

	local resp_obj = utl.ubus("fwx", "common", req_obj)

	if resp_obj and resp_obj.code == 2000 and resp_obj.data then
		luci.http.write_json(resp_obj.data)
	else
		luci.http.write_json({class_list = {}})
	end
end


function get_all_users()
	luci.http.prepare_content("application/json")

	local flag = tonumber(luci.http.formvalue("flag")) or 3
	local page = tonumber(luci.http.formvalue("page")) or 0
	local page_size = tonumber(luci.http.formvalue("page_size")) or 0

	local req_obj = {}
	req_obj.api = "get_all_users"
	req_obj.data = {
		flag = flag
	}

	local resp_obj = utl.ubus("fwx", "common", req_obj)

	if not (resp_obj and resp_obj.code == 2000 and resp_obj.data) then
		luci.http.write_json({data = resp_obj or {}})
		return
	end

	local local_list = resp_obj.data.list or {}

	local peer_lists = {}
	local ok_peers, peers = pcall(load_sync_peer_lists)
	if ok_peers and peers then
		peer_lists = peers
	end

	local ok_merge, merged = pcall(merge_sync_users, local_list, peer_lists)
	if not ok_merge or not merged then
		merged = local_list
	end
	pcall(sort_sync_users, merged)
	pcall(annotate_ap_bindings, merged)

	local total_num = #merged
	local total_page = 1
	local resp_page = 0
	local resp_page_size = total_num

	if page > 0 then
		if page_size < 1 then
			page_size = SYNC_DEFAULT_PAGE_SIZE
		end
		total_page = math.max(1, math.ceil(total_num / page_size))
		if page > total_page then
			page = total_page
		end
		local start_idx = (page - 1) * page_size + 1
		local end_idx = math.min(page * page_size, total_num)
		local paged = {}
		for i = start_idx, end_idx do
			paged[#paged + 1] = merged[i]
		end
		merged = paged
		resp_page = page
		resp_page_size = page_size
	end

	luci.http.write_json({data = {
		list = merged,
		total_num = total_num,
		total_page = total_page,
		page = resp_page,
		page_size = resp_page_size,
		bind_nodes = build_bind_nodes()
	}})
end

function get_system_base_info()
	luci.http.prepare_content("application/json")

	local req_obj = {}
	req_obj.api = "get_system_base_info"
	req_obj.data = {}

	local resp_obj = utl.ubus("fwx", "common", req_obj)

	if resp_obj and resp_obj.code == 2000 and resp_obj.data then
		luci.http.write_json(resp_obj.data)
	else
		luci.http.write_json({
			user_session_enable = 0
		})
	end
end

function get_mac_blacklist()
	luci.http.prepare_content("application/json")

	local resp_obj = call_fwx_common("get_mac_blacklist", {})
	if resp_obj and resp_obj.code == 2000 and resp_obj.data then
		luci.http.write_json({code = 0, data = resp_obj.data, message = "success"})
	else
		luci.http.write_json({code = 1, data = {list = {}}, message = "failed"})
	end
end

function add_mac_blacklist()
	local json = require "luci.jsonc"
	luci.http.prepare_content("application/json")

	local mac_list = {}
	local mac = normalize_mac(luci.http.formvalue("mac"))
	if mac ~= "" then
		table.insert(mac_list, mac)
	else
		local data_str = luci.http.formvalue("data")
		if data_str and data_str ~= "" then
			local data = json.parse(data_str)
			if data and type(data.mac_list) == "table" then
				for _, item in ipairs(data.mac_list) do
					local normalized_mac = normalize_mac(item)
					if normalized_mac ~= "" then
						table.insert(mac_list, normalized_mac)
					end
				end
			end
		end
	end

	if #mac_list == 0 then
		luci.http.write_json({code = 1, message = "Invalid mac"})
		return
	end

	local resp_obj = call_fwx_common("add_mac_blacklist", {mac_list = mac_list})
	if resp_obj and resp_obj.code == 2000 then
		luci.http.write_json({code = 0, message = "success"})
	else
		luci.http.write_json({code = 1, message = "failed"})
	end
end

function del_mac_blacklist()
	luci.http.prepare_content("application/json")
	local mac = normalize_mac(luci.http.formvalue("mac"))
	if mac == "" then
		luci.http.write_json({code = 1, message = "Invalid mac"})
		return
	end

	local resp_obj = call_fwx_common("del_mac_blacklist", {mac = mac})
	if resp_obj and resp_obj.code == 2000 then
		luci.http.write_json({code = 0, message = "success"})
	else
		luci.http.write_json({code = 1, message = "failed"})
	end
end

function get_parental_control_detail()
	luci.http.prepare_content("application/json")
	local req_obj = {}
	req_obj.api = "get_parental_control_detail"
	req_obj.data = {
		mac = luci.http.formvalue("mac")
	}

	local resp_obj = utl.ubus("fwx", "common", req_obj)
	if resp_obj and resp_obj.code == 2000 and resp_obj.data then
		luci.http.write_json(resp_obj.data)
	else
		luci.http.write_json({
			pc_status = "unlimited",
			pc_status_key = "unlimited",
			af_whitelist = 0,
			mf_whitelist = 0,
			appfilter_rules = {},
			macfilter_rules = {}
		})
	end
end

function get_user_parental_control_rules()
	luci.http.prepare_content("application/json")

	local target_mac = normalize_mac(luci.http.formvalue("mac"))
	if target_mac == "" then
		luci.http.write_json({
			mac = "",
			af_whitelist = 0,
			mf_whitelist = 0,
			list = {}
		})
		return
	end

	local req_obj = {
		api = "get_user_parental_control_rules",
		data = {
			mac = target_mac
		}
	}
	local resp_obj = utl.ubus("fwx", "common", req_obj)

	if resp_obj and resp_obj.code == 2000 and type(resp_obj.data) == "table" then
		luci.http.write_json(resp_obj.data)
	else
		luci.http.write_json({
			mac = target_mac,
			af_whitelist = 0,
			mf_whitelist = 0,
			list = {}
		})
	end
end

function get_oaf_status()
	local json = require "luci.jsonc"
	luci.http.prepare_content("application/json")
	
	local req_obj = {}
	req_obj.api = "get_oaf_status"
	req_obj.data = {}
	
	local resp_obj = utl.ubus("fwx", "common", req_obj)
	
	if resp_obj and resp_obj.code == 2000 and resp_obj.data then
		luci.http.write_json(resp_obj.data)
	else
		luci.http.write_json(resp_obj or {})
	end
end


function set_nickname()
	local json = require "luci.jsonc"
	luci.http.prepare_content("application/json")
	
	local req_obj = {}
	req_obj.api = "set_nickname"
	req_obj.data = {
		mac = luci.http.formvalue("mac"),
		nickname = luci.http.formvalue("nickname")
	}
	
	local resp_obj = utl.ubus("fwx", "common", req_obj);
	
	if resp_obj and resp_obj.code == 2000 then
		luci.http.write_json(resp_obj.data or {})
	else
		luci.http.write_json(resp_obj or {})
	end
end


function get_dev_visit_time(mac)
	local json = require "luci.jsonc"
	luci.http.prepare_content("application/json")
	
	local req_obj = {}
	req_obj.api = "dev_visit_time"
	req_obj.data = {
		mac = mac
	}
	
	local visit_obj = utl.ubus("fwx", "common", req_obj)
	
	local visit_list = {}
	if visit_obj and visit_obj.code == 2000 and visit_obj.data and visit_obj.data.list then
		visit_list = visit_obj.data.list
	end
	luci.http.write_json(visit_list)
end

function get_app_class_visit_time(mac)
	local json = require "luci.jsonc"
	luci.http.prepare_content("application/json")
	
	local req_obj = {}
	req_obj.api = "app_class_visit_time"
	req_obj.data = {
		mac = mac
	}
	
	local visit_obj = utl.ubus("fwx", "common", req_obj)
	
	local class_array = {}
	if visit_obj and visit_obj.code == 2000 and visit_obj.data and visit_obj.data.class_list then
		class_array = visit_obj.data.class_list
	end
	luci.http.write_json(class_array)
end


function get_dev_visit_list(mac)
	local json = require "luci.jsonc"
	luci.http.prepare_content("application/json")
	
	local req_obj = {}
	req_obj.api = "dev_visit_list"
	req_obj.data = {
		mac = mac
	}
	
	local page = luci.http.formvalue("page")
	local page_size = luci.http.formvalue("page_size")
	if page then
		req_obj.data.page = tonumber(page) or 1
	end
	if page_size then
		req_obj.data.page_size = tonumber(page_size) or 15
	end
	
	local resp_obj = utl.ubus("fwx", "common", req_obj)
	
	if resp_obj and resp_obj.code == 2000 and resp_obj.data then
		luci.http.write_json(resp_obj.data)
	else
		luci.http.write_json(resp_obj or {})
	end
end

function get_user_daily_summary()
	local mac = luci.http.formvalue("mac")
	luci.http.prepare_content("application/json")
	if not mac or not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
		luci.http.status(400, "Bad Request")
		luci.http.write_json({code = 400})
		return
	end
	local result = require("luci.util").ubus("fwx", "common", {
		api = "get_user_daily_summary",
		data = {mac = mac, days = 30}
	})
	if not result or result.code ~= 2000 or not result.data then
		luci.http.status(503, "Service Unavailable")
		luci.http.write_json({code = 503})
		return
	end
	luci.http.write_json(result.data)
end

function get_hourly_stats(mac)
	local json = require "luci.jsonc"
	local utl = require "luci.util"
	
	luci.http.prepare_content("application/json")
	
	local req_obj = {}
	req_obj.api = "get_hourly_top_apps"
	req_obj.data = {
		mac = mac
	}
	
	local resp_obj = utl.ubus("fwx", "common", req_obj)
	
	if resp_obj and resp_obj.code == 2000 and resp_obj.data then
		luci.http.write_json(resp_obj.data)
	else
		luci.http.write_json({
			mac = mac,
			date = 0,
			is_today = 1,
			hourly_stats = {}
		})
	end
end

function get_user_basic_info(mac)
	local json = require "luci.jsonc"
	local utl = require "luci.util"
	
	luci.http.prepare_content("application/json")
	
	local req_obj = {}
	req_obj.api = "get_user_basic_info"
	req_obj.data = {
		mac = mac
	}
	
	local resp_obj = utl.ubus("fwx", "common", req_obj)
	
	if resp_obj and resp_obj.code == 2000 and resp_obj.data then
		luci.http.write_json(resp_obj.data)
	else
		luci.http.write_json({})
	end
end

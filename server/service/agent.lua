local skynet = require "skynet"
local queue = require "skynet.queue"
local sharemap = require "sharemap"
local socket = require "socket"

local syslog = require "syslog"
local protoloader = require "protoloader"
local character_handler = require "agent.character_handler"
local map_handler = require "agent.map_handler"
local aoi_handler = require "agent.aoi_handler"
local move_handler = require "agent.move_handler"
local combat_handler = require "agent.combat_handler"

-- 取到gamed的地址
local gamed = tonumber (...)
local database

local host, proto_request = protoloader.load (protoloader.GAME)

--[[
.user {
	fd : integer
	account : integer

	character : character
	world : integer
	map : integer
}
]]

local user

-- 直接向客户端fd发送消息
local function send_msg (fd, msg)
	local package = string.pack (">s2", msg)
	socket.write (fd, package)
end

local user_fd
local session = {}
local session_id = 0
-- 给本agent对应的客户端fd发消息
local function send_request (name, args)
	session_id = session_id + 1
	local str = proto_request (name, args, session_id)
	send_msg (user_fd, str)

	-- 当请求的响应回来时，需要找到对应的name和args来执行RESPONSE调用
	session[session_id] = { name = name, args = args }
end

local function kick_self ()
	skynet.call (gamed, "lua", "kick", skynet.self (), user_fd)
end

local last_heartbeat_time
local HEARTBEAT_TIME_MAX = 0 -- 60 * 100
local function heartbeat_check ()
	if HEARTBEAT_TIME_MAX <= 0 or not user_fd then return end

	local t = last_heartbeat_time + HEARTBEAT_TIME_MAX - skynet.now ()
	if t <= 0 then
		syslog.warning ("heatbeat check failed")
		kick_self ()
	else
		skynet.timeout (t, heartbeat_check)
	end
end

local traceback = debug.traceback
local REQUEST
-- 处理客户端来的请求消息
-- 这里的local REQUEST在后面的几个register里merge了很多方法进来
local function handle_request (name, args, response)
	--
	local f = REQUEST[name]
	if f then
		local ok, ret = xpcall (f, traceback, args)
		if not ok then
			syslog.warningf ("handle message(%s) failed : %s", name, ret) 
			kick_self ()
		else
			last_heartbeat_time = skynet.now ()
			if response and ret then
				send_msg (user_fd, response (ret))
			end
		end
	else
		syslog.warningf ("unhandled message : %s", name)
		kick_self ()
	end
end

local RESPONSE
-- 处理响应消息
-- 这里的local RESPONSE在后面的几个register里merge了很多方法进来
local function handle_response (id, args)
	local s = session[id]
	if not s then
		syslog.warningf ("session %d not found", id)
		kick_self ()
		return
	end

	local f = RESPONSE[s.name]
	if not f then
		syslog.warningf ("unhandled response : %s", s.name)
		kick_self ()
		return
	end

	local ok, ret = xpcall (f, traceback, s.args, args)
	if not ok then
		syslog.warningf ("handle response(%d-%s) failed : %s", id, s.name, ret) 
		kick_self ()
	end
end

-- 客户端消息的各种处理函数
skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
	unpack = function (msg, sz)
		return host:dispatch (msg, sz)
	end,
	dispatch = function (_, _, type, ...)
		if type == "REQUEST" then
			handle_request (...)
		elseif type == "RESPONSE" then
			handle_response (...)
		else
			syslog.warningf ("invalid message type : %s", type) 
			kick_self ()
		end
	end,
}

local CMD = {}

-- 新用户进来了
function CMD.open (fd, account)
	local name = string.format ("agent:%d", account)
	syslog.debug ("agent opened")

	user = { 
		fd = fd, 
		account = account,
		REQUEST = {},
		RESPONSE = {},
		CMD = CMD,
		send_request = send_request,
	}
	user_fd = user.fd
	REQUEST = user.REQUEST
	RESPONSE = user.RESPONSE
	
	character_handler:register (user)

	last_heartbeat_time = skynet.now ()
	heartbeat_check ()
end

-- 用户退出
function CMD.close ()
	syslog.debug ("agent closed")
	
	local account
	if user then
		account = user.account

		if user.map then
			skynet.call (user.map, "lua", "character_leave")
			user.map = nil
			map_handler:unregister (user)
			aoi_handler:unregister (user)
			move_handler:unregister (user)
			combat_handler:unregister (user)
		end

		if user.world then
			skynet.call (user.world, "lua", "character_leave", user.character.id)
			user.world = nil
		end

		character_handler.save (user.character)

		user = nil
		user_fd = nil
		REQUEST = nil
	end

	skynet.call (gamed, "lua", "close", skynet.self (), account)
end

-- 踢掉用户
function CMD.kick ()
	error ()
	syslog.debug ("agent kicked")
	skynet.call (gamed, "lua", "kick", skynet.self (), user_fd)
end

-- 被world调用
function CMD.world_enter (world)
	local name = string.format ("agent:%d:%s", user.character.id, user.character.general.name)

	character_handler.init (user.character)

	user.world = world

	-- @@用户进入具体的map后，character_handler不再处理用户的消息
	character_handler:unregister (user)

	return user.character.general.map, user.character.movement.pos
end

-- 被world调用，进入地图
function CMD.map_enter (map)
	user.map = map

	map_handler:register (user)
	aoi_handler:register (user)
	move_handler:register (user)
	combat_handler:register (user)
end

skynet.start (function ()
	skynet.dispatch ("lua", function (_, _, command, ...)
		local f = CMD[command]
		if not f then
			syslog.warningf ("unhandled message(%s)", command) 
			return skynet.ret ()
		end

		local ok, ret = xpcall (f, traceback, ...)
		if not ok then
			syslog.warningf ("handle message(%s) failed : %s", command, ret) 
			kick_self ()
			return skynet.ret ()
		end
		skynet.retpack (ret)
	end)
end)


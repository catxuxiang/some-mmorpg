local skynet = require "skynet"
local socket = require "socket"

local syslog = require "syslog"
local config = require "config.system"


local session_id = 1
local slave = {}
local nslave
local gameserver = {}

local CMD = {}

function CMD.open (conf)
	-- 创建多个loginslave service
	for i = 1, conf.slave do
		local s = skynet.newservice ("loginslave")
		skynet.call (s, "lua", "init", skynet.self (), i, conf)
		table.insert (slave, s)
	end
	nslave = #slave

	-- 网络监听
	local host = conf.host or "0.0.0.0"
	local port = assert (tonumber (conf.port))
	local sock = socket.listen (host, port)

	syslog.noticef ("listen on %s:%d", host, port)

	-- 这是accept的处理函数
	local balance = 1
	socket.start (sock, function (fd, addr)
		local s = slave[balance]
		balance = balance + 1
		if balance > nslave then balance = 1 end

		-- loginserver收到用户连接后，轮流的选择一个loginslave，然后把fd/addr发过去调用auth方法
		skynet.call (s, "lua", "auth", fd, addr)
	end)
end

function CMD.save_session (account, key, challenge)
	-- 这个session原来是全局变量，我改为local变量了
	local session = session_id
	session_id = session_id + 1

	-- 分配session，并且保存到slave的
	s = slave[(session % nslave) + 1]
	skynet.call (s, "lua", "save_session", session, account, key, challenge)
	return session
end

function CMD.challenge (session, challenge)
	-- 找到session所在的slave，把请求转发过去
	s = slave[(session % nslave) + 1]
	return skynet.call (s, "lua", "challenge", session, challenge)
end

function CMD.verify (session, token)
	-- 找到session所在的slave，把请求转发过去
	local s = slave[(session % nslave) + 1]
	return skynet.call (s, "lua", "verify", session, token)
end

skynet.start (function ()
	skynet.dispatch ("lua", function (_, _, command, ...)
		local f = assert (CMD[command])
		skynet.retpack (f (...))
	end)
end)

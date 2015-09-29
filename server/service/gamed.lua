local skynet = require "skynet"

local gameserver = require "gameserver.gameserver"
local syslog = require "syslog"

-- 这里的...表示require此文件时的参数
local logind = tonumber (...)

local gamed = {}

local pending_agent = {}
local pool = {}

local online_account = {}

-- 这个open改名为init更准确些
-- 启动agent/gdd/world服务
function gamed.open (config)
	syslog.notice ("gamed opened")

	local self = skynet.self ()
	local n = config.pool or 0
	-- 预先启动多个agent服务，放在agent池里，提高效率
	for i = 1, n do
		table.insert (pool, skynet.newservice ("agent", self))
	end

	-- 启动gdd和world服务
	skynet.uniqueservice ("gdd")
	skynet.uniqueservice ("world")
end

function gamed.command_handler (cmd, ...)
	local CMD = {}

	function CMD.close (agent, account)
		syslog.debugf ("agent %d recycled", agent)

		online_account[account] = nil
		table.insert (pool, agent)
	end

	function CMD.kick (agent, fd)
		gameserver.kick (fd)
	end

	local f = assert (CMD[cmd])
	return f (...)
end

function gamed.auth_handler (session, token)
	return skynet.call (logind, "lua", "verify", session, token)	
end

-- 登陆成功后给fd分配agent
function gamed.login_handler (fd, account)
	local agent = online_account[account]
	if agent then
		syslog.warningf ("multiple login detected for account %d", account)
		skynet.call (agent, "lua", "kick", account)
	end

	if #pool == 0 then
		-- 把gamed的地址做为参数传递给agent
		agent = skynet.newservice ("agent", skynet.self ())
		syslog.noticef ("pool is empty, new agent(%d) created", agent)
	else
		agent = table.remove (pool, 1)
		syslog.debugf ("agent(%d) assigned, %d remain in pool", agent, #pool)
	end
	online_account[account] = agent

	skynet.call (agent, "lua", "open", fd, account)
	gameserver.forward (fd, agent)
	return agent
end

gameserver.start (gamed)

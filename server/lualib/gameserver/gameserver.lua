local skynet = require "skynet"

local gateserver = require "gameserver.gateserver"
local syslog = require "syslog"
local protoloader = require "protoloader"


local gameserver = {}
local pending_msg = {}

-- forwark是让gateserver把fd里的消息，直接转发给agent去处理
-- 当fd经过验证并分配agent后，该fd的消息都要交给agent去做业务处理，所以这里就forward下
function gameserver.forward (fd, agent)
	gateserver.forward (fd, agent)
end

function gameserver.kick (fd)
	gateserver.close_client (fd)
end

function gameserver.start (gamed)
	-- handler会传递到gateserver中
	local handler = {}

	local host, send_request = protoloader.load (protoloader.LOGIN)

	-- 在gateserver启动后，调gamed的open
	function handler.open (source, conf)
		return gamed.open (conf)
	end

	--
	function handler.connect (fd, addr)
		syslog.noticef ("connect from %s (fd = %d)", addr, fd)
		gateserver.open_client (fd)
	end

	-- 连接断开时这里只是输出日志
	function handler.disconnect (fd)
		syslog.noticef ("fd (%d) disconnected", fd)
	end

	local function do_login (fd, msg, sz)
		local type, name, args, response = host:dispatch (msg, sz)
		assert (type == "REQUEST")
		assert (name == "login")
		assert (args.session and args.token)
		local session = tonumber (args.session) or error ()
		local account = gamed.auth_handler (session, args.token) or error ()
		assert (account)
		return account
	end

	local traceback = debug.traceback
	function handler.message (fd, msg, sz)
		-- 找到fd对应的pending msg（还未发给agent的消息）
		local queue = pending_msg[fd]
		if queue then
			table.insert (queue, { msg = msg, sz = sz })
		else
			pending_msg[fd] = {}

			-- do_login里面会调skynet.call到loginserver那边去验证，这时coroutine会挂起
			-- 如果这时该fd上再有消息来，会重入到这个函数，所以上面就会搞个peding_msg来缓存该fd的消息
			--    （实际上可以严格要求下，当登陆未结束时不允许客户端发起新的请求）
			-- 当do_login验证通过后，会为该连接分配agent，后续的消息处理会在gateserver里直接转到agent处理了
			local ok, account = xpcall (do_login, traceback, fd, msg, sz)
			if ok then
				syslog.noticef ("account %d login success", account)
				-- 登录成功，分配agent，后续的消息会被转到agent处理（参见gateserver的dispatch_msg())
				local agent = gamed.login_handler (fd, account)
				queue = pending_msg[fd]
				for _, t in pairs (queue) do
					syslog.noticef ("forward pending message to agent %d", agent)
					skynet.rawcall(agent, "client", t.msg, t.sz)
				end
			else
				syslog.warningf ("%s login failed : %s", addr, account)
				gateserver.close_client (fd)
			end

			-- 消息都转到agent那里去，然后pending_msg[fd]=nil
			pending_msg[fd] = nil
		end
	end

	local CMD = {}

	function CMD.token (id, secret)
		local id = tonumber (id)
		login_token[id] = secret
		skynet.timeout (10 * 100, function ()
			if login_token[id] == secret then
				syslog.noticef ("account %d token timeout", id)
				login_token[id] = nil
			end
		end)
	end

	function handler.command (cmd, ...)
		-- 拦截CMD.token消息，否则就调gamed.command_handler消息（close/kick）
		local f = CMD[cmd]
		if f then
			return f (...)
		else
			return gamed.command_handler (cmd, ...)
		end
	end

	return gateserver.start (handler)
end

return gameserver

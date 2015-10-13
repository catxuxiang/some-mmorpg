local skynet = require "skynet"
local netpack = require "netpack"
local socketdriver = require "socketdriver"

local syslog = require "syslog"


local gateserver = {}

local socket
local queue
local maxclient
local nclient = 0

-- @@这个用法还不太明白
local CMD = setmetatable ({}, { __gc = function () netpack.clear (queue) end })

-- 在下面的dispatch_msg中用到了PTYPE_CLIENT协议，必须先注册才能用
-- 又因为dispatch_msg里只是用了skynet.redirect来转发，转发时不需pack函数
skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
}

local connection = {}

function gateserver.open_client (fd)
	if connection[fd] then
		socketdriver.start (fd)
	end
end

function gateserver.close_client (fd)
	local c = connection[fd]
	if c then
		socketdriver.close (fd)
	end
end

-- 给连接fd分配agent后，调用forward函数让后续fd的socket消息直接转给agent去处理
function gateserver.forward (fd, agent)
	local c = connection[fd]
	if c then
		c.agent = agent
		syslog.debugf ("start forward fd(%d) to agent(%d)", fd, agent)
	end
end

function gateserver.start (handler)

	-- 打开gateserver的监听
	function CMD.open (source, conf)
		local addr = conf.address or "0.0.0.0"
		local port = assert (tonumber (conf.port))
		maxclient = conf.maxclient or 64

		syslog.noticef ("gateserver listen on %s:%d", addr, port)
		socket = socketdriver.listen (addr, port)
		socketdriver.start (socket)

		-- 让handler(gamed)接着执行open，其实就相当于在gamed前执行了gateserver的open操作
		if handler.open then
			return handler.open (source, conf)
		end
	end

	local MSG = {}

	function MSG.open (fd, addr)
		-- 超过最大连接数了
		if nclient >= maxclient then
			return socketdriver.close (fd)
		end

		local c = {
			fd = fd,
			addr = addr,
		}
		connection[fd] = c
		nclient = nclient + 1

		handler.connect (fd, addr)
	end

	local function close_fd (fd)
		local c = connection[fd]
		if c then
			-- 通知fd对应的连接的agent关闭掉，这说明这个设计里每个连接对应一个agent
			local agent = c.agent
			if agent then
				syslog.noticef ("fd(%d) disconnected, closing agent(%d)", fd, agent)
				skynet.call (agent, "lua", "close")
				c.agent = nil
			else
				-- 没有agent时调用handler
				if handler.disconnect then
					handler.disconnect (fd)
				end
			end

			connection[fd] = nil
			nclient = nclient - 1
		end
	end

	function MSG.close (fd)
		close_fd (fd)
	end

	function MSG.error (fd, msg)
		close_fd (fd)
	end

	local function dispatch_msg (fd, msg, sz)
		local c = connection[fd]
		local agent = c.agent
		if agent then
			-- 如果有agent了就直接转给agent去处理
			skynet.redirect (agent, 0, "client", 0, msg, sz)

			-- 如何在lua协议里转发，参考这个例子
			-- skynet.start(function()
			-- 	skynet.dispatch("lua", function(session, source, command, ...)
			-- 		local s = worker[math.random(1, #worker)]
			-- 		skynet.redirect(s, source, "lua", session, skynet.pack(command, ...))
			-- 	end)
			-- end)
		else
			-- 否则就给gameserver去处理
			handler.message (fd, msg, sz)
		end
	end

	MSG.data = dispatch_msg

	local function dispatch_queue ()
		local fd, msg, sz = netpack.pop (queue)
		if fd then
			skynet.fork (dispatch_queue)
			dispatch_msg (fd, msg, sz)

			-- 这个for语句的用法参见 http://cloudwu.github.io/lua53doc/manual.html#3.3.5 中的等价语句
			-- 可以理解为：
			-- while true do
			--	 local fd, msg, sz = netpack.pop(queue)
			-- 	 if fd == nil then break end
			--   block
			-- end
			for fd, msg, sz in netpack.pop, queue do
				dispatch_msg (fd, msg, sz)
			end
		end
	end

	MSG.more = dispatch_queue

	-- sock类型的消息是从客户端来的
	-- 这里采用了netpack.filter来解包，返回的结果有queue, type, fd, msg，见netpack源码
	-- type是netpack里定义的几种值
	--	data = 1，表示有1个数据包
	--	more = 2，表示有多于1个的数据包
	--	error =  3，表示出错了
	--	open =  4，表示新连接
	--	close =  5，表示连接断开
	--	warn = 6，表示缓冲区的数据超过1M了，告警下
	-- 所以在dispatch函数中里的MSG也有对应的open/close/data/more/error等函数
	skynet.register_protocol {
		name = "socket",
		id = skynet.PTYPE_SOCKET,
		unpack = function (msg, sz)
			-- netpack.filter的说明
			-- 参数：
			-- 		userdata queue
			--		lightuserdata msg
			--		integer size
			-- 返回值：
			--		userdata queue
			--		integer type
			--		integer fd
			--		string msg | lightuserdata/integer
			return netpack.filter (queue, msg, sz)
		end,
		-- 这个dispatch函数从第3个起的参数和上面的unpack返回的值是配对的，在skynet.lua的raw_dispatch_message函数能看到
		dispatch = function (_, _, q, type, ...)
			queue = q
			if type then
				return MSG[type] (...) 
			end
		end,
	}

	skynet.start (function ()
		-- lua类型的消息一般是内部调用
		-- 先从gateserver的CMD里查（open）
		-- 再从gameserver的CMD里查（token）
		-- 最后从gamed的CMD里查（close/kick）
		skynet.dispatch ("lua", function (_, address, cmd, ...)
			-- 先用CMD来拦截函数，仅仅是open方法
			local f = CMD[cmd]
			if f then
				skynet.retpack (f(address, ...))
			else
				skynet.retpack (handler.command (cmd, ...))
			end
		end)
	end)
end

return gateserver

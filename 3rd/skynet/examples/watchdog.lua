-- 这里的watchdog负责维护gate service和agent service
-- 这里的gate是service/gate.lua，是个官方提供的服务
-- watchdog对每个新连接会newservice一个agent来处理，更好的做法是预先newservice一批agent，参见some-mmorpg
--
-- 用户连接的过程是：
-- 1. gateserver.lua收到socket open消息，调用gate handler.connect
-- 2. gate handler.connect里skynet.send给watchdog一条socket open消息
-- 3. watchdog SOCKET.open里 newservice agent，并让agent start
-- 4. agent start时skynet.call gate forward，让gate后续把socket消息forward到agent
-- 5. 后续的socket消息还是先发到gate，然后gate转发到agent来处理

local skynet = require "skynet"
local netpack = require "netpack"

local CMD = {}
local SOCKET = {}
local gate
local agent = {}

function SOCKET.open(fd, addr)
	skynet.error("New client from : " .. addr)
	agent[fd] = skynet.newservice("agent")
	skynet.call(agent[fd], "lua", "start", { gate = gate, client = fd, watchdog = skynet.self() })
end

local function close_agent(fd)
	local a = agent[fd]
	agent[fd] = nil
	if a then
		skynet.call(gate, "lua", "kick", fd)
		-- disconnect never return
		skynet.send(a, "lua", "disconnect")
	end
end

function SOCKET.close(fd)
	print("socket close",fd)
	close_agent(fd)
end

function SOCKET.error(fd, msg)
	print("socket error",fd, msg)
	close_agent(fd)
end

function SOCKET.warning(fd, size)
	-- size K bytes havn't send out in fd
	print("socket warning", fd, size)
end

function SOCKET.data(fd, msg)
end

function CMD.start(conf)
	skynet.call(gate, "lua", "open" , conf)
end

function CMD.close(fd)
	close_agent(fd)
end

skynet.start(function()
	skynet.dispatch("lua", function(session, source, cmd, subcmd, ...)
		-- socket消息其实是从gate发来的
		if cmd == "socket" then
			local f = SOCKET[subcmd]
			f(...)
			-- socket api don't need return
		else
			local f = assert(CMD[cmd])
			skynet.ret(skynet.pack(f(subcmd, ...)))
		end
	end)

	-- gate在watchdog里维护
	gate = skynet.newservice("gate")
end)

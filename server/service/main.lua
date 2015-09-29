local skynet = require "skynet"

local config = require "config.system"
local login_config = require "config.loginserver"
local game_config = require "config.gameserver"

skynet.start(function()
	-- 明确skynet的一些概念能更快熟悉代码
	-- skynet节点：每个启动的skynet进程称为一个skynet节点，对应在OS看来是个多线程的程序
	-- skynet网络：多个skynet节点用cluster或habor模式运行时可以组成skynet网络
	-- skynet线程：每个skynet进程默认会启动timer/socket/monitor这3个线程+N个worker线程，N在启动配置文件里配置
	-- skynet服务：每个skynet服务（skynet.newservice/uniqueservice）都是一个独立的lua虚拟机，所以skynet服务相互是隔离的
	-- skynet服务与skynet worker线程之间的关系：简单的说是worker线程不停的从队列里取出有消息的skynet服务来运行，就好比CPU跑进程一样
	-- skynet服务与coroutine之间的关系：skynet服务是个lua虚拟机，coroutine在所属的skynet服务里运行。每个skynet服务同一时间只有一个coroutine在运行。
	skynet.newservice ("debug_console", config.debug_port)
	skynet.newservice ("protod")
	skynet.uniqueservice ("database")

	local loginserver = skynet.newservice ("loginserver")
	skynet.call (loginserver, "lua", "open", login_config)	

	local gamed = skynet.newservice ("gamed", loginserver)
	skynet.call (gamed, "lua", "open", game_config)
end)

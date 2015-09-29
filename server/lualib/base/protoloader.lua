-- 启动的时候把sproto协议文件解析并存起来，后续用时直接load
-- save是在protod这个service，load是在别的service，而service之间又是相互隔离的，如何能做好load出别的service save的协议？
-- 查看源码可以发现最终调用到C代码sproto.core来实现的，不是线程安全的，必须自行保证在初始化完毕后再做 load 操作
-- 见https://github.com/cloudwu/skynet/wiki/Sproto#sproto-loader

local sprotoloader = require "sprotoloader"

local loginp = require "proto.login_proto"
local gamep = require "proto.game_proto"

local loader = {
	GAME_TYPES = 0,

	LOGIN = 1,
	LOGIN_C2S = 1,
	LOGIN_S2C = 2,

	GAME = 3,
	GAME_C2S = 3,
	GAME_S2C = 4,
}

function loader.init ()
	sprotoloader.save (gamep.types, loader.GAME_TYPES)

	sprotoloader.save (loginp.c2s, loader.LOGIN_C2S)
	sprotoloader.save (loginp.s2c, loader.LOGIN_S2C)

	sprotoloader.save (gamep.c2s, loader.GAME_C2S)
	sprotoloader.save (gamep.s2c, loader.GAME_S2C)

	-- skynet examples/protoloader.lua的注释
	-- don't call skynet.exit() , because sproto.core may unload and the global slot become invalid
end

function loader.load (index)
	-- 先load package结构是因为RPC调用需要，见https://github.com/cloudwu/skynet/wiki/Sproto#rpc
	local host = sprotoloader.load (index):host "package"
	local request = host:attach (sprotoloader.load (index + 1))
	return host, request
end

return loader

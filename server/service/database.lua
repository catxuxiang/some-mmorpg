-- 数据库模块，参见作者的说明 https://github.com/jintiao/some-mmorpg/wiki/%E6%95%B0%E6%8D%AE%E5%BA%93

local skynet = require "skynet"
local redis = require "redis"

local config = require "config.database"
local account = require "db.account"
local character = require "db.character"

local center
local group = {}  -- 按作者的构想，redis会启动33个实例，可拆分的数据放在1~32号实例，不可拆分的放0号实例，这里的group就是1~32号实例
local ngroup

local function hash_str (str)
	local hash = 0
	string.gsub (str, "(%w)", function (c)
		hash = hash + string.byte (c)
	end)
	return hash
end

local function hash_num (num)
	local hash = num << 8
	return hash
end

function connection_handler (key)
	local hash
	local t = type (key)
	if t == "string" then
		hash = hash_str (key)
	else
		hash = hash_num (assert (tonumber (key)))
	end

	return group[hash % ngroup + 1]
end


local MODULE = {}
local function module_init (name, mod)
	MODULE[name] = mod
	mod.init (connection_handler)
end

local traceback = debug.traceback

skynet.start (function ()
	module_init ("account", account)
	module_init ("character", character)

	-- center没用到，估计是上面说的0号实例，存放全局数据
	center = redis.connect (config.center)
	ngroup = #config.group
	for _, c in ipairs (config.group) do
		table.insert (group, redis.connect (c))
	end

	skynet.dispatch ("lua", function (_, _, mod, cmd, ...)
		-- 这里对于异常情况直接调用skynet.ret()，调用方如何知道错误信息？
		local m = MODULE[mod]
		if not m then
			return skynet.ret ()
		end
		local f = m[cmd]
		if not f then
			return skynet.ret ()
		end

		local function ret (ok, ...)
			if not ok then
				skynet.ret ()
			else
				skynet.retpack (...)
			end

		end
		-- 这个ret函数的用法挺巧妙的, f的返回值数量未知
		ret (xpcall (f, traceback, ...))
	end)
end)

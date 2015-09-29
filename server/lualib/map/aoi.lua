-- aoi(Area Of Interest)，在网游中表示该节点的关注列表，当该节点发生变化时（移动、掉血）会通知关注列表中的其他节点
-- 一般是把该节点半径raduis内（矩形）的节点加入到关注列表，常用到四叉树来计算

local quadtree = require "map.quadtree"

local aoi = {}

local object = {}
local qtree
local radius

function aoi.init (bbox, r)
	qtree = quadtree.new (bbox.left, bbox.top, bbox.right, bbox.bottom)
	radius = r
end

function aoi.insert (id, pos)
	if object[id] then return end

	-- 把id/pos插入到四叉树中
	local tree = qtree:insert (id, pos.x, pos.z)
	if not tree then return end

	-- 查询id/pos周围有哪些节点
	local result = {}
	qtree:query (id, pos.x - radius, pos.z - radius, pos.x + radius, pos.z + radius, result)

	-- 这里的list表示当前id的关注列表
	-- 即当前id发生变化时，需要通知list中的id
	local list = {}
	for i = 1, #result do
		local cid = result[i]
		local c = object[cid]
		if c then
			-- 相互加到对方的list中
			list[cid] = cid
			c.list[id] = id
		end
	end

	object[id] = { id = id, pos = pos, qtree = tree, list = list }
	
	return true, list
end

function aoi.remove (id)
	local c = object[id]
	if not c then return end

	if c.qtree then
		c.qtree:remove (id)
	else
		qtree:remove (id)
	end

	for _, v in pairs (c.list) do
		local t = object[v]
		if t then
			t.list[id] = nil
		end
	end
	object[id] = nil

	return true, c.list
end

-- update返回有3个list
-- olist：旧的关注列表
-- nlist：移动位置后的关注列表中新增的那些id
-- ulist：移动位置后仍然在关注列表中得那些id
-- 如果之前的关注列表是[1,2,3]，update后的关注列表是[2,3,4]，那么
-- olist=[1], nlist=[4], ulist=[2,3]
function aoi.update (id, pos)
	local c = object[id]
	if not c then return end

	-- 先从四叉树删除
	if c.qtree then
		c.qtree:remove (id)
	else
		qtree:remove (id)
	end

	local olist = c.list  -- 旧的关注列表

	local tree = qtree:insert (id, pos.x, pos.z)
	if not tree then return end

	c.pos = pos

	local result = {}
	qtree:query (id, pos.x - radius, pos.z - radius, pos.x + radius, pos.z + radius, result)

	local nlist = {}   -- 新增的
	for i = 1, #result do
		local cid = result[i]
		nlist[cid] = cid
	end

	-- 在新list中也在旧list的，就是ulist
	local ulist = {}
	for _, a in pairs (nlist) do
		local k = olist[a]
		if k then
			ulist[a] = a
			olist[a] = nil
		end
	end

	for _, a in pairs (ulist) do
		nlist[a] = nil
	end

	c.list = {}
	for _, v in pairs (nlist) do
		c.list[v] = v
	end
	for _, v in pairs (ulist) do
		c.list[v] = v
	end

	return true, nlist, ulist, olist
end

return aoi

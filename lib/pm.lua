-- ��Դ���� power manage
local base = _G
local pmd = require"pmd"
local pairs = base.pairs
module("pm")

local tags = {}
local flag = true

function isleep()
	return flag
end

function wake(tag)
	id = tag or "default"

	tags[id] = 1

	if flag == true then
		flag = false
		pmd.sleep(0)
	end
end

function sleep(tag)
	id = tag or "default"

	tags[id] = 0

	if tags[id] < 0 then
		base.print("pm.sleep:error",tag)
		tags[id] = 0
	end

	-- ֻҪ�����κ�һ��ģ�黽��,��˯��
	for k,v in pairs(tags) do
		if v > 0 then
			return
		end
	end

	flag = true
	pmd.sleep(1)
end

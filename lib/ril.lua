
-- ����ģ��,����������
local base = _G
local table = require"table"
local string = require"string"
local uart = require"uart"
local rtos = require"rtos"
local sys = require"sys"
module("ril")

--���س��õ�ȫ�ֺ���������
local setmetatable = base.setmetatable
local print = base.print
local type = base.type
local smatch = string.match
local sfind = string.find
local vwrite = uart.write
local vread = uart.read

-- ����
local TIMEOUT = 60000 --1�����޷��� �ж�at����ִ��ʧ��
-- cmd type: 0:no reuslt 1:number 2:sline 3:mline 4:string 10:spec
local NORESULT = 0
local NUMBERIC = 1
local SLINE = 2
local MLINE = 3
local STRING = 4
local SPECIAL = 10
local RILCMD = {
	["+CSQ"] = 2,
	["+CGSN"] = 1,
	["+WISN"] = 4,
	["+CIMI"] = 1,
	["+CCID"] = 1,
	["+CGATT"] = 2,
	["+CCLK"] = 2,
	["+ATWMFT"] = 4,
	["+CMGR"] = 3,
	["+CMGS"] = 2,
	["+CPBF"] = 3,
	["+CPBR"] = 3,
 	["+CIPSEND"] = 10,
	["+CIPCLOSE"] = 10,
	["+CIFSR"] = 10,
}

-- local var
local radioready,delaying = false

-- �������
local cmdqueue = {
	"ATE0",
	"AT+CMEE=0",
}
-- ��ǰ����ִ�е�����,����,�����ص�,�ӳ�ִ��,����ͷ,����,������ʽ
local currcmd,currarg,currsp,curdelay,cmdhead,cmdtype,rspformt
-- �������,�м���Ϣ,�����Ϣ
local result,interdata,respdata

-- ril������������: ����ظ�\�����ϱ�\���ʱ
-- ��ʱ
local function atimeout()
	sys.restart("ril.atimeout_"..(currcmd or "")) -- ������Ӧ��ʱ�Զ�����ϵͳ
end

-- ����ظ�
local function defrsp(cmd,success,response,intermediate)
	print("default response:",cmd,success,response,intermediate)
end

local rsptable = {}
setmetatable(rsptable,{__index = function() return defrsp end})
local formtab = {}
function regrsp(head,fnc,typ,formt)
	if typ == nil then
		rsptable[head] = fnc
		return true
	end
	if typ == 0 or typ == 1 or typ == 2 or typ == 3 or typ == 4 or typ == 10 then
		if RILCMD[head] and RILCMD[head] ~= typ then
			return false
		end
		RILCMD[head] = typ
		rsptable[head] = fnc
		formtab[head] = formt
		return true
	else
		return false
	end
end

local function rsp()
	sys.timer_stop(atimeout)

	if currsp then
		currsp(currcmd,result,respdata,interdata)
	else
		rsptable[cmdhead](currcmd,result,respdata,interdata)
	end

	currcmd,currarg,currsp,curdelay,cmdhead,cmdtype,rspformt = nil
	result,interdata,respdata = nil
end

-- �����ϱ���ʾ
local function defurc(data)
	print("defurc:",data)
end

local urctable = {}
setmetatable(urctable,{__index = function() return defurc end})
function regurc(prefix,handler)
	urctable[prefix] = handler
end

function deregurc(prefix)
	urctable[prefix] = nil
end

local urcfilter

local function urc(data)
	if data == "RDY" then
		radioready = true
	else
		local prefix = smatch(data,"(%+*[%u%d ]+)")

		urcfilter = urctable[prefix](data,prefix)
	end
end

local function procatc(data)
	print("atc:",data)

	if interdata and cmdtype == MLINE then -- �������ն��з���ֱ������OKΪֹ
		-- ���з���������������յ��м�����˵��ִ�гɹ���,�ж�֮������ݽ�������OK
		if data ~= "OK\r\n" then
			if sfind(data,"\r\n",-2) then -- ȥ�����Ļ��з�
				data = string.sub(data,1,-3)
			end
			interdata = interdata .. "\r\n" .. data
			return
		end
	end

	if urcfilter then
		data,urcfilter = urcfilter(data)
	end

	if sfind(data,"\r\n",-2) then -- ����������ֽ���\r\n��ɾ��
		data = string.sub(data,1,-3)
	end

	if data == "" then
		return
	end

	if currcmd == nil then -- ��ǰ��������ִ�����ж�Ϊurc
		urc(data)
		return
	end

	local isurc = false

	if sfind(data,"^%+CMS ERROR:") or sfind(data,"^%+CME ERROR:") or (data == "CONNECT FAIL" and currcmd and smatch(currcmd,"CIPSTART")) then
		data = "ERROR"
	end

	if data == "OK" or data == "SHUT OK" then
		result = true
		respdata = data
	elseif data == "ERROR" or data == "NO ANSWER" or data == "NO DIALTONE" then
		result = false
		respdata = data
	elseif data == "> " then
		if cmdhead == "+CMGS" then -- ������ʾ�����Ͷ��Ż�������
			print("send:",currarg)
			vwrite(uart.ATC,currarg,"\026")
		elseif cmdhead == "+CIPSEND" then
			print("send:",currarg)
			vwrite(uart.ATC,currarg)
		else
			print("error promot cmd:",currcmd)
		end
	else
		--���������������ж��յ���������urc���߷�������
		if cmdtype == NORESULT then -- �޽������ ��ʱ�յ�������ֻ��URC
			isurc = true
		elseif cmdtype == NUMBERIC then -- ȫ����
			local numstr = smatch(data,"(%x+)")
			if numstr == data then
				interdata = data
			else
				isurc = true
			end
		elseif cmdtype == STRING then -- �ַ���
			if smatch(data,rspformt or "^%w+$") then
				interdata = data
			else
				isurc = true
			end
		elseif cmdtype == SLINE or cmdtype == MLINE then
			if interdata == nil and sfind(data, cmdhead) == 1 then
				interdata = data
			else
				isurc = true
			end
		elseif cmdhead == "+CIFSR" then
			local s = smatch(data,"%d+%.%d+%.%d+%.%d+")
			if s ~= nil then
				interdata = s
				result = true
			else
				isurc = true
			end
		elseif cmdhead == "+CIPSEND" or cmdhead == "+CIPCLOSE" then
			local keystr = cmdhead == "+CIPSEND" and "SEND" or "CLOSE"
			local lid,res = smatch(data,"(%d), *([%u%d :]+)")

			if lid and res then
				if (sfind(res,keystr) == 1 or sfind(res,"TCP ERROR") == 1 or sfind(res,"UDP ERROR") == 1 or sfind(data,"DATA ACCEPT")) and (lid == smatch(currcmd,"=(%d)")) then
					result = true
					respdata = data
				else
					isurc = true
				end
			elseif data == "+PDP: DEACT" then
				result = true
				respdata = data
			else
				isurc = true
			end
		else
			isurc = true
		end
	end

	if isurc then
		urc(data)
	elseif result ~= nil then
		rsp()
	end
end

local readat = false

local function getcmd(item)
	local cmd,arg,rsp,delay

	if type(item) == "string" then
		cmd = item
	elseif type(item) == "table" then
		cmd = item.cmd
		arg = item.arg
		rsp = item.rsp
		delay = item.delay
	else
		print("getpack unknown item")
		return
	end

	head = smatch(cmd,"AT([%+%*]*%u+)")

	if head == nil then
		print("request error cmd:",cmd)
		return
	end

	if head == "+CMGS" or head == "+CIPSEND" then -- �����в���
		if arg == nil or arg == "" then
			print("request error no arg",head)
			return
		end
	end

	currcmd = cmd
	currarg = arg
	currsp = rsp
	curdelay = delay
	cmdhead = head
	cmdtype = RILCMD[head] or NORESULT
	rspformt = formtab[head]

	return currcmd
end

local function sendat()
	if not radioready or readat or currcmd ~= nil or delaying then
		-- δ��ʼ��/���ڶ�ȡatc���ݡ���������ִ�С����������� ֱ���˳�
		return
	end

	local item

	while true do
		if #cmdqueue == 0 then
			return
		end

		item = table.remove(cmdqueue,1)

		getcmd(item)

		if curdelay then
			sys.timer_start(delayfunc,curdelay)
			currcmd,currarg,currsp,curdelay,cmdhead,cmdtype,rspformt = nil
			item.delay = nil
			delaying = true
			table.insert(cmdqueue,1,item)
			return
		end

		if currcmd ~= nil then
			break
		end
	end

	sys.timer_start(atimeout,TIMEOUT)

	print("sendat:",currcmd)

	vwrite(uart.ATC,currcmd .. "\r")
end

function delayfunc()
	delaying = nil
	sendat()
end

local function atcreader()
	local s

	readat = true
	while true do
		s = vread(uart.ATC,"*l",0)

		if string.len(s) ~= 0 then
			procatc(s)
		else
			break
		end
	end
	readat = false
	sendat() -- atc�ϱ����ݴ������Ժ��ִ�з���AT����
end

sys.regmsg("atc",atcreader)

function request(cmd,arg,onrsp,delay)
	--���뻺�����
	if arg or onrsp or delay or formt then
		table.insert(cmdqueue,{cmd = cmd,arg = arg,rsp = onrsp,delay = delay})
	else
		table.insert(cmdqueue,cmd)
	end

	sendat()
end

if not RequiredScript then return end

-- Initialize

if not _G.TeamSpeak then

	-- TeamSpeak

	_G.TeamSpeak = { Version = "1.0.4 beta", Path = "TeamSpeak/lib/" }

	TeamSpeak.Channels = { GLOBAL = "3", CHANNEL = "2", PRIVATE = "1" }

	-- Parse Options

	dofile("TeamSpeak/Options.lua")

	if TeamSpeak.Options.ChatHistory == true then
		TeamSpeak.Options.ChatHistory = 20
	else
		TeamSpeak.Options.ChatHistory = tonumber(TeamSpeak.Options.ChatHistory)
		if TeamSpeak.Options.ChatHistory == nil or TeamSpeak.Options.ChatHistory < 1 then
			TeamSpeak.Options.ChatHistory = 0
		end
	end

	-- Internals

	function TeamSpeak.ShowMessage(sender, message, color, icon)
		managers.chat:_receive_message(ChatManager.GAME, sender, message, color, icon)
	end

	function TeamSpeak.OnReceive(body)
		local command = body:match("^([^ ]+)");
		io.write("[TS] " .. command .. "\n")
		if command == "notifytextmessage" then
			local channel = TeamSpeak.param("targetmode", body)
			local sender = TeamSpeak.param("invokername", body)
			local message = TeamSpeak.param("msg", body)
			TeamSpeak.Hooks:Call("TeamSpeakOnReceiveMessage", channel, sender, message)
		end
	end

	-- Hooks

	TeamSpeak.Hooks = {}

	function TeamSpeak.Hooks:Add(key, func)
		self[key] = self[key] or {}
		table.insert(self[key], func)
		return #self[key]
	end

	function TeamSpeak.Hooks:Remove(key, id)
		table.remove(key, id)
	end

	function TeamSpeak.Hooks:Call(key, ...)
		local args, vals = {...}
		for _, func in pairs(self[key] or {}) do
			vals = {func(unpack(args))}
			if vals[1] == false then return nil end
			if #vals ~= 0 then args = vals end
		end
		return args
	end

	-- Logic

	TeamSpeak.Hooks:Add("ChatManagerOnLoad", function()
		TeamSpeak.Hooks:Add("ChatManagerOnReceiveMessage", function(channel, name, message, color, icon)
			if channel == ChatManager.GAME then
				TeamSpeak.SaveChatMessage(name, message, color, icon)
			end
		end)
	end)

	TeamSpeak.Hooks:Add("ChatManagerOnSendMessage", function(channel, sender, message)
		local command = message:match("^/([^ ]+)")
		if command == nil then return end
		message = message:sub(command:len() + 3)
		if command == "msg" or command == "ts" then
			TeamSpeak.Send("sendtextmessage targetmode=2 msg=" .. TeamSpeak.escape(message))
			return false
		elseif command == "mute" then
			io.write("[TS][WIP] Muted " .. message .. "\n")
			return false
		end
	end)

	TeamSpeak.Hooks:Add("TeamSpeakOnReceiveMessage", function(channel, sender, message)
		local color = TeamSpeak.Options.Colors.Channel
		if channel == TeamSpeak.Channels.GLOBAL then color = TeamSpeak.Options.Colors.Global end
		TeamSpeak.ShowMessage(sender, message, color)
	end)

	if TeamSpeak.Options.FixChatLag then
		local last_messages = {}
		TeamSpeak.Hooks:Add("ChatManagerOnReceiveMessage", function(channel, sender, message, color, icon)
			if last_messages[sender] and last_messages[sender].message == message then
				local time = os.clock()
				local interval = time - last_messages[sender].time
				last_messages[sender].time = time
				if interval < 10 then return false end
			else
				last_messages[sender] = { message = message, time = os.clock() }
			end
		end)
	end

	-- Helpers

	function TeamSpeak.param(name, body)
		return TeamSpeak.unescape(body:match(name .. "=([^ ]+)"))
	end

	local escape_pairs = { ["\n"] = "\\n", ["\r"] = "\\r", [" "] = "\\s", ["\\"] = "\\\\", ["/"] = "\\/" }
	local unescape_pairs = { n = "\n", r ="\r", t = " ", s = " " , ["\\"] = "\\", ["/"] = "/" }

	function TeamSpeak.escape(value)
		return value:gsub("(.)", escape_pairs)
	end

	function TeamSpeak.unescape(value)
		return value:gsub("\\(.)", unescape_pairs)
	end

end

-- Override scripts

do

	local requiredScripts = {
		["lib/managers/chatmanager"] = "ChatManager.lua"
	}

	if requiredScripts[RequiredScript] ~= nil then
		if type(requiredScripts[RequiredScript]) == "string" then
			dofile(TeamSpeak.Path .. requiredScripts[RequiredScript])
			return
		end
		for _, script in pairs(requiredScripts[RequiredScript]) do
			dofile(TeamSpeak.Path .. script)
		end
	end

end

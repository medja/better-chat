if not RequiredScript then return end

-- Initialize

if not _G.TeamSpeak then

	-- [[ TeamSpeak ]] --

	_G.TeamSpeak = { Version = "1.0.4 beta", Path = "TeamSpeak/lib/" }

	TeamSpeak.Channels = { GLOBAL = "3", CHANNEL = "2", PRIVATE = "1" }

	-- [[ Parse Options ]] --

	dofile("TeamSpeak/Options.lua")

	-- Makes sure ChatHistory is a number
	-- Defaults to 20 when true is specified and 0 for any non-number

	if TeamSpeak.Options.ChatHistory == true then
		TeamSpeak.Options.ChatHistory = 20
	else
		TeamSpeak.Options.ChatHistory = tonumber(TeamSpeak.Options.ChatHistory)
		if TeamSpeak.Options.ChatHistory == nil or TeamSpeak.Options.ChatHistory < 1 then
			TeamSpeak.Options.ChatHistory = 0
		end
	end

	-- [[ Internals ]] --

	-- Displays (and saves) a message in the in-game chat

	function TeamSpeak.ShowMessage(sender, message, color, icon)
		managers.chat:_receive_message(ChatManager.GAME, sender, message, color, icon)
	end

	-- Handles TeamSpeak events sent from the application
	-- Calls hooks for each implemented event

	function TeamSpeak.OnReceive(body)
		local command = body:match("^(%S+)");
		io.write("[TS] " .. command .. "\n")
		if command == "notifytextmessage" then
			local channel = TeamSpeak.param("targetmode", body)
			local sender = TeamSpeak.param("invokername", body)
			local message = TeamSpeak.param("msg", body)
			TeamSpeak.Hooks:Call("TeamSpeakOnReceiveMessage", channel, sender, message)
		end
	end

	-- [[ Hooks ]] --

	TeamSpeak.Hooks = {}

	-- Registers a hook for a specific key

	function TeamSpeak.Hooks:Add(key, func)
		self[key] = self[key] or {}
		table.insert(self[key], func)
		return #self[key]
	end

	-- Removes a specific hook for a key

	function TeamSpeak.Hooks:Remove(key, id)
		table.remove(key, id)
	end

	-- Calls each hook for a key

	function TeamSpeak.Hooks:Call(key, ...)
		-- Stores the passed arguments and uses them when calling hooks
		local args, vals = {...}
		for _, func in ipairs(self[key] or {}) do
			vals = {func(unpack(args))}
			-- Returning false will prevent additional hooks from being called
			if vals[1] == false then return nil end
			-- Returning a new set of arguments will replace the current ones
			if #vals ~= 0 then args = vals end
		end
		-- Returns the possibly new set of arguments
		return args
	end

	-- [[ Logic ]] --

	-- Once the chat manager and GUI have loaded and chat becomes usable
	TeamSpeak.Hooks:Add("ChatManagerOnLoad", function()
		-- Save any recived chat message using a C++ function
		TeamSpeak.Hooks:Add("ChatManagerOnReceiveMessage", function(channel, name, message, color, icon)
			if channel == ChatManager.GAME then
				TeamSpeak.SaveChatMessage(name, message, color, icon)
			end
		end)
	end)

	-- Every time a message is about to be sent from the client
	TeamSpeak.Hooks:Add("ChatManagerOnSendMessage", function(channel, sender, message)
		-- Checks for a command inside the message
		local command = message:match("^/(%S+)")
		if command == nil then return end
		-- Removes the command from the message
		message = message:sub(command:len() + 3)
		if command == "msg" or command == "ts" then
			-- Handles: /msg <message> | /ts <message>
			-- Sends a message via the current TeamSpeak channel
			TeamSpeak.Send("sendtextmessage targetmode=2 msg=" .. TeamSpeak.escape(message))
			return false
		elseif command == "mute" then
			-- Handles: /mute <username>
			io.write("[TS][WIP] Muted " .. message .. "\n")
			return false
		end
	end)

	-- Handles messages received from TeamSpeak
	TeamSpeak.Hooks:Add("TeamSpeakOnReceiveMessage", function(channel, sender, message)
		local color = TeamSpeak.Options.Colors.Channel
		if channel == TeamSpeak.Channels.GLOBAL then color = TeamSpeak.Options.Colors.Global end
		TeamSpeak.ShowMessage(sender, message, color)
	end)

	-- Discards duplicate messages if the chat lag fix is enabled
	if TeamSpeak.Options.FixChatLag then
		-- Stores a list of the last messages from users in the lobby or game
		local last_messages = {}
		TeamSpeak.Hooks:Add("ChatManagerOnReceiveMessage", function(channel, sender, message, color, icon)
			-- If this player has already sent a message with the same content
			if last_messages[sender] and last_messages[sender].message == message then
				-- Calculate the time between them
				local time = os.clock()
				local interval = time - last_messages[sender].time
				last_messages[sender].time = time
				-- And discard the message if its less then 10 seconds
				if interval < 10 then return false end
			else
				last_messages[sender] = { message = message, time = os.clock() }
			end
		end)
	end

	-- Autocomplete matches and current index
	local autocomplete_index = 0
	local autocomplete_matches = nil

	-- Handles keypresses inside the chat
	TeamSpeak.Hooks:Add("ChatManagerKeyPress", function(key, chat)
		-- Fire autocompletion if tab is pressed
		if key == Idstring("tab") then
			-- Gets the input field, selection start and text
			local panel = chat._input_panel:child("input_text")
			local i, text = panel:selection(), panel:text()
			-- Either autocomplete the input or switch between previous results
			if autocomplete_matches == nil then
				-- Get the part of the word right of the cursor
				local offset = text:sub(i + 1):match("^%S*")
				-- Join the text before the cursor and word after it together
				local input = (text:sub(0, i) .. offset):lower()
				-- Store all player names inside a table
				local players = {}
				for _, player in ipairs(managers.network:game():all_members()) do
					table.insert(players, player:peer():name())
				end
				-- Match player names with the input
				local matches = {}
				while input:len() > 0 do
					for _, player in ipairs(players) do
						-- If the player name contains the input add it to the list
						local match = player:lower():find(input, 0, true)
						if match ~= nil then
							table.insert(matches, { match, player })
						end
					end
					if #matches > 0 then break end
					-- If no match was found shorten the input by removing the front word
					input = input:sub((input:find("%s") or input:len()) + 1)
				end
				if #matches > 0 then
					-- If a match is found sort the matches and save them for later
					table.sort(matches, function(a, b)
						-- Use the match index inside the player name for sorting
						return a[1] < b[1]
					end)
					autocomplete_matches = matches
					-- Set the match index to the best / first one
					autocomplete_index = 1
					local best = matches[1][2]
					-- Get the different string lengths used to split up the original text
					local input_length = input:len()
					local after_length = offset:len()
					local before_length = input_length - after_length
					local best_length = best:len()
					-- Check if any character after the cursor matches the ending of the player name
					local after = text:sub(i + after_length + 1):lower()
					local match = best:sub(input_length + 1):lower()
					for i = 0, math.min(after:len(), match:len()) do
						if after:sub(i, i) ~= match:sub(i, i) then break end
						-- And make sure they get trimmed off
						after_length = after_length + 1
					end
					-- Replace the matched text with the player name
					panel:set_text(text:sub(0, i - before_length) .. best .. text:sub(i + after_length))
					-- And set the cursor's position respectively
					local selection = i - before_length + best_length
					panel:set_selection(selection, selection)
					chat:update_caret()
				end
			else
				-- Get the current player name length
				local length = autocomplete_matches[autocomplete_index][2]:len()
				-- Find the next match index looping back to 1 if needed
				if autocomplete_index == #autocomplete_matches then
					autocomplete_index = 1
				else
					autocomplete_index = autocomplete_index + 1
				end
				-- Replace the previous match with the new one
				local match = autocomplete_matches[autocomplete_index][2]
				panel:set_text(text:sub(0, i - length) .. match .. text:sub(i + 1))
				-- And set the cursor's position respectively
				local selection = i - length + match:len()
				panel:set_selection(selection, selection)
				chat:update_caret()
			end
		else
			autocomplete_matches = nil
		end
	end)

	-- [[ Helpers ]] --

	-- Finds a parameter inside the string and unescapes it
	function TeamSpeak.param(name, body)
		return TeamSpeak.unescape(body:match(name .. "=(%S+)"))
	end

	-- Character pairs used for escaping and unescaping TeamSpeak ClienQuery strings
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

	-- Script pairs used for overriding classes
	local requiredScripts = {
		["lib/managers/chatmanager"] = "ChatManager.lua"
	}

	-- If the required script has to be overriden
	if requiredScripts[RequiredScript] ~= nil then
		-- Load that one script
		if type(requiredScripts[RequiredScript]) == "string" then
			dofile(TeamSpeak.Path .. requiredScripts[RequiredScript])
			return
		end
		-- Or multiple of them if a table is used instead of a script name
		for _, script in ipairs(requiredScripts[RequiredScript]) do
			dofile(TeamSpeak.Path .. script)
		end
	end

end

if not RequiredScript then return end

-- Initialize

if not _G.BC then

	-- [[ BetterChat ]] --

	_G.BC = { version = "1.0.6 beta", path = "BetterChat/lib/" }

	-- TeamSpeak channels
	BC.channels = { global = "3", channel = "2", private = "1" }

	-- TeamSpeak clients
	BC.clients = {}
	BC.local_client = {}

	-- Queue of private message receivers
	BC.receivers = {}
	-- Last private channel client / used for replies
	BC.last_sender = nil

	-- In-game / in-lobby state
	BC.in_game = false
	-- Current game state name
	BC.game_state = nil

	-- Chat input message and position
	BC.input = nil

	-- [[ Parse Options ]] --

	-- Load the options
	BC.Options = {}
	dofile("BetterChat/Options.lua")
	BC.Options:init()

	-- Make sure chat_history is a number
	-- Default to 20 when true is and 0 for any non-number
	if BC.Options.chat_history == true then
		BC.Options.chat_history = 20
	else
		BC.Options.chat_history = tonumber(BC.Options.chat_history)
		if BC.Options.chat_history == nil or BC.Options.chat_history < 1 then
			BC.Options.chat_history = 0
		end
	end

	-- [[ Internals ]] --

	-- Logs the current value with a [TS] prefix
	-- Works like string.format and can handle tables
	function BC.log(...)
		local args = {...}
		for key, value in ipairs(args) do
			args[key] = BC.to_string(value)
		end
		io.write("[TS] " .. string.format(unpack(args)) .. "\n")
	end

	-- Transforms a value into a string
	function BC.to_string(object)
		if type(object) ~= "table" then
			return tostring(object)
		end
		-- Convert tables manually
		local result = ""
		for key, value in pairs(object) do
			local value_type = type(value)
			if value_type == "string" then
				value = "\"" .. value .. "\""
			else
				value = BC.to_string(value)
			end
			result = result .. ", " .. tostring(key) .. " = " .. value
		end
		-- Remove the leading comma
		return "{ " .. result:sub(3) .. " }"
	end

	-- Displays a message in the in-game chat
	function BC.show_message(sender, message, color, icon, formatter)
		managers.chat:_receive_message(ChatManager.GAME, sender, message, color, icon)
		if formatter ~= nil then
			-- Call the formatter for each chat gui that received the message
			for _, chat in ipairs(managers.chat._receivers[ChatManager.GAME]) do
				formatter(chat)
			end
		end
	end

	-- Fetches the client list from TeamSpeak
	function BC.fetch_info()
		-- Check the local clients id and channel
		BC.send_command("whoami")
		BC.Queue:push(function(client)
			BC.local_client.id = client[1].clid
			BC.local_client.channel = client[1].cid
		end)
		-- Get a list of all the clients
		BC.send_command("clientlist")
		BC.Queue:push(function(clients)
			BC.clients = {}
			for _, client in ipairs(clients) do
				BC.clients[client.clid] = {
					name    = client.client_nickname,
					channel = client.cid }
			end
		end)
	end

	-- [[ Formatters ]] --

	-- Formatters used for last second editing of messages in chat guis
	BC.Formatters = {
		-- Private message formatter
		private = function(chat)
			local line = BC.Formatters.get_last_line(chat)
			local text = line:text()
			line:set_range_color(text:find(" "), text:find(":") - 1, Color("FFFFFF"))
		end
	}

	-- Returns the last line / message from the chat
	function BC.Formatters.get_last_line(chat)
		return chat._lines[#chat._lines][1]
	end

	-- [[ Hooks ]] --

	-- Main hook / event system used by this mod
	BC.Hooks = {}

	-- Registers a hook for a specific action
	function BC.Hooks:add(action, func)
		self[action] = self[action] or {}
		table.insert(self[action], func)
	end

	-- Calls each hook for an action
	function BC.Hooks:call(key, ...)
		-- Store the passed arguments and uses them when calling hooks
		local args, vals = {...}
		for _, func in ipairs(self[key] or {}) do
			vals = {func(unpack(args))}
			-- Stop the loop if false was returned
			if vals[1] == false then return nil end
			-- Replace the arguments if a new set was returned
			if #vals ~= 0 then args = vals end
		end
		-- Return the last set of arguments
		return args
	end

	-- [[ Queue ]] --

	-- Queue of callbacks used for handling TeamSpeak responses
	BC.Queue = {}

	-- Enqueues a new callback to the queue
	function BC.Queue:push(func)
		table.insert(self, func)
	end

	-- Dequeues the last callback and calls it
	function BC.Queue:call(...)
		-- Make sure we actually have an element in the queue
		if #self > 0 then
			table.remove(self, 1)(...)
		end
	end

	-- [[ Logic ]] --

	-- Handles incoming TeamSpeak events and responses
	BC.Hooks:add("TeamSpeak:Receive", function(body)
		-- Parse the packet
		local command, params = BC.parse(body)
		if command == nil then
			-- Call the first queued callback if the packet is a response
			BC.Queue:call(params)
			return
		elseif command == "error" then
			-- Disregard any error events
			return
		end
		-- Event packets may only contain one set of parameters
		params = params[1]
		-- Call hooks for implemented events
		if command == "notifytextmessage" then
			local channel = params.targetmode
			local sender = params.invokerid
			local message = params.msg
			BC.Hooks:call("TeamSpeak:ReceiveMessage", channel, sender, message)
		elseif command == "notifycliententerview" then
			-- If a new client connects add it to the client list
			BC.clients[params.clid] = { name = params.client_nickname, channel = params.ctid }
			BC.Hooks:call("TeamSpeak:ClientMove", params.clid, params.ctid)
		elseif command == "notifyclientleftview" then
			BC.Hooks:call("TeamSpeak:ClientMove", params.clid, nil)
			-- If a client disconnects remove it from the client list
			BC.clients[params.clid] = nil
		elseif command == "notifyclientmoved" then
			if params.clid == BC.local_client.id then
				-- If the local client moves, only save the new channel id
				BC.local_client.channel = params.ctid
				BC.clients[BC.local_client.id].channel = params.ctid
			else
				-- Call the hook for everyone else
				BC.Hooks:call("TeamSpeak:ClientMove", params.clid, params.ctid)
			end
		end
	end)

	-- Handles incoming TeamSpeak messages
	BC.Hooks:add("TeamSpeak:ReceiveMessage", function(channel, sender, message)
		-- Get the sender's name
		local name = BC.clients[sender].name
		-- Default to the channel color
		local color = BC.Options.colors.channel
		-- Don't use a formatter
		local formatter = nil
		if channel == BC.channels.global then
			-- If this is a server message change its color
			color = BC.Options.colors.global
		elseif channel == BC.channels.private then
			-- If this is a private message change its color and use a formatter
			color = BC.Options.colors.private
			formatter = BC.Formatters.private
			-- Prefix the sender's name accordingly
			if sender == BC.local_client.id then
				-- If thias message is sent by the local
				-- client use the receivers name instead
				name = "To " .. BC.clients[table.remove(BC.receivers, 1)].name
			else
				name = "From " .. name
				-- Use the sender's id for replies
				BC.last_sender = sender
			end
		end
		-- Show the message in chat
		BC.show_message(name, message, color, nil, formatter)
	end)

	-- Displays messages whenever a client joins / leaves the local client's channel
	BC.Hooks:add("TeamSpeak:ClientMove", function(id, channel)
		-- Only handle remote clients
		if id == BC.local_client.id then return end
		-- Get the moving client's info
		local client = BC.clients[id]
		-- If the client is joining the local client's channel
		if channel ~= nil and channel == BC.local_client.channel then
			-- Write entered instead of joined if the client just connected
			local action = channel == client.channel and "entered" or "joined"
			local message = string.format("%s %s your channel", client.name, action)
			BC.show_message("Server", message, BC.Options.colors.info)
		-- If the client is leaving the local client's channel
		elseif client.channel == BC.local_client.channel then
			-- Write disconnected instead of left if the client left the server
			local action = channel == nil and "disconnected from" or "left"
			local message = string.format("%s %s your channel", client.name, action)
			BC.show_message("Server", message, BC.Options.colors.info)
		end
		-- Save the client's new channel
		client.channel = channel
	end)

	-- Stores any in-game messages that pass through the chat manager
	BC.Hooks:add("ChatManager:ReceiveMessage", function(channel, name, message, color, icon)
		if channel == ChatManager.GAME then
			BC.save_chat_message(name, message, color, icon)
		end
	end)

	-- Checks messages about to be send for BetterChat commands
	BC.Hooks:add("ChatManager:SendMessage", function(channel, sender, message)
		-- Check for a command inside the message
		local command = message:match("^/(%S+)")
		if command == nil or command == "" then return end
		command = command:lower()
		-- Remove the command from the message
		message = message:sub(command:len() + 3)

		if command == "help" then
			-- Handles: /help
			-- Displays a list of all commands
			BC.show_message("Commands",
				"/global, /help, /list, /msg, /reply, /whisper",
				BC.Options.colors.info)
			return false
		elseif command == "whisper" or command == "w" then
			-- Handles: /whisper <client> <message> | /w <client> <message>
			-- Sends a private TeamSpeak message

			-- Display command usage if only the command is passed
			if message == "" then
				BC.show_message("Usage",
					"/whisper <client> <message>",
					BC.Options.colors.info)
				return false
			end

			-- Get the client name from the message
			local target = message:match("^%S+")
			message = message:sub(target:len() + 2)

			-- Get this client's id
			local id
			for key, client in pairs(BC.clients) do
				if client.name == target then
					id = key break
				end
			end
			if id == nil then
				-- Make sure the client exists
				BC.show_message("Server",
					target .. " is not online",
					BC.Options.colors.info)
			elseif id == BC.local_client.id then
				-- The client isn't the local
				BC.show_message("Server",
					"You cannot send a message to yourself",
					BC.Options.colors.info)
			else
				-- Use this id for replies
				BC.last_sender = id
				-- Send the private message command
				BC.send_command(BC.packet("sendtextmessage", {
					targetmode = BC.channels.private,
					target = id,
					msg = message
				}))
				table.insert(BC.receivers, id)
			end
			-- Discard this message
			return false
		elseif command == "reply" or command == "r" then
			-- Handles: /reply <message> | /r <message>
			-- Sends a reply to the last private message

			-- Display command usage if only the command is passed
			if message == "" then
				BC.show_message("Usage",
					"/reply <message>",
					BC.Options.colors.info)
				return false
			end

			-- Check if any private messages have even been received
			if BC.last_sender == nil then
				BC.show_message("Server",
					"You have no private messages to reply to",
					BC.Options.colors.info)
			else
				-- Send the private message command
				BC.send_command(BC.packet("sendtextmessage", {
					targetmode = BC.channels.private,
					target = BC.last_sender,
					msg = message
				}))
				table.insert(BC.receivers, BC.last_sender)
			end
			-- Discard this message
			return false
		elseif command == "msg" or command == "ts" then
			-- Handles: /msg <message> | /ts <message>
			-- Sends a message via the current TeamSpeak channel

			-- Display command usage if only the command is passed
			if message == "" then
				BC.show_message("Usage",
					"/msg <message>",
					BC.Options.colors.info)
				return false
			end

			-- Send the channel message command
			BC.send_command(BC.packet("sendtextmessage", {
				targetmode = BC.channels.channel,
				msg = message
			}))
			return false
		elseif command == "global" or command == "g" then
			-- Handles: /global <message> | /g <message>
			-- Sends a message to the entire server

			-- Display command usage if only the command is passed
			if message == "" then
				BC.show_message("Usage",
					"/global <message>",
					BC.Options.colors.info)
				return false
			end

			-- Send the server message command
			BC.send_command(BC.packet("sendtextmessage", {
				targetmode = BC.channels.global,
				msg = message
			}))
			-- Discard this message
			return false
		elseif command == "list" then
			-- Handles: /list [channel|server]
			-- Displays a list of clients in the channel or server

			-- Use channel as the default parameter
			if message == "" then message = "channel" end
			message = message:lower()
			if string.find("channel", message, 0, true) == 1 then
				-- Find all clients in the channel
				local clients = {}
				for _, client in pairs(BC.clients) do
					if client.channel == BC.local_client.channel then
						table.insert(clients, client.name)
					end
				end
				-- Sort and display them
				table.sort(clients)
				BC.show_message("Channel",
					table.concat(clients, ", "),
					BC.Options.colors.info)
			elseif string.find("server", message, 0, true) == 1 then
				-- Find all clients on the server
				local clients = {}
				for _, client in pairs(BC.clients) do
					table.insert(clients, client.name)
				end
				-- Sort and display them
				table.sort(clients)
				BC.show_message("Server",
					table.concat(clients, ", "),
					BC.Options.colors.info)
			else
				-- Display command usage if an invalid parameter is passed
				BC.show_message("Usage",
					"/list [channel|server]",
					BC.Options.colors.info)
				return false
			end
			-- Discard this message
			return false
		elseif command == "mute" then
			-- Handles: /mute <username>
			BC.log("mute: %s", message)
			BC.show_message("Info",
				"This command has not been implemented",
				BC.Options.colors.info)
			return false
		end
	end)

	-- Handles game state changes
	BC.Hooks:add("GameState:Change", function(state)
		-- Save the game state
		BC.game_state = state
		-- Check if the player is in-game
		local in_game = state:find("game") ~= nil
			and state ~= "ingame_lobby_menu"
			and state ~= "ingame_waiting_for_players"
		-- If this has changed trigger an event
		if BC.in_game ~= in_game then
			BC.in_game = in_game
			BC.Hooks:call(in_game and "GameState:EnterGame" or "GameState:LeaveGame")
		end
	end)

	-- Discards duplicate messages if the chat lag fix is enabled
	if BC.Options.fix_chat_lag then
		-- A map of the last message from each player in the lobby
		local last_messages = {}
		BC.Hooks:add("ChatManager:ReceivePeerMessage", function(channel, peer, message)
			-- Make sure we only work with game chat messages
			if channel ~= ChatManager.GAME then return end
			-- Get the player's id
			local sender = peer:id()
			-- If this player has already sent a message with the same content
			if last_messages[sender] and last_messages[sender].message == message then
				-- Calculate the time that has elapsed since he sent it
				local time = os.clock()
				local interval = time - last_messages[sender].time
				last_messages[sender].time = time
				-- And discard the message if its less then 8 seconds
				if interval < 8 then return false end
			else
				last_messages[sender] = { message = message, time = os.clock() }
			end
		end)
	end

	-- Autocompletes player and TeamSpeak client names in chat
	if BC.Options.autocomplete then
		-- Autocomplete matches and current match index
		local autocomplete_index = 0
		local autocomplete_matches = nil

		-- Handles keypresses inside the chat input
		BC.Hooks:add("ChatGUI:KeyPress", function(key, chat)
			-- Autocomplete the player / client name if tab is pressed
			if key == Idstring("tab") then
				-- Gets the chat input panel, selection start and text
				local panel = chat._input_panel:child("input_text")
				local i, text = panel:selection(), panel:text()

				-- Either autocomplete the input or switch between previous results
				if autocomplete_matches == nil then
					-- Get the part of the word right of the cursor
					local offset = text:sub(i + 1):match("^%S*")
					-- Join the text before the cursor and word after it together
					local input = (text:sub(0, i) .. offset):lower()

					-- Store all player names inside a table
					local names = {}
					for _, player in ipairs(managers.network:game():all_members()) do
						table.insert(names, player:peer():name())
					end
					for _, client in pairs(BC.clients) do
						table.insert(names, client.name)
					end

					-- Match the names with the input
					local matches, hashes = {}, {}
					while input:len() > 0 do
						for _, name in ipairs(names) do
							-- If the name contains the input add it to the list
							local match = name:lower():find(input, 0, true)
							if match ~= nil and hashes[name] == nil then
								table.insert(matches, { match, name })
								hashes[name] = true
							end
						end
						if #matches > 0 then break end
						-- If no match was found shorten the input by removing the first word
						input = input:sub((input:find("%s") or input:len()) + 1)
					end

					-- Make sure we have at least one match
					if #matches == 0 then return end
					
					-- Sort the matches using the match index
					table.sort(matches, function(a, b)
						return a[1] < b[1]
					end)
					-- Store the matches for later
					autocomplete_matches = matches

					-- Set the match index to the best / first one
					autocomplete_index = 1
					local best = matches[1][2]

					-- Get the different string lengths used to split up the original text
					local input_length = input:len()
					local after_length = offset:len()
					local before_length = input_length - after_length
					local best_length = best:len()

					-- Check if any character after the cursor matches the ending of the name
					local after = text:sub(i + after_length + 1):lower()
					local match = best:sub(input_length + 1):lower()
					for i = 0, math.min(after:len(), match:len()) do
						if after:sub(i, i) ~= match:sub(i, i) then break end
						-- And make sure they get trimmed off
						after_length = after_length + 1
					end

					-- Replace the matched text with the match
					panel:set_text(text:sub(0, i - before_length) .. best .. text:sub(i + after_length))
					-- And set the cursor's position respectively
					local selection = i - before_length + best_length
					panel:set_selection(selection, selection)
					chat:update_caret()

				else
					-- Get the current player name length
					local length = autocomplete_matches[autocomplete_index][2]:len()
					-- Find the next match index, looping back to 1 if needed
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
				-- Discard all other autocomplete matches if any key besides tab is pressed
				autocomplete_matches = nil
			end
		end)
	end

	-- Loads and restores the chat input text and selection between states
	if BC.Options.restore_chat_input then
		-- Loads the previous chat input text and cursor position
		BC.Hooks:add("ChatGUI:Show", function(chat)
			if BC.input == nil then return end
			local panel = chat._input_panel:child("input_text")
			panel:set_text(BC.input.text)
			panel:set_selection(BC.input.position, BC.input.position)
		end)

		-- Clears the chat input on enter
		BC.Hooks:add("ChatGUI:KeyPress", function(key, chat)
			if key == Idstring("enter") then
				BC.input = { text = "", position = 0 }
			end
		end)

		-- Saves the current chat input text and cursor position
		BC.Hooks:add("ChatGUI:KeyRelease", function(key, chat)
			if key == Idstring("enter") then return end
			local panel = chat._input_panel:child("input_text")
			BC.input = { text = panel:text(), position = panel:selection() }
		end)
	end

	-- [[ Helpers ]] --

	-- Parses a TeamSpeak packet
	function BC.parse(packet)
		-- Extract the command
		local command = packet:match("^(%S+)")
		-- If the packet didn't contain a command set it to nil
		if command:find("=") ~= nil then command = nil end
		-- Extract a list of parameters from the packet
		local list, parameters = {}
		for body in packet:gmatch("[^|]+") do
			parameters = {}
			for key, value in body:gmatch("(%S+)=(%S+)") do
				parameters[key] = BC.unescape(value)
			end
			table.insert(list, parameters)
		end
		return command, list
	end

	-- Packages a command and parameters into a TeamSpeak command
	function BC.packet(command, parameters)
		local body = command
		if parameters ~= nil then
			for key, value in pairs(parameters) do
				body = body .. " " .. key .. "=" .. BC.escape(value)
			end
		end
		return body
	end

	-- Character pairs used for escaping and unescaping TeamSpeak ClienQuery strings
	local escape_pairs = { ["\n"] = "\\n", ["\r"] = "\\r", [" "] = "\\s", ["\\"] = "\\\\", ["/"] = "\\/" }
	local unescape_pairs = { ["\\n"] = "\n", ["\\r"] ="\r", ["\\t"] = " ", ["\\s"] = " " , ["\\\\"] = "\\", ["\\/"] = "/" }

	-- Escapes a TeamSpeak string
	function BC.escape(value)
		return tostring(value):gsub(".", escape_pairs)
	end

	-- Unescapes a string for TeamSpeak
	function BC.unescape(value)
		return value:gsub("\\.", unescape_pairs)
	end

end

-- Override scripts

do

	-- Script pairs used for overriding classes
	local requiredScripts = {
		["lib/managers/chatmanager"] = "ChatManager.lua",
		["lib/managers/hud/hudchat"] = "HUDChat.lua",
		["lib/utils/game_state_machine/gamestatemachine"] = "GameStateMachine.lua"
	}

	-- If the required script has to be overriden
	if requiredScripts[RequiredScript] ~= nil then
		-- Load that one script
		if type(requiredScripts[RequiredScript]) == "string" then
			dofile(BC.path .. requiredScripts[RequiredScript])
			return
		end
		-- Or multiple of them if a table is used instead of a script name
		for _, script in ipairs(requiredScripts[RequiredScript]) do
			dofile(BC.path .. script)
		end
	end

end

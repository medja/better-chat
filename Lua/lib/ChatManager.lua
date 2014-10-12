-- Add a hook for chat gui initialization
local init = ChatGui.init
function ChatGui:init(ws)
	init(self, ws)
	TS.Hooks:call("ChatGUI:Load", self)
end

-- Add a hook for chat gui key presses
local key_press = ChatGui.key_press
function ChatGui:key_press(o, k)
	-- Prevents the escape key from clearing the input
	if TS.Options.clear_input_on_escape_key or k ~= Idstring("esc") then
		key_press(self, o, k)
	else
		local panel = self._input_panel:child("input_text")
		local text = panel:text()
		local potision = panel:selection()
		key_press(self, o, k)
		panel:set_text(text)
		panel:set_selection(potision, potision)
	end

	if self._key_pressed ~= nil then
		TS.Hooks:call("ChatGUI:KeyPress", self._key_pressed, self)
	end
end

-- Add a hook for handing messages about to be sent
local send_message = ChatManager.send_message
function ChatManager:send_message(channel, sender, message)
	local args = TS.Hooks:call("ChatManager:SendMessage", channel, sender, message)
	if args ~= nil then return send_message(self, unpack(args)) end
end

-- Add a hook for handing received messages
local _receive_message = ChatManager._receive_message;
function ChatManager:_receive_message(channel, name, message, color, icon)
	local args = TS.Hooks:call("ChatManager:ReceiveMessage", channel, name, message, color, icon)
	if args ~= nil then return _receive_message(self, unpack(args)) end
end

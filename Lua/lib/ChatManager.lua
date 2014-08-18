local send_message = ChatManager.send_message
function ChatManager:send_message(channel, sender, message)
	local args = TeamSpeak.Hooks:Call("ChatManagerOnSendMessage", channel, sender, message)
	if args ~= nil then send_message(self, unpack(args)) end
end

local _receive_message = ChatManager._receive_message;
function ChatManager:_receive_message(channel, name, message, color, icon)
	local args = TeamSpeak.Hooks:Call("ChatManagerOnReceiveMessage", channel, name, message, color, icon)
	if args ~= nil then _receive_message(self, unpack(args)) end
end
local init = HUDChat.init
function HUDChat:init(ws, hud)
	init(self, ws, hud)
	TeamSpeak.Hooks:Call("ChatManagerOnLoad")
end

local key_press = HUDChat.key_press
function HUDChat:key_press(o, k)
	if TeamSpeak.GameState:find("game") == nil or
		TeamSpeak.GameState == "ingame_lobby_menu" or
		TeamSpeak.GameState == "ingame_waiting_for_players" then return end
	key_press(self, o, k)
	if self._key_pressed ~= nil then
		TeamSpeak.Hooks:Call("ChatManagerKeyPress", self._key_pressed, self)
	end
end
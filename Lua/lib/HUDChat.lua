-- Add a hook for HUD chat initialization
local init = HUDChat.init
function HUDChat:init(ws, hud)
	init(self, ws, hud)
	TS.Hooks:call("ChatGUI:Load", self)
end

-- Add a hook for HUD chat key presses
local key_press = HUDChat.key_press
function HUDChat:key_press(o, k)
	-- Disable the chat outside the game
	if TS.game_state:find("game") == nil or
		TS.game_state == "ingame_lobby_menu" or
		TS.game_state == "ingame_waiting_for_players" then return end
	key_press(self, o, k)
	if self._key_pressed ~= nil then
		TS.Hooks:call("ChatGUI:KeyPress", self._key_pressed, self)
	end
end

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
	if not TS.in_game then return end

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

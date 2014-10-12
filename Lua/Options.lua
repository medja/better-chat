function TS.Options:init()
	-- Colors used for TeamSpeak messages
	self.colors = {
		info    = Color("FFD400"),
		global  = Color("33CCFF"),
		channel = Color("FFFFFF"),
		private = Color("828282")}

	-- Enables autocomplete in chat
	self.autocomplete = true
	-- Removes duplicate messages caused by lag
	self.fix_chat_lag = true
	-- Maximum lenght of chat history
	self.chat_history = 20
	-- Clears the chat input when esceape is pressed
	self.clear_input_on_escape_key = false
	-- Keeps chat input between screens
	self.restore_chat_input = true
end

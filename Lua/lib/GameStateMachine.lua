local _do_state_change = GameStateMachine._do_state_change
function GameStateMachine:_do_state_change()
	_do_state_change(self)
	TeamSpeak.Hooks:Call("GameStateChange", self:current_state_name())
end
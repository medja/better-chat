-- Add a hook for game state changes
local _do_state_change = GameStateMachine._do_state_change
function GameStateMachine:_do_state_change()
	_do_state_change(self)
	BC.Hooks:call("GameState:Change", self:current_state_name())
end

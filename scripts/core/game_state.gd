# game_state.gd — autoload `Game`: FORGEFALL run state, scoring, killstreaks, Forge budget.
# Purpose: the single authoritative store for per-run state (wave, kills, streak,
# score, forge budget, killstreak unlocks) plus the game-wide signals every
# subsystem listens to (HUD, waves, Forge console, killstreaks).
# Connections: autoloaded FIRST (before Sfx, Forge). Referenced by name (`Game`)
# from wave_manager, HUD, killstreak and Forge code. Reads balance values from
# Tuning (scripts/core/tuning.gd). No scene-tree dependencies; safe at boot.
extends Node

signal wave_started(n: int)
signal wave_cleared(n: int)
signal build_phase_started(seconds: int)
signal enemy_killed(points: int, headshot: bool, victim_name: String)
signal player_died()
signal killstreak_ready(index: int)
signal killstreak_used(index: int)
signal forge_budget_changed(amount: int)

var wave: int = 0
var kills: int = 0
var streak: int = 0
var score: int = 0
var forge_budget: int = Tuning.FORGE_START_BUDGET
var killstreaks_unlocked: Array[bool] = [false, false, false]
## Duplicated from Tuning so a run can (in future) mutate thresholds safely.
var killstreak_thresholds: Array = Tuning.KILLSTREAK_THRESHOLDS.duplicate()


func _ready() -> void:
	# Autoload init: nothing to load yet; state starts clean for the menu.
	reset_run()


## Called by enemies on death. Scores the kill, grows the streak, unlocks
## killstreaks at the 3/5/7 thresholds (MW2 style: once earned, a killstreak is
## kept through death until it is used).
func register_kill(headshot: bool, victim_name: String) -> void:
	kills += 1
	streak += 1
	var points: int = Tuning.SCORE_HEADSHOT_KILL if headshot else Tuning.SCORE_KILL
	score += points
	enemy_killed.emit(points, headshot, victim_name)
	for i in range(killstreak_thresholds.size()):
		if not killstreaks_unlocked[i] and streak >= int(killstreak_thresholds[i]):
			killstreaks_unlocked[i] = true
			killstreak_ready.emit(i)


## Called when the player dies. MW2 rules: the streak resets, earned killstreaks
## stay available until used.
func register_player_death() -> void:
	streak = 0
	player_died.emit()


## Generic score add (objectives, bonuses). For kills use register_kill().
func add_score(n: int) -> void:
	score += n


## Spend Forge build-budget. Returns true and emits on success; false = not
## enough budget, nothing changes.
func spend_budget(n: int) -> bool:
	if n < 0:
		return false
	if forge_budget < n:
		return false
	forge_budget -= n
	forge_budget_changed.emit(forge_budget)
	return true


## Grant Forge build-budget (wave-clear trickle, pickups, debug).
func grant_budget(n: int) -> void:
	if n <= 0:
		return
	forge_budget += n
	forge_budget_changed.emit(forge_budget)


## Mark a killstreak as used (fired). Emits killstreak_used; the slot can be
## re-earned by reaching the threshold again.
func use_killstreak(index: int) -> bool:
	if index < 0 or index >= killstreaks_unlocked.size():
		return false
	if not killstreaks_unlocked[index]:
		return false
	killstreaks_unlocked[index] = false
	killstreak_used.emit(index)
	return true


## Called by the wave manager: opens a wave and notifies listeners.
func start_wave(n: int) -> void:
	wave = n
	wave_started.emit(n)


## Called by the wave manager: closes a wave, pays the Forge trickle budget.
func clear_wave(n: int) -> void:
	wave_cleared.emit(n)
	grant_budget(Tuning.FORGE_BUDGET_PER_WAVE)


## Called between waves: opens the Forge build window for `seconds` seconds.
func start_build_phase(seconds: int) -> void:
	build_phase_started.emit(seconds)


## Full run reset (new game from the menu / after game over).
func reset_run() -> void:
	wave = 0
	kills = 0
	streak = 0
	score = 0
	forge_budget = Tuning.FORGE_START_BUDGET
	killstreaks_unlocked = [false, false, false]
	forge_budget_changed.emit(forge_budget)

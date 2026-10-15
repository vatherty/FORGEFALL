# audio_manager.gd — FORGEFALL Sfx autoload (Worker 7: audio)
#
# Central sound board. Other subsystems call:
#   Sfx.play_2d(id, vol_db, pitch)          — non-positional (UI, player feedback, music stingers)
#   Sfx.play_3d(id, pos, vol_db, pitch)     — positional (world sounds: shots, explosions, footsteps)
#   Sfx.play_music(id, vol_db) / Sfx.stop_music()
#   Sfx.play_footstep(surface, pos)         — "concrete" | "dirt" | "metal"
#   Sfx.set_volumes(master_db, sfx_db, music_db, ui_db)
#   Sfx.set_muted(m) / Sfx.toggle_mute()
#
# All WAVs are synthesized by tools/gen_audio.py (stdlib only, no assets).
# Unknown ids warn once and never crash.
extends Node

#region TUNABLES
const POOL_2D_SIZE := 12          # round-robin non-positional voices
const POOL_3D_SIZE := 16          # round-robin positional voices
const PITCH_JITTER := 0.05        # +/- random pitch per play (keeps repeats from stacking)
const MUSIC_FADE_SEC := 1.5       # music crossfade duration
const MUSIC_VOLUME_DB := -8.0     # default music level (drone sits under the mix)
const MAX_VOL_DB := 6.0           # clamp ceiling for set_volumes
const SFX_3D_UNIT_SIZE := 12.0    # 3D attenuation: distance at which falloff is "1 unit"
const SFX_3D_MAX_DISTANCE := 90.0 # 3D voices cut past this range (saves mixing CPU)
const AMBIENT_WIND_DB := -8.0     # wind bed: audible, always under the gunshots
const AMBIENT_POLL_SEC := 0.25    # how often to check gameplay start/stop for wind

# C3 mix table: per-id dB offsets applied in play_2d/play_3d/start_loop_2d.
# All gunshot WAVs are peak-normalized (~0.95) at the source, so the raw
# files are already close — the offsets only tame the loudest/longest ones
# (sniper tail, shotgun 4-crack stack, sustained LMG fire) and seat the
# quiet layers (footsteps, loops, UI) underneath. Every offset is <= 0 and
# _mix() clamps the result to <= 0 dB, so no sound can ever exceed the
# gunshot reference level or clip from stacking. Aliases resolve to their
# target id before lookup, so e.g. "shot_ar7" gets the "shot_ar" offset.
const MIX_DB: Dictionary = {
	# Gunshots: AR is the 0 dB reference; everything else sits at or under it.
	"shot_sniper": -2.0, "shot_shotgun": -2.0, "shot_lmg": -2.0,
	"shot_turret": -1.0, "shot_smg": -1.0, "shot_pistol": -1.0,
	"shot_raptor": -1.0,
	# Goal 3 CONTENT: burst sits at the AR reference; the big revolver
	# report is tamed like the sniper/shotgun.
	"shot_burst": -1.0, "shot_revolver": -2.0,
	# Loud one-shots.
	"explosion_big": -3.0, "explosion_barrel": -3.0,
	"explosion_airstrike": -2.0, "explosion_small": -4.0,
	"damage_thud": -1.0, "grenade_beep": -2.0,
	"wave_horn": -2.0, "juggernaut_horn": -2.0,
	# Impacts: clearly under gunfire (they fire on every bullet hit).
	"impact_concrete": -6.0, "impact_metal": -6.0,
	"impact_dirt": -6.0, "impact_flesh": -6.0,
	"cover_break": -2.0,
	# Player feedback: footsteps audible but clearly under gunfire.
	"footstep_concrete": -4.0, "footstep_dirt": -4.0, "footstep_metal": -4.0,
	"footstep_brute": -2.0, "jump_land": -2.0,
	# Goal 2 integration: Worker B's new movement/enemy one-shots.
	"slide_whoosh": -3.0, "wallrun_scrape": -3.0,
	"enemy_death": -2.0, "spawn_telegraph": -3.0,
	# Action / world.
	"grapple_fire": -1.0, "grapple_zip": -4.0,
	"portal_open": -2.0, "portal_teleport": -2.0, "portal_hum_loop": -6.0,
	"heartbeat_loop": -6.0,
	# Forge + UI feedback: distinct, never louder than gunshots.
	"forge_success": -2.0, "forge_fail": -2.0,
	"killstreak_ready": -3.0, "uav_online": -3.0, "pickup": -3.0,
	"weapon_raise": -3.0, "reload_ar": -3.0,
	"reload_sniper": -3.0, "reload_shotgun": -3.0, "reload_lmg": -3.0,
	"dryfire": -3.0,
	"hitmarker": -3.0, "headshot_ding": -3.0, "kill_confirm": -3.0,
	"ui_click": -4.0, "ui_hover": -5.0, "ui_confirm": -3.0,
}

# Goal 2 (SOUND): per-category voice caps. The mix table caps dB, but
# stacked one-shots (sustained LMG fire + turret + impacts) can still
# sum past the ceiling — so each category also caps SIMULTANEOUS voices.
# A refused play is a dropped sound, never a crash; caps sit above any
# sane in-game concurrency (LMG 600 rpm x 0.48 s shot = ~5 voices).
const CATEGORY_CAPS: Dictionary = {
	"gunshot": 6, "explosion": 2, "impact": 4, "reload": 2, "other": 99,
}
#endregion

#region CONSTANTS
const BUS_SFX := &"SFX"
const BUS_MUSIC := &"Music"
const BUS_UI := &"UI"

# Every WAV produced by tools/gen_audio.py. Explicit list = robust on export.
const SOUND_IDS: Array[String] = [
	"shot_ar", "shot_sniper", "shot_shotgun", "shot_smg", "shot_pistol",
	"shot_lmg", "shot_turret", "shot_raptor",
	# Goal 3 CONTENT: new-weapon shots.
	"shot_burst", "shot_revolver",
	"reload_ar", "reload_sniper", "reload_shotgun", "reload_lmg",
	# Goal 3 CONTENT: new-weapon reloads.
	"reload_burst", "reload_revolver",
	"dryfire", "weapon_raise",
	"hitmarker", "headshot_ding", "kill_confirm",
	"explosion_big", "explosion_small", "explosion_barrel",
	"explosion_airstrike", "grenade_beep",
	"impact_concrete", "impact_metal", "impact_dirt", "impact_flesh",
	"cover_break",
	"grapple_fire", "grapple_zip", "portal_open", "portal_hum_loop",
	"portal_teleport",
	"wave_horn", "juggernaut_horn",
	"damage_thud", "heartbeat_loop",
	"footstep_concrete", "footstep_dirt", "footstep_metal", "jump_land",
	# Goal 2 integration: Worker B's new movement/enemy one-shots.
	"slide_whoosh", "wallrun_scrape", "enemy_death", "footstep_brute",
	"spawn_telegraph",
	"ui_click", "ui_hover", "ui_confirm",
	"forge_success", "forge_fail", "killstreak_ready", "uav_online", "pickup",
	"ambient_wind_loop", "music_drone_loop",
]

# Aliases for SFX ids assumed by other workers (player/UI/weapons) that map
# onto the real synthesized files. Keeps every play_* call sounding right.
const SFX_ALIASES: Dictionary = {
	"player_hurt": "damage_thud", "player_death": "damage_thud",
	"player_land": "jump_land", "player_land_hard": "jump_land",
	"portal_fire": "portal_open", "portal_fail": "dryfire",
	"portal_travel": "portal_teleport",
	"heartbeat": "heartbeat_loop", "wave_start": "wave_horn",
	"forge_open": "ui_click", "forge_submit": "ui_confirm",
	"shot_ar7": "shot_ar", "shot_lr8": "shot_sniper", "shot_sg12": "shot_shotgun",
	"shot_smg9": "shot_smg", "shot_p9": "shot_pistol",
	# Goal 3 CONTENT: Arsenal sfx_fire ids -> real synthesized files.
	"shot_br3": "shot_burst", "shot_hv44": "shot_revolver",
	"reload_out": "reload_ar", "reload_in": "reload_ar", "reload_chamber": "reload_ar",
	"bolt_cycle": "dryfire", "pump_cycle": "dryfire",
	# Goal 2: the Raptor claw is an energy weapon — grab/throw now play the
	# distinct shot_raptor zap instead of the grapple_fire whoosh.
	"raptor_grab": "shot_raptor", "raptor_throw": "shot_raptor", "raptor_drop": "ui_click",
	"heal_pickup": "pickup",
}

# Streams that loop seamlessly (synth already crossfaded head/tail).
# Goal 2 integration: only streams with a real start AND stop path stay
# here. heartbeat_loop is played one-shot by the HUD (low-HP thump);
# portal_hum_loop and music_drone_loop have no start/stop callers, so
# they are plain one-shots in SOUND_IDS — keeping them in LOOP_IDS made
# Sfx refuse one-shot plays of them (the silent-heartbeat bug).
const LOOP_IDS: Array[String] = [
	"ambient_wind_loop",
	"grapple_zip",
]

const AUDIO_DIR := "res://assets/audio/"
#endregion

var _streams: Dictionary = {}          # id -> AudioStreamWAV
var _stream_to_id: Dictionary = {}     # AudioStreamWAV -> id (category caps)
var _pool_2d: Array[AudioStreamPlayer] = []
var _pool_3d: Array[AudioStreamPlayer3D] = []
var _idx_2d := 0
var _idx_3d := 0
var _warned: Dictionary = {}           # ids already warned about
var _muted := false
var _loop_players: Dictionary = {}     # id -> dedicated AudioStreamPlayer

# Music crossfade pair.
var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _music_active: AudioStreamPlayer
var _music_id := &""
var _music_tweens: Array[Tween] = []

# Ambient wind auto-manage (C3): poll timer for gameplay detection.
var _ambient_poll := 0.0


func _ready() -> void:
	_ensure_buses()
	_load_streams()
	_build_pools()


func _process(delta: float) -> void:
	# Ambient wind follows gameplay with no coupling to main.gd (C3):
	# a node in the "player" group exists only during a run, so wind
	# starts when gameplay starts and stops back in the menus.
	_ambient_poll -= delta
	if _ambient_poll > 0.0:
		return
	_ambient_poll = AMBIENT_POLL_SEC
	_update_ambient()


## Start the wind loop if a run is live, stop it in menus. Idempotent.
## Wind rides the MUSIC bus (play_music), not _loop_players: the loop-player
## dict is the SFX-loop registry (grapple zip, heartbeat, portal hum) and
## other checks assert on its size. Nothing else calls play_music today, so
## wind owns the music bus; if a music track ever arrives, it crossfades
## with the wind instead of stacking.
func _update_ambient() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var in_game := tree.get_first_node_in_group("player") != null
	if in_game and not is_ambient_playing():
		play_music("ambient_wind_loop", AMBIENT_WIND_DB)
	elif not in_game and is_ambient_playing():
		stop_music(0.25)


## Public ambient controls (used by the C3 verifier; gameplay uses the auto path).
func start_ambient() -> void:
	play_music("ambient_wind_loop", AMBIENT_WIND_DB)


func stop_ambient() -> void:
	if is_ambient_playing():
		stop_music(0.25)


func is_ambient_playing() -> bool:
	return current_music() == "ambient_wind_loop" and _music_active.playing


## Forge result sting. forge_manager.gd already calls play_2d("forge_success" /
## "forge_fail") on its submit paths; this is the single-call-site helper
## for any future caller. Routes through the mix table like everything else.
func play_forge_result(ok: bool) -> void:
	play_2d("forge_success" if ok else "forge_fail")


## Mix-table lookup (resolved through aliases). Public for the C3 verifier.
func mix_db_for(id: String) -> float:
	var rid: String = SFX_ALIASES.get(id, id)
	return float(MIX_DB.get(rid, 0.0))


## Caller volume + mix offset, clamped so nothing exceeds the 0 dB gunshot
## reference (no clipping, no sound louder than the gunshots).
func _mix(id: String, vol_db: float) -> float:
	return clampf(vol_db + mix_db_for(id), -60.0, 0.0)


#region Setup
func _ensure_buses() -> void:
	for bus_name in [BUS_SFX, BUS_MUSIC, BUS_UI]:
		var idx := AudioServer.get_bus_index(bus_name)
		if idx == -1:
			AudioServer.add_bus()
			idx = AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, &"Master")


func _load_streams() -> void:
	for id in SOUND_IDS:
		var path := AUDIO_DIR + "%s.wav" % id
		if not ResourceLoader.exists(path):
			push_warning("[Sfx] missing audio file: %s" % path)
			continue
		var stream := load(path) as AudioStreamWAV
		if stream == null:
			push_warning("[Sfx] failed to load as AudioStreamWAV: %s" % path)
			continue
		if id in LOOP_IDS:
			# Docs: loop_begin/loop_end are in samples; 16-bit mono -> bytes/2.
			stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
			stream.loop_begin = 0
			stream.loop_end = int(stream.get_data().size() / 2)
		_streams[id] = stream
	# Resolve cross-worker aliases onto the real streams.
	for alias in SFX_ALIASES:
		var target: String = SFX_ALIASES[alias]
		if _streams.has(target) and not _streams.has(alias):
			_streams[alias] = _streams[target]
	# Reverse map for per-category voice caps (aliases share the target's
	# stream; either id resolves to the same category, so last wins is fine).
	for id in _streams:
		_stream_to_id[_streams[id]] = id


func _build_pools() -> void:
	for i in POOL_2D_SIZE:
		var p := AudioStreamPlayer.new()
		p.name = "Sfx2D_%d" % i
		p.bus = BUS_SFX
		add_child(p)
		_pool_2d.append(p)
	for i in POOL_3D_SIZE:
		var p := AudioStreamPlayer3D.new()
		p.name = "Sfx3D_%d" % i
		p.bus = BUS_SFX
		p.unit_size = SFX_3D_UNIT_SIZE
		p.max_distance = SFX_3D_MAX_DISTANCE
		add_child(p)
		_pool_3d.append(p)
	_music_a = AudioStreamPlayer.new()
	_music_a.name = "MusicA"
	_music_a.bus = BUS_MUSIC
	add_child(_music_a)
	_music_b = AudioStreamPlayer.new()
	_music_b.name = "MusicB"
	_music_b.bus = BUS_MUSIC
	add_child(_music_b)
	_music_active = _music_a
#endregion


#region Playback
func play_2d(id: String, vol_db: float = 0.0, pitch: float = 1.0) -> void:
	"""Non-positional one-shot. UI ids auto-route to the UI bus."""
	if not _has(id):
		return
	if _is_loop_stream(id):
		# One-shots must never start a looping stream: play_2d has no stop,
		# so every call leaked a forever-looping player (the grapple zip
		# bug — one per 0.3s + one per Raptor throw, stacking forever).
		# Use start_loop_2d()/stop_loop_2d() for loop streams.
		push_warning("[Sfx] play_2d called with loop stream '%s' — refused" % id)
		return
	if _at_category_cap(id):
		return
	var p := _pool_2d[_idx_2d]
	_idx_2d = (_idx_2d + 1) % POOL_2D_SIZE
	p.stream = _streams[id]
	p.bus = _bus_for(id)
	p.volume_db = _mix(id, vol_db)
	p.pitch_scale = _jittered_pitch(pitch)
	p.play()


func play_3d(id: String, pos: Vector3, vol_db: float = 0.0, pitch: float = 1.0) -> void:
	"""Positional one-shot on the SFX bus."""
	if not _has(id):
		return
	if _is_loop_stream(id):
		push_warning("[Sfx] play_3d called with loop stream '%s' — refused" % id)
		return
	if _at_category_cap(id):
		return
	var p := _pool_3d[_idx_3d]
	_idx_3d = (_idx_3d + 1) % POOL_3D_SIZE
	p.stream = _streams[id]
	p.position = pos
	p.volume_db = _mix(id, vol_db)
	p.pitch_scale = _jittered_pitch(pitch)
	p.play()


func play_footstep(surface: String, pos: Vector3, vol_db: float = 0.0) -> void:
	"""Footstep helper. surface: 'concrete' | 'dirt' | 'metal' (default concrete)."""
	var id := "footstep_concrete"
	match surface.to_lower():
		"dirt":
			id = "footstep_dirt"
		"metal":
			id = "footstep_metal"
	play_3d(id, pos, vol_db)
#endregion


#region Loops
func start_loop_2d(id: String, vol_db: float = 0.0) -> void:
	"""Start a looping stream on its own dedicated player. IDEMPOTENT:
	calling it while the loop already plays is a no-op — this is what
	prevents the grapple zip from stacking (one player, one loop)."""
	if not _has(id):
		return
	var existing: AudioStreamPlayer = _loop_players.get(id)
	if existing != null and existing.playing:
		return
	var p: AudioStreamPlayer = existing
	if p == null:
		p = AudioStreamPlayer.new()
		p.name = "SfxLoop_%s" % id
		add_child(p)
		_loop_players[id] = p
	p.stream = _streams[id]
	p.bus = _bus_for(id)
	p.volume_db = _mix(id, vol_db)
	p.pitch_scale = 1.0
	p.play()


func stop_loop_2d(id: String) -> void:
	"""Stop a looping stream started with start_loop_2d. Safe to call
	when the loop isn't playing."""
	var p: AudioStreamPlayer = _loop_players.get(id)
	if p != null and p.playing:
		p.stop()


func _is_loop_stream(id: String) -> bool:
	# Aliases share the target's stream object, so this catches aliases
	# onto loop streams (e.g. the old raptor_throw -> grapple_zip) too.
	var stream := _streams.get(id) as AudioStreamWAV
	return stream != null and stream.loop_mode != AudioStreamWAV.LOOP_DISABLED
#endregion


#region Music
func play_music(id: String, vol_db: float = MUSIC_VOLUME_DB) -> void:
	"""Start (or crossfade to) a music/ambience loop. No-op if already playing."""
	if not _has(id):
		return
	var idn := StringName(id)
	if idn == _music_id and _music_active.playing:
		return
	var incoming: AudioStreamPlayer = _music_b if _music_active == _music_a else _music_a
	var outgoing: AudioStreamPlayer = _music_active
	_kill_music_tweens()
	incoming.stream = _streams[id]
	incoming.volume_db = -60.0
	incoming.pitch_scale = 1.0
	incoming.play()
	var fade_in := create_tween()
	fade_in.tween_property(incoming, "volume_db", vol_db, MUSIC_FADE_SEC)
	_music_tweens.append(fade_in)
	if outgoing.playing:
		var fade_out := create_tween()
		fade_out.tween_property(outgoing, "volume_db", -60.0, MUSIC_FADE_SEC)
		fade_out.tween_callback(outgoing.stop)
		_music_tweens.append(fade_out)
	_music_active = incoming
	_music_id = idn


func stop_music(fade_sec: float = MUSIC_FADE_SEC) -> void:
	"""Fade out whatever music is playing."""
	if not _music_active.playing:
		_music_id = &""
		return
	_kill_music_tweens()
	var old: AudioStreamPlayer = _music_active
	var fade := create_tween()
	fade.tween_property(old, "volume_db", -60.0, fade_sec)
	fade.tween_callback(old.stop)
	_music_tweens.append(fade)
	_music_id = &""


func _kill_music_tweens() -> void:
	for t in _music_tweens:
		if t and t.is_valid():
			t.kill()
	_music_tweens.clear()


func current_music() -> String:
	return String(_music_id)
#endregion


#region Mixer
func set_volumes(master_db: float, sfx_db: float, music_db: float, ui_db: float) -> void:
	"""Set bus levels in dB (clamped to [-60, +6])."""
	_set_bus_db(&"Master", master_db)
	_set_bus_db(BUS_SFX, sfx_db)
	_set_bus_db(BUS_MUSIC, music_db)
	_set_bus_db(BUS_UI, ui_db)


func set_muted(m: bool) -> void:
	_muted = m
	AudioServer.set_bus_mute(0, m)  # bus 0 is always Master


func toggle_mute() -> bool:
	set_muted(not _muted)
	return _muted


func is_muted() -> bool:
	return _muted


func _set_bus_db(bus_name: StringName, db: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		push_warning("[Sfx] bus missing: %s" % bus_name)
		return
	AudioServer.set_bus_volume_db(idx, clampf(db, -60.0, MAX_VOL_DB))
#endregion


#region Internals
func _has(id: String) -> bool:
	if _streams.has(id):
		return true
	if not _warned.has(id):
		_warned[id] = true
		push_warning("[Sfx] unknown sound id: '%s' (warn once)" % id)
	return false


func _bus_for(id: String) -> StringName:
	if id.begins_with("ui_"):
		return BUS_UI
	return BUS_SFX


## Category for per-category voice caps (aliases resolve first).
func _category_of(id: String) -> String:
	var rid: String = SFX_ALIASES.get(id, id)
	if rid.begins_with("shot_"):
		return "gunshot"
	if rid.begins_with("explosion_"):
		return "explosion"
	if rid.begins_with("impact_"):
		return "impact"
	if rid.begins_with("reload_"):
		return "reload"
	return "other"


## True when the id's category already has its cap of voices playing
## across both pools (loop players excluded — loops are capped by
## start_loop_2d idempotence, not by this). Refused plays drop silently.
func _at_category_cap(id: String) -> bool:
	var cat := _category_of(id)
	var cap := int(CATEGORY_CAPS.get(cat, 99))
	var n := 0
	for p in _pool_2d:
		if p.playing and p.stream != null and _category_of(str(_stream_to_id.get(p.stream, ""))) == cat:
			n += 1
			if n >= cap:
				return true
	for p in _pool_3d:
		if p.playing and p.stream != null and _category_of(str(_stream_to_id.get(p.stream, ""))) == cat:
			n += 1
			if n >= cap:
				return true
	return false


func _jittered_pitch(pitch: float) -> float:
	var p := maxf(0.1, pitch)
	return p * randf_range(1.0 - PITCH_JITTER, 1.0 + PITCH_JITTER)
#endregion

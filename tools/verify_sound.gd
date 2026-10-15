# verify_sound.gd — headless verification for FORGEFALL Goal 2 (SOUND).
# Usage: godot --headless --path <project> --script res://tools/verify_sound.gd
#
# Covers (Worker C):
#   A. Every WAV the game references exists and loads (scan game scripts +
#      scenes for audio names, load each via Godot headless), no missing
#      or zero-length audio. Every WAV on disk is registered in
#      Sfx.SOUND_IDS (else Sfx never loads it). Every literal one-shot
#      call site resolves through SFX_ALIASES to a real SOUND_ID.
#   B. Per-weapon gunshots are DISTINCT for the 7 weapons (AR, SMG,
#      shotgun, sniper, LMG, pistol, physics gun): resolve each weapon's
#      sfx_fire through aliases to a WAV, then compare resolved paths
#      AND raw PCM bytes — two weapons sharing one file = FAIL.
#   C. No double-played hit tick: the hitmarker sound has exactly one
#      owner (HUD.show_hitmarker, deduped); the ONLY tolerated second
#      site is the weapon_base fallback, which must be guarded by
#      `not hud_shown` (mutually exclusive with the HUD path, never both).
#   D. No looping SFX left running: every id in Sfx.LOOP_IDS has a start
#      path (start_loop_2d / play_music with that literal id) AND a stop
#      path (stop_loop_2d with that id, or stop_music for music-path
#      loops). No one-shot call (play_2d / play_3d / HUD _play) may target
#      a loop stream — Sfx refuses those, so such a call is silent audio.
#   E. Audio size: assets/audio/*.wav total stays under 6 MiB.
#
# Static by design (reads the live constant maps + file text, so Worker
# A/B fixes — a new LMG mapping, wired portal hum, a de-looped heartbeat —
# are judged on the code as it stands, not on hardcoded expectations).
# Behavioral spot-checks use the real Sfx autoload (loop start/stop
# idempotence, one-shot refusal for loop streams, HUD hitmarker arming).
# Exit 0 = all checks pass; any FAIL prints and exits 1.
extends SceneTree

const AUDIO_DIR := "res://assets/audio/"
const SCRIPTS_DIR := "res://scripts"
const SCENES_DIR := "res://scenes"
const MAX_AUDIO_BYTES := 6 * 1024 * 1024  # ~6M cap (task wording)

# The 7 weapons whose gunshots must be pairwise distinct.
const EXPECTED_WEAPONS: Array[String] = [
	"ar7", "smg9", "sg12", "lr8", "lmg", "p9", "raptor",
]

var _fails := 0
var _passes := 0
var _warns := 0
var _frames := 0
var _done := false

var _sound_ids: Array = []
var _loop_ids: Array = []
var _aliases: Dictionary = {}
var _game_scripts: Dictionary = {}  # path -> full text (scripts/ only)
var _scene_text: Dictionary = {}    # path -> full text (scenes/ only)
var _const_vals := {}  # `const NAME := "value"` harvested from game scripts


func _check(cond: bool, label: String) -> void:
	if cond:
		_passes += 1
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _warn(cond: bool, label: String) -> void:
	# Warn-only: prints OK on success (deliberately NOT "PASS: " so the
	# PASS-line count in logs matches _passes exactly).
	if cond:
		print("OK: ", label)
	else:
		_warns += 1
		print("WARN: ", label)


# ---------------------------------------------------------------- helpers

func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	return int(f.get_length())


func _read_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _collect_files(dir_path: String, ext: String, out: Array) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(ext):
			out.append(dir_path.path_join(f))
	for sub in d.get_directories():
		_collect_files(dir_path.path_join(sub), ext, out)


func _load_game_text() -> void:
	var gd_files: Array = []
	_collect_files(SCRIPTS_DIR, ".gd", gd_files)
	for p in gd_files:
		# Skip .uid companions (not .gd) — _collect_files already filters.
		_game_scripts[p] = _read_file(p)
	var scene_files: Array = []
	_collect_files(SCENES_DIR, ".tscn", scene_files)
	_collect_files(SCENES_DIR, ".tres", scene_files)
	for p in scene_files:
		_scene_text[p] = _read_file(p)
	# Harvest `const NAME := "value"` across game scripts (HUD SFX_* etc.).
	for path in _game_scripts.keys():
		for line in (_game_scripts[path] as String).split("\n"):
			if not line.contains("const ") or not line.contains(":="):
				continue
			var eq := line.find(":=")
			var before := line.substr(0, eq)
			var tokens := before.split(" ", false)
			var qs := _quoted(line)
			if not tokens.is_empty() and not qs.is_empty():
				_const_vals[str(tokens[tokens.size() - 1])] = qs[0]


## All SFX_* const names mentioned on a line (e.g. _play(SFX_HIT)).
func _sfx_consts(line: String) -> Array:
	var out: Array = []
	var i := 0
	while true:
		var a := line.find("SFX_", i)
		if a < 0:
			break
		# Collect [A-Z0-9_]+ from the SFX_ prefix onward.
		var k := a
		var name := ""
		while k < line.length():
			var c := line[k]
			if (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_":
				name += c
				k += 1
			else:
				break
		if not name.is_empty() and not out.has(name):
			out.append(name)
		i = a + 4
	return out


## All quoted strings on one line, in order.
func _quoted(line: String) -> Array:
	var out: Array = []
	var i := 0
	while true:
		var a := line.find('"', i)
		if a < 0:
			break
		var b := line.find('"', a + 1)
		if b < 0:
			break
		out.append(line.substr(a + 1, b - a - 1))
		i = b + 1
	return out


## Resolve an id through SFX_ALIASES (transitively) to a canonical id.
func _resolve(id: String) -> String:
	var cur := id
	var guard := 0
	while _aliases.has(cur) and guard < 8:
		cur = str(_aliases[cur])
		guard += 1
	return cur


## All ids (canonical + alias keys) that resolve to `canonical`.
func _names_for(canonical: String) -> Array:
	var out: Array = [canonical]
	for k in _aliases.keys():
		if _resolve(str(k)) == canonical:
			out.append(str(k))
	return out


## Fingerprint of a WAV's PCM: [bytes, sum, sumsq, first, mid, last sample].
## PackedByteArray == is the definitive identical check; the fingerprint
## is for the human-readable report.
func _fingerprint(stream: AudioStreamWAV) -> Array:
	var data: PackedByteArray = stream.get_data()
	var total := 0
	var total_sq := 0.0
	var first := 0
	var mid := 0
	var last := 0
	var n := int(data.size() / 2)
	for i in n:
		var lo := int(data[i * 2])
		var hi := int(data[i * 2 + 1])
		var s := hi * 256 + lo
		if s >= 32768:
			s -= 65536
		total += s
		total_sq += float(s) * float(s)
		if i == 0:
			first = s
		if i == n / 2:
			mid = s
		if i == n - 1:
			last = s
	return [data.size(), total, total_sq, first, mid, last]


func _load_wav(id: String) -> AudioStreamWAV:
	return load(AUDIO_DIR + "%s.wav" % id) as AudioStreamWAV


# ---------------------------------------------------------------- checks

func _check_registry_and_files() -> void:
	var mgr := load("res://scripts/audio/audio_manager.gd") as GDScript
	_check(mgr != null, "audio_manager.gd loads")
	if mgr == null:
		return
	var cmap := mgr.get_script_constant_map()
	_sound_ids = cmap.get("SOUND_IDS", [])
	_loop_ids = cmap.get("LOOP_IDS", [])
	_aliases = cmap.get("SFX_ALIASES", {})
	_check(not _sound_ids.is_empty(), "SOUND_IDS is non-empty (%d ids)" % _sound_ids.size())
	var seen := {}
	var dup := false
	for id in _sound_ids:
		if seen.has(id):
			dup = true
		seen[id] = true
	_check(not dup, "SOUND_IDS has no duplicates")
	_check(not _loop_ids.is_empty(), "LOOP_IDS is non-empty (%d ids)" % _loop_ids.size())
	for lid in _loop_ids:
		_check(_sound_ids.has(lid), "loop id '%s' is a registered SOUND_ID" % str(lid))

	# A1: every registered id -> file exists, loads, non-empty.
	var loaded := 0
	for id in _sound_ids:
		var sid := str(id)
		var path := AUDIO_DIR + "%s.wav" % sid
		var exists := FileAccess.file_exists(path)
		_check(exists, "WAV exists for '%s' (%s)" % [sid, path])
		if not exists:
			continue
		var bytes := _file_size(path)
		_check(bytes > 0, "WAV non-zero-length for '%s' (%d bytes)" % [sid, bytes])
		var stream := _load_wav(sid)
		_check(stream != null, "WAV loads as AudioStreamWAV: '%s'" % sid)
		if stream != null:
			_check(stream.get_data().size() > 0, "WAV has PCM data: '%s'" % sid)
			_check(stream.get_length() > 0.0, "WAV has positive duration: '%s' (%.2fs)" % [sid, stream.get_length()])
			loaded += 1
	print("VERIFY(sound): %d/%d registered WAVs loaded" % [loaded, _sound_ids.size()])

	# A2: every WAV on disk is registered (else Sfx never loads it).
	var d := DirAccess.open("res://assets/audio")
	if d != null:
		for f in d.get_files():
			if f.ends_with(".wav"):
				var base := f.substr(0, f.length() - 4)
				_check(_sound_ids.has(base), "WAV on disk is registered in SOUND_IDS: '%s'" % base)

	# A3: every literal one-shot / loop / music call site in game scripts
	# resolves through aliases to a registered id. (HUD/forge _play("...")
	# literals and SFX_* consts included; sfx_fire variables covered in B.)
	for path in _game_scripts.keys():
		var text: String = _game_scripts[path]
		var lines := text.split("\n")
		for li in lines.size():
			var line: String = lines[li]
			# Skip comments and warning/print lines: e.g. the autoload's
			# push_warning("[Sfx] play_2d called with loop stream ...")
			# mentions play_2d( + a quoted string but is not a call site.
			var stripped := line.strip_edges()
			if stripped.begins_with("#") or line.contains("push_warning") \
					or line.contains("push_error") or line.contains("printerr("):
				continue
			var is_call := line.contains("play_2d(") or line.contains("play_3d(") \
				or line.contains("start_loop_2d(") or line.contains("stop_loop_2d(") \
				or line.contains("play_music(") or line.contains("_play(")
			if not is_call:
				continue
			for q in _quoted(line):
				var resolved := _resolve(q)
				_check(_sound_ids.has(resolved),
					"call-site id resolves: '%s' -> '%s' (%s:%d)" % [q, resolved, path, li + 1])
			# SFX_* consts on call lines (HUD _play(SFX_HIT) style).
			for t in _sfx_consts(line):
				if _const_vals.has(t):
					var resolved := _resolve(str(_const_vals[t]))
					_check(_sound_ids.has(resolved),
						"call-site const resolves: %s='%s' -> '%s' (%s:%d)" % [t, _const_vals[t], resolved, path, li + 1])
	# A4: gun_update / fire_hitscan sound args (enemy guns pass ids positionally).
	for path in _game_scripts.keys():
		var text: String = _game_scripts[path]
		for li in text.split("\n").size():
			var line: String = text.split("\n")[li]
			if line.contains("gun_update(") or line.contains("fire_hitscan("):
				for q in _quoted(line):
					var resolved := _resolve(q)
					_check(_sound_ids.has(resolved),
						"enemy-gun sound id resolves: '%s' -> '%s' (%s:%d)" % [q, resolved, path, li + 1])

	# A5: scenes referencing .wav files — each must exist.
	for path in _scene_text.keys():
		var text: String = _scene_text[path]
		for li in text.split("\n").size():
			var line: String = text.split("\n")[li]
			if line.contains(".wav"):
				for q in _quoted(line):
					if q.ends_with(".wav"):
						var rel: String = str(q)
						if rel.begins_with("res://"):
							_check(FileAccess.file_exists(rel),
								"scene WAV reference exists: '%s' (%s:%d)" % [rel, path, li + 1])
						else:
							_check(FileAccess.file_exists(AUDIO_DIR + q),
								"scene WAV reference exists: '%s' (%s:%d)" % [q, path, li + 1])

	# A6 (warn-only): every registered id should be synthesized by
	# tools/gen_audio.py (sounds["id"] = ...) so the asset is regenerable.
	var gen := _read_file("res://tools/gen_audio.py")
	for id in _sound_ids:
		_warn(gen.contains('"%s"' % str(id)),
			"gen_audio.py synthesizes '%s'" % str(id))


func _check_weapon_distinctness() -> void:
	var arsenal := load("res://scripts/weapons/arsenal.gd") as GDScript
	_check(arsenal != null, "arsenal.gd loads")
	if arsenal == null:
		return
	var weapons: Dictionary = (arsenal.get_script_constant_map().get("WEAPONS", {}) as Dictionary)
	for w in EXPECTED_WEAPONS:
		_check(weapons.has(w), "weapon present in Arsenal: '%s'" % w)
	var resolved := {}  # weapon -> canonical sound id
	var pcm := {}       # weapon -> PackedByteArray
	var fps := {}       # weapon -> fingerprint
	for w in weapons.keys():
		var wid := str(w)
		var stats: Dictionary = weapons[wid]
		var raw := str(stats.get("sfx_fire", ""))
		_check(raw != "", "%s has an sfx_fire entry ('%s')" % [wid, raw])
		if raw == "":
			continue
		var canon := _resolve(raw)
		_check(_sound_ids.has(canon), "%s sfx_fire resolves: '%s' -> '%s'" % [wid, raw, canon])
		resolved[wid] = canon
		var stream := _load_wav(canon)
		_check(stream != null, "%s gunshot WAV loads: '%s'" % [wid, canon])
		if stream != null:
			pcm[wid] = stream.get_data()
			fps[wid] = _fingerprint(stream)
	# Gunshots (non-raptor) must resolve to shot_* files.
	for w in resolved.keys():
		if str(w) == "raptor":
			continue
		_check(str(resolved[w]).begins_with("shot_"),
			"%s fires a shot_* sound (got '%s')" % [str(w), str(resolved[w])])
	# Pairwise distinctness across ALL weapons in the table.
	var ids := resolved.keys()
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var a := str(ids[i])
			var b := str(ids[j])
			_check(resolved[a] != resolved[b],
				"%s and %s resolve to DIFFERENT files ('%s' vs '%s')" % [a, b, resolved[a], resolved[b]])
			if pcm.has(a) and pcm.has(b):
				_check((pcm[a] as PackedByteArray) != (pcm[b] as PackedByteArray),
					"%s and %s have DIFFERENT PCM (fingerprints %s vs %s)" % [a, b, fps[a], fps[b]])
	# The shot_lmg asset itself must exist and differ from shot_ar (so a
	# correct LMG mapping has a distinct file to point at).
	if _sound_ids.has("shot_lmg") and _sound_ids.has("shot_ar"):
		var lmg := _load_wav("shot_lmg")
		var ar := _load_wav("shot_ar")
		if lmg != null and ar != null:
			_check(lmg.get_data() != ar.get_data(),
				"shot_lmg.wav PCM differs from shot_ar.wav (distinct asset exists)")


func _check_hitmarker_single_owner() -> void:
	# Collect hitmarker play sites in game scripts: lines mentioning
	# "hitmarker" together with a play call, or SFX_HIT on a _play line.
	var sites: Array = []
	for path in _game_scripts.keys():
		var text: String = _game_scripts[path]
		var lines := text.split("\n")
		for li in lines.size():
			var line: String = lines[li]
			var is_hit_play := (line.contains("hitmarker") and (line.contains("play_2d(") or line.contains("play_3d(") or line.contains("_play("))) \
				or (line.contains("SFX_HIT") and line.contains("_play("))
			if is_hit_play:
				sites.append("%s:%d: %s" % [path, li + 1, line.strip_edges()])
	print("VERIFY(sound): hitmarker play sites (%d):" % sites.size())
	for s in sites:
		print("VERIFY(sound):   ", s)
	var hud_sites := 0
	var fallback_guarded := false
	var other_sites := 0
	for s in sites:
		var site := str(s)
		if site.contains("scripts/ui/hud.gd"):
			hud_sites += 1
		elif site.contains("scripts/weapons/weapon_base.gd"):
			# Guarded fallback? `if not hud_shown:` within 15 lines above.
			var wtext: String = _game_scripts["res://scripts/weapons/weapon_base.gd"]
			var wlines := wtext.split("\n")
			for li in wlines.size():
				if wlines[li].contains("hitmarker") and (wlines[li].contains("play_2d(") or wlines[li].contains("play_3d(")):
					var guard_found := false
					for back in range(1, 16):
						if li - back < 0:
							break
						if wlines[li - back].contains("not hud_shown"):
							guard_found = true
							break
					fallback_guarded = guard_found
		else:
			other_sites += 1
	_check(hud_sites == 1, "exactly ONE HUD hitmarker play site (found %d)" % hud_sites)
	_check(other_sites == 0, "no hitmarker play site outside HUD + weapon fallback (found %d)" % other_sites)
	if sites.size() > 1:
		_check(fallback_guarded,
			"second hitmarker site is the weapon_base fallback guarded by 'not hud_shown' (mutually exclusive, never double-play)")
	# Dedupe: HUD show_hitmarker must gate the tick on _hit_snd_t.
	var hud_text: String = _game_scripts.get("res://scripts/ui/hud.gd", "")
	_check(hud_text.contains("_hit_snd_t <= 0.0"),
		"HUD show_hitmarker dedupes the tick on _hit_snd_t (no same-frame stack)")
	_check(hud_text.contains("HIT_SOUND_MIN_GAP"),
		"HUD defines HIT_SOUND_MIN_GAP for the hit-tick dedupe window")
	# Behavioral: real HUD arms the hitmarker timer on show_hitmarker.
	var hud_script := load("res://scripts/ui/hud.gd") as GDScript
	if hud_script != null:
		var hud: CanvasLayer = hud_script.new()
		root.add_child(hud)
		hud.call("show_hitmarker", false, false)
		_check(float(hud.get("_hit_t")) > 0.0,
			"real HUD show_hitmarker arms the hitmarker timer (_hit_t %.2f)" % float(hud.get("_hit_t")))
		hud.queue_free()


func _check_loops() -> void:
	var all_text := ""
	for path in _game_scripts.keys():
		all_text += _game_scripts[path] + "\n"
	for loop_id in _loop_ids:
		var lid := str(loop_id)
		var names := _names_for(lid)
		var has_start := false
		var started_via_music := false
		var has_stop := false
		for n in names:
			if all_text.contains('start_loop_2d("%s"' % n):
				has_start = true
			if all_text.contains('play_music("%s"' % n):
				has_start = true
				started_via_music = true
			if all_text.contains('stop_loop_2d("%s"' % n):
				has_stop = true
		# Music-path loops stop via the generic stop_music / stop_ambient.
		if started_via_music and (all_text.contains("stop_music(") or all_text.contains("stop_ambient(")):
			has_stop = true
		_check(has_start, "loop '%s' has a START path (start_loop_2d / play_music; names: %s)" % [lid, names])
		_check(has_stop, "loop '%s' has a STOP path (stop_loop_2d / stop_music; names: %s)" % [lid, names])
	# No one-shot call may target a loop stream (Sfx refuses those -> silence).
	for path in _game_scripts.keys():
		if path == "res://scripts/audio/audio_manager.gd":
			continue  # the autoload's own refusal guards are not call sites
		var text: String = _game_scripts[path]
		var lines := text.split("\n")
		for li in lines.size():
			var line: String = lines[li]
			var stripped := line.strip_edges()
			if stripped.begins_with("#") or line.contains("push_warning") \
					or line.contains("push_error") or line.contains("printerr("):
				continue
			var is_oneshot := line.contains("play_2d(") or line.contains("play_3d(") or line.contains("_play(")
			if not is_oneshot:
				continue
			for q in _quoted(line):
				var resolved := _resolve(q)
				_check(not _loop_ids.has(resolved),
					"one-shot call does NOT target loop stream: '%s' -> '%s' (%s:%d)" % [q, resolved, path, li + 1])
			# HUD _play(SFX_HEARTBEAT) style: resolve every SFX_* const.
			for t in _sfx_consts(line):
				if _const_vals.has(t):
					var resolved := _resolve(str(_const_vals[t]))
					_check(not _loop_ids.has(resolved),
						"one-shot const call does NOT target loop stream: %s='%s' -> '%s' (%s:%d)" % [t, _const_vals[t], resolved, path, li + 1])
	# Warn-only: a *_loop.wav on disk that is NOT in LOOP_IDS will never
	# loop (Sfx only loops LOOP_IDS). Not a FAIL: a worker may legitimately
	# de-loop a file (e.g. heartbeat -> one-shot) and keep the filename.
	var d := DirAccess.open("res://assets/audio")
	if d != null:
		for f in d.get_files():
			if f.ends_with("_loop.wav"):
				var base := f.substr(0, f.length() - 4)  # strip ".wav"
				_warn(_loop_ids.has(base),
					"'%s' is registered in LOOP_IDS (loop-named file actually loops)" % base)


func _check_audio_size() -> void:
	var total := 0
	var d := DirAccess.open("res://assets/audio")
	if d != null:
		for f in d.get_files():
			if f.ends_with(".wav"):
				total += _file_size("res://assets/audio".path_join(f))
	print("VERIFY(sound): audio total %d bytes (%.2f MiB), cap %d bytes (6 MiB)" % [total, float(total) / 1048576.0, MAX_AUDIO_BYTES])
	_check(total > 0, "audio total is non-zero")
	_check(total < MAX_AUDIO_BYTES,
		"audio total %.2f MiB < 6 MiB cap" % (float(total) / 1048576.0))


func _check_behavioral_loops() -> void:
	var sfx := root.get_node_or_null("Sfx")
	_check(sfx != null, "Sfx autoload present for behavioral loop checks")
	if sfx == null:
		return
	var streams: Dictionary = sfx.get("_streams")
	for loop_id in _loop_ids:
		var lid := str(loop_id)
		var st := streams.get(lid) as AudioStreamWAV
		_check(st != null and st.loop_mode != AudioStreamWAV.LOOP_DISABLED,
			"Sfx stream '%s' has looping enabled (loop_mode != DISABLED)" % lid)
		# One-shot refusal: play_2d on a loop stream must not start a player.
		var before: int = (sfx.get("_loop_players") as Dictionary).size()
		sfx.call("play_2d", lid)
		_check((sfx.get("_loop_players") as Dictionary).size() == before,
			"play_2d('%s') refused (no loop player leaked)" % lid)
	# Full start/stop cycle for every loop with a start_loop_2d path.
	var all_text := ""
	for path in _game_scripts.keys():
		all_text += _game_scripts[path] + "\n"
	for loop_id in _loop_ids:
		var lid := str(loop_id)
		var names := _names_for(lid)
		var has_start_loop := false
		for n in names:
			if all_text.contains('start_loop_2d("%s"' % n):
				has_start_loop = true
		if not has_start_loop:
			continue
		sfx.call("start_loop_2d", lid)
		sfx.call("start_loop_2d", lid)  # idempotent: must not stack
		var loops: Dictionary = sfx.get("_loop_players")
		var p = loops.get(lid)
		_check(p != null and p.playing, "start_loop_2d('%s') starts the loop" % lid)
		var playing_count := 0
		for v in loops.values():
			if v != null and v.playing:
				playing_count += 1
		_check(playing_count == 1, "double start_loop_2d('%s') still = 1 playing loop (no stack)" % lid)
		sfx.call("stop_loop_2d", lid)
		_check(not (p != null and p.playing), "stop_loop_2d('%s') stops the loop" % lid)


func _process(_delta: float) -> bool:
	if _done:
		return true
	_frames += 1
	if _frames < 2:
		return false
	_done = true
	_load_game_text()
	_check_registry_and_files()
	_check_weapon_distinctness()
	_check_hitmarker_single_owner()
	_check_loops()
	_check_audio_size()
	_check_behavioral_loops()
	print("VERIFY(sound): %d passed, %d failed, %d warnings" % [_passes, _fails, _warns])
	if _fails == 0:
		print("VERIFY(sound): ALL CHECKS PASSED")
	else:
		printerr("VERIFY(sound): %d CHECK(S) FAILED" % _fails)
	quit(_fails)
	return true

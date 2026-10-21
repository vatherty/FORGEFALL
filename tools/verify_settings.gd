# Run with XDG_DATA_HOME=/tmp/forge-settings-verification to isolate credentials.
extends SceneTree
var failures := 0
var checks := 0
func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
	print(("PASS: " if condition else "FAIL: ") + label)
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	if not OS.get_user_data_dir().begins_with("/tmp/forge-settings-verification/"):
		printerr("Use XDG_DATA_HOME=/tmp/forge-settings-verification to avoid touching real preferences.")
		quit(1)
		return
	var prefs: Node = root.get_node("Preferences")
	await process_frame
	if "--reload" in OS.get_cmdline_user_args():
		check(is_equal_approx(float(prefs.values.sensitivity), 1.35), "preferences restored after process restart")
		quit(1 if failures else 0)
		return
	var cfg := ConfigFile.new()
	cfg.set_value("game", "mode", "tdm")
	cfg.save(prefs.PATH)
	check(prefs.change("master_vol", 0.0) == OK, "preference saved")
	check(AudioServer.is_bus_mute(AudioServer.get_bus_index("Master")), "zero volume mutes audio")
	cfg.load(prefs.PATH)
	check(cfg.get_value("game", "mode") == "tdm", "unrelated settings preserved")
	check(cfg.get_value("ui", "master_vol") == 0.0, "volume persisted")
	var player: Node = load("res://scenes/player.tscn").instantiate()
	root.add_child(player)
	prefs.change("sensitivity", 1.75)
	prefs.change("invert_y", true)
	prefs.change("fov", 105.0)
	check(is_equal_approx(player.look_sensitivity, 1.75) and player.invert_y and player.preferred_fov == 105.0, "live player preferences applied")
	var main_menu: Node = load("res://scenes/ui/main_menu.tscn").instantiate()
	root.add_child(main_menu)
	main_menu._on_options()
	check(main_menu.get_node_or_null("SettingsMenu") != null, "main menu opens shared settings")
	main_menu.get_node("SettingsMenu")._close()
	await process_frame
	main_menu.free()
	var settings: Node = load("res://scripts/ui/settings_menu.gd").open_in(root)
	check(settings.find_child("SettingsTabs", true, false).get_tab_count() == 5, "five settings categories")
	check(settings._key.secret and settings._key.text.is_empty(), "key field masked and does not expose saved credentials")
	settings._key.text = ""
	settings._save_key()
	check(settings._status.text.contains("non-empty"), "empty keys rejected")
	settings._key.text = "test-fixture-not-a-real-key"
	settings._save_key()
	check(ForgeConfig.load_key() == "test-fixture-not-a-real-key", "shared Forge and mod credential store updated")
	check(settings._key.text.is_empty(), "key removed from field after save")
	settings._reset()
	check(prefs.values.sensitivity == 1.75, "reset requires confirmation")
	settings._reset()
	check(prefs.values.sensitivity == prefs.DEFAULTS.sensitivity, "confirmed reset applies defaults")
	check(ForgeConfig.load_key() == "test-fixture-not-a-real-key", "reset preserves AI credential")
	settings._remove_key()
	check(ForgeConfig.load_key().is_empty(), "remove deletes usable credential")
	settings._close()
	await process_frame
	var pause: Node = load("res://scenes/ui/pause_menu.tscn").instantiate()
	root.add_child(pause)
	paused = true
	pause._on_options()
	check(pause.get_node_or_null("SettingsMenu") != null and paused, "shared settings open while paused")
	pause.get_node("SettingsMenu")._close()
	check(paused, "closing settings preserves pause")
	paused = false
	pause.free()
	player.free()
	prefs.change("sensitivity", 1.35)
	print("SETTINGS: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)

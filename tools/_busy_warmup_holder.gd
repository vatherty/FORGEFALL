# tools/_busy_warmup_holder.gd — test helper (NOT a suite).
# Reproduces the exact condition of Main._ready() calling
# WebWarmup.begin(self): a node that starts the warmup from inside its
# OWN _ready(), while it is still "busy setting up children". Before the
# Phase-0 fix, the pools' add_child() calls failed here; after the fix
# (one frame of deferral) they succeed.
extends Node

const WebWarmupScript := preload("res://scripts/core/web_warmup.gd")

var warmup: Node = null


func _ready() -> void:
	get_tree().current_scene = self
	warmup = WebWarmupScript.begin(self, true)

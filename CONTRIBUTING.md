# Contributing — adding a new effect kind

FORGEFALL's mod API grows with requests: when a mod idea needs something that
doesn't exist yet (slow was the first — the Bubble Blaster asked for it and
the effect table didn't have it), you add it as a commit. This is the whole
point of the repo being open source. A new effect kind touches six places:

## 1. Define the kind — `scripts/mods/mod_hook.gd`

Add the kind name, its parameters, and its validation (ranges, allowed hook
points). Status effects belong on `on_hit` / `on_kill` (hit target) or
`on_damage_taken` (the player) — never on fire points, where no target exists
yet. Keep parameters bounded (e.g. slow factor 0.05–1.0, duration 0.5–30s);
the validator rejects anything outside the ranges.

## 2. Implement it — `scripts/mods/mod_status_effects.gd`

Per-target metadata + a self-cleaning ticker. Re-application keeps the
strongest value + longest duration. If your effect changes movement speed,
it flows through `ModStatusEffects.speed_multiplier(target)` — locomotion
(`EnemyBase._apply_locomotion`, player ground movement) already multiplies by
it, so you don't touch locomotion code. A mod is an explicit player-built
exception: mod effects apply to any `CharacterBody3D`, including the brute.

## 3. Wire it into the hook system — `scripts/mods/mod_api.gd` (+ registry)

`_apply_effect` applies the kind to the hook context's target (or the player
for `on_damage_taken`). `ModAPI.apply_status_effect()` is the hook-facing
entry point, usable from code hooks too. The merged hook result should gain a
`status_applied` flag so the sandbox and approval can report it.

## 4. Teach the LLM it exists — `scripts/mods/mod_creator.gd`

Document the kind in `HOOK_PROMPT_ADDENDUM` (parameters, target rule, one
example). Be explicit about what it is NOT — the Bubble Blaster failed because
the prompt never mentioned slow, so the model expressed slowing as smoke +
announce. If a new kind can be confused with an old one, say so.

## 5. Show it — approval + sandbox

- Approval: `ModHook.summarize_hooks()` (called from
  `scripts/ui/mod_creator_menu.gd`) must list the effect per hook, e.g.
  `Effects: slow x0.50 for 3.0s`. A player approving a mod must see the
  effect in the payload, not just in prose.
- Sandbox: `scripts/ui/sandbox_test_room.gd` must parse and apply the effect
  on the dummy (it has a base speed for this) and REPORT it visibly, e.g.
  `SLOWED: dummy speed 4.0 → 2.0 m/s for 3.0s.` A status-effect mod must be
  verifiable in the sandbox, not just "HIT".

## 6. Test it — `tools/verify_status_effects.gd`

Add cases for: validation (ranges, hook-point rejection), the prompt catalog
mentioning the kind, the approval summary, registry apply (including the
`on_damage_taken` → player fallback), the status system (refresh-strongest,
expiry recovery, ticker cleanup), the sandbox report, and one real
`EnemyBase` driven through `_apply_locomotion` showing the effect apply and
wear off. Run the suite headless, plus `verify_forge_batch`,
`verify_creator_fix`, `verify_invented_hooks`, `verify_creator_chat`,
`verify_fixes`, and the 900-frame smoke test — all green before you open
the PR.

## Rules that don't bend

- **No new raw-engine access.** Hook code may only call ModAPI methods.
  The validator is the boundary: forbidden APIs (file/network/eval/process,
  dynamic code loading, raw node manipulation) are rejected, and the
  rejection names the violation.
- **Approval stays.** A mod with your effect still goes through
  generation → validation → approval → Install. Nothing installs silently.
- **Errors disable visibly, never crash.** A hook that errors at load or run
  disables the mod with a message. Never let a bad mod take the game down.
- **Don't fake it.** If the game can't actually apply your effect, don't
  express it as a lookalike (smoke for slow). Either implement it or leave
  it out.

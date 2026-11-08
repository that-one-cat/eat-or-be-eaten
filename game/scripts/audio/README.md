# scripts/audio

Presentation-only sound (S7, GAME_DESIGN §11). Reads sim events and state, never writes the sim.

- `audio_director.gd` (`AudioDirector`, node in `scenes/maps/reef.tscn`, set up by `reef.gd`): sim events -> SFX groups
  (pooled `AudioStreamPlayer3D` for world sounds near the camera, `AudioStreamPlayer` for the player's own), random
  variant + small pitch jitter, per-group caps; music (theme + boss layer in sync, crossfade while the boss is engaged)
  and the ambience loop. `play_counts` counts plays per group (also headless) for checks.
- `ui_sounds.gd` (`UiSounds`, node in `scenes/main.tscn`): click / hover for every `BaseButton` in the tree, including
  buttons created later (pick cards). No screen script is touched.

Buses (`res://default_bus_layout.tres`): `Master` (hard limiter -0.5 dB) <- `Music`, `SFX` <- `Underwater` (-3 dB,
low-pass 3 kHz + light reverb). World and player SFX play on `Underwater`, UI and ambience on `SFX`, music on `Music`; the S6
settings volumes (Master / Music / SFX) therefore cover everything.

Event map: BITTEN -> `bite_small` / `bite_big` (damage >= `rules.feedback.chomp_min_frac` of max HP, or a boss dash
hit); player BITE_MISSED (F1, throttled by the sim) -> `bite_miss`; EATEN -> `swallow`; DIED -> `kill`; SPIKED (player) -> `bite_small`; INFLATED / RESPAWNED / player
PLANKTON_EATEN -> `bubbles`; player boost start and Bite-Dash -> `boost`; SONAR_PULSE -> `sonar`; BOSS_TELL ->
`boss_tell`; BOSS_DASH -> `boss_dash`; player BAND_UP and BOSS_DEFEATED -> `band_up`.

Headless (Dummy audio driver): everything loads and events are handled, but no stream is started (a playing stream on
Dummy outlives the quit-time resource cleanup and prints "resources still in use at exit").

Assets and generators: `tools/audio/README.md`.

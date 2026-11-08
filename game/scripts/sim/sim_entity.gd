class_name SimEntity
extends RefCounted
## Sim-owned state of one creature or food bit. Mutated only by SimWorld while applying commands and stepping
## (NPC brain fields: by NpcBrain during SimWorld.step()).

enum Kind { CREATURE, FOOD_BIT }

## The control mode every entity starts in (and the only one an NPC can have).
const CLASSIC_MODE: StringName = &"classic"

var id: int = 0
## Kind.CREATURE or Kind.FOOD_BIT.
var kind: int = Kind.CREATURE
var species_id: StringName = &""
var position: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
## Unit vector.
var heading: Vector3 = Vector3.FORWARD
var length_m: float = 0.0
var hp: float = 1.0
var max_hp: float = 1.0
var hunger: float = 0.0
var xp: float = 0.0
## Size band, 1..4.
var band: int = 1
var stamina: float = 0.0
## Boost actually active; derived each tick by SimWorld from `boost_held` and stamina.
var boosting: bool = false
## Boost intent (Shift held); set by BOOST commands.
var boost_held: bool = false
var is_player: bool = false
## False while a player waits for its respawn (NPCs are removed when they die).
var alive: bool = true
## Brake held (S key); set by BRAKE commands.
var braking: bool = false
## |velocity| after the last tick, m/s.
var speed: float = 0.0
## Derived from `heading` every tick, for presentation: yaw 0 = facing -Z (Godot rotation.y convention),
## pitch positive = nose up. No roll in the swim model.
var yaw_deg: float = 0.0
var pitch_deg: float = 0.0

## Player deaths so far.
var deaths: int = 0
## Tick at which a dead player respawns; -1 while alive.
var respawn_tick: int = -1
## A BITE resolves only when world.tick >= bite_ready_tick (cooldown after a landed bite).
var bite_ready_tick: int = 0
## Inflated (puffer) while world.tick < inflated_until_tick.
var inflated_until_tick: int = -1
## Set on an NPC victim when bitten: who bit it and until which tick it stays aggressive. Read by NpcBrain.
var aggro_target: int = -1
var aggro_until_tick: int = -1
## NpcBrain state machine value (meaning owned by NpcBrain).
var brain_state: int = 0
## Inside a hiding volume (kelp/coral) and since when.
var hidden: bool = false
var hidden_since_tick: int = -1
## Who last damaged this creature (bite, spikes, swallow); -1 = nobody / starvation. DIED.other_id.
var last_damage_from: int = -1
## Player XP for which band / length / max HP were last derived; growth re-derives them when `xp` differs
## (so a length set explicitly at spawn is kept until the XP changes).
var grown_at_xp: float = 0.0
## Pending BITE (target id, -1 = best target in the cone), SimWorld.NO_BITE (-2) otherwise. Set while applying
## commands; the bite phase consumes it on a hit or once world.tick >= bite_until_tick.
var bite_request: int = -2
## Last tick (inclusive) the pending bite_request may still fire: the command tick + rules.bite_buffer_s for
## players, the command tick for NPCs (single-tick bites); -1 = none.
var bite_until_tick: int = -1
## Players: earliest tick of the next BITE_MISSED cue (rules.bite_miss_cooldown_s throttle; never delays a bite).
var bite_miss_ready_tick: int = 0
## Aim assist lock memory (T1.5, players, only touched and hashed while aim_assist_strength > 0): the creature the last
## assisted selection chose (-1 = none) and the last tick (exclusive) the memory counts.
var aim_lock_target: int = -1
var aim_lock_until_tick: int = 0
## Control mode (T1.4, players): id from controls/modes.json set by SET_CONTROL_MODE; `classic` = nothing changes. The sim
## reads it for the effective aim assist / lunge strengths (max(global rule, mode value)); hashed only while not classic.
var control_mode: StringName = CLASSIC_MODE
## Promoted school member (S4): the SchoolSystem school id and member index it came from, -1 for none, and the tick
## it was promoted (TierManager keeps it interactive for at least tiers.min_interactive_s).
var school_id: int = -1
var school_member: int = -1
var school_since_tick: int = -1

## S6 progression (players; Progression): mutation node ids in pick order, granted active abilities (ability ids in
## grant order) with the tick each is ready again (parallel to `abilities`, Abilities), the open mutation offer
## (empty = none) and the bands an offer was already made for (a band regained after a death offers nothing).
var mutations: PackedStringArray = PackedStringArray()
var abilities: PackedStringArray = PackedStringArray()
var ability_ready_ticks: PackedInt64Array = PackedInt64Array()
var pending_offer: PackedStringArray = PackedStringArray()
var picks_offered_for_band: PackedInt32Array = PackedInt32Array()
## Passives of the owned mutations (Progression.apply_effects; neutral without any). presence_sector_deg: presence
## indicator coverage for presentation (players: rules presence.sector_deg, 360 with Wide Vision; 0 for NPCs).
var bite_power_mult: float = 1.0
var swim_speed_mult: float = 1.0
var boost_duration_mult: float = 1.0
var boost_speed_mult: float = 1.0
var hunger_drain_mult: float = 1.0
var damage_taken_mult: float = 1.0
var presence_sector_deg: float = 0.0
## Lunge (player Bite-Dash, boss charge): while world.tick < dash_until_tick the creature moves with dash_velocity
## (heading locked to it); -1 = no lunge. dash_ability: &"bite_dash" | &"boss_dash".
var dash_until_tick: int = -1
var dash_velocity: Vector3 = Vector3.ZERO
var dash_ability: StringName = &""
## Bite lunge (T1.6, players, only touched and hashed while rules.lunge_strength > 0): ticks of the lunge window still to run
## after a landed bite (0 = none) and the extra forward speed (m/s, along the heading) it adds on top of the normal motion.
var bite_lunge_left: int = 0
var bite_lunge_mps: float = 0.0
## Boss only (BossBrain; boss_state -1 = not a boss): state, tick it was entered, engaged target, locked charge
## direction, last tick a living player was within engage range, earliest tick of the next charge tell, home point
## (spawn position, DISENGAGE swims back there) and the players the current charge already hit. boss_hug_tick: the
## tick the target came inside dash_min_range_m (-1 = it is not that close; the close-range charge, S7).
var boss_state: int = -1
var boss_state_tick: int = 0
var boss_target: int = -1
var boss_dir: Vector3 = Vector3.ZERO
var boss_seen_tick: int = -1
var boss_attack_tick: int = 0
var boss_home: Vector3 = Vector3.ZERO
var boss_dash_hits: PackedInt32Array = PackedInt32Array()
var boss_hug_tick: int = -1

## Food bits only: what swallowing the bit gives, when it disappears, and the length of the creature it came from
## (XP falloff is computed against that length, not the bit's tiny one).
var xp_value: float = 0.0
var hunger_value: float = 0.0
var expire_tick: int = -1
var source_length_m: float = 0.0
## Species of the creature the bit came from (its xp_band_mult applies when the bit is eaten).
var source_species: StringName = &""

# Current MOVE intent; persists until the next MOVE for this entity.
var move_dir: Vector3 = Vector3.ZERO
var move_thrust: float = 0.0
# Last BITE / ABILITY request.
var last_bite_target: int = -1
var last_ability_id: StringName = &""

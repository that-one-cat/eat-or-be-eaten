class_name SimEvent
extends RefCounted
## Something that happened in the sim; presentation reads these, never writes them.
## entity_id is the subject the event happened to, other_id the other party (-1 when n/a):
## - ENTITY_SPAWNED: the new creature. FOOD_SPAWNED: the bit; other = the creature it came from.
## - EATEN: the swallowed creature or food bit; other = the eater; value = XP the eater gained.
## - BITTEN: the victim; other = the biter; value = damage; data {"max_hp": victim max HP}.
## - DIED: the dead creature; other = the killer (-1 = starvation); data {"species", "length", "pos"}.
## - BAND_UP / BAND_DOWN: the entity; value = the new band.
## - RESPAWNED: the player; data {"pos"}.
## - INFLATED: the puffer; value = seconds inflated. SPIKED: the biter; other = the puffer; value = damage.
## - HIDDEN / REVEALED: the creature entering / leaving a hiding volume.
## School and plankton events (S4; SchoolSystem.apply_event() replays the school ones, data keys are ints):
## - SCHOOL_MEMBER_PROMOTED: entity = the new interactive entity; data {"school", "k", "entity"}. It is spawned at
##   the member slot in the same tick (an ENTITY_SPAWNED for it comes first).
## - SCHOOL_MEMBER_DEMOTED: entity = the entity removed in the same tick (no DIED); data {"school", "k"}; the member is
##   back in the ambient form.
## - SCHOOL_MEMBER_EATEN: entity = the promoted entity that died or was swallowed; other = the eater/killer (-1 n/a);
##   data {"school", "k"}; the slot respawns respawn_s later.
## - SCHOOL_MEMBER_RESPAWNED: entity -1; data {"school", "k"}; the member is back in the ambient form.
## - PLANKTON_EATEN: entity = the eater; value = XP gained; data {"cell": PlanktonField cell index, "amount": density
##   eaten, "pos": cell centre, "field": 0 = SimWorld.plankton, i + 1 = SimWorld.krill[i]}. Krill: one event per
##   critter, "amount" = KrillField.unit, "pos" = the critter's position, plus "k" = its index in the cell.
## Progression, abilities and the boss (S6; data values are Strings / PackedStringArray / ints / floats / Vector3):
## - MUTATION_OFFERED: entity = the player; value = the band the offer is for; data {"offer": PackedStringArray of 1-3
##   node ids, "band": int}. The player's `pending_offer` holds the same ids until a PICK_MUTATION.
## - MUTATION_PICKED: entity = the player; data {"node_id": String, "ability": String granted ability id or ""}.
## - ABILITY_USED: entity = the user; data {"ability": String}; value = cooldown seconds started.
## - DASH_STARTED / DASH_ENDED: entity = the lunging creature (player Bite-Dash or boss charge); data {"ability":
##   "bite_dash" | "boss_dash", "dir": Vector3 (STARTED), "duration": seconds (STARTED)}. Bite-Dash bites right after
##   DASH_ENDED in the same tick (a BITTEN with other = the player follows when something was in the cone).
## - SONAR_PULSE: entity = the player; data {"radius": float, "duration": float, "contacts": Array of
##   {"id": int, "rel": "smaller" | "similar" | "bigger"}} (creatures within radius, ascending id, self excluded).
## - BOSS_ENGAGED: entity = the boss; other = the player it engages. BOSS_DISENGAGED: entity = the boss.
## - BOSS_TELL: entity = the boss; other = the target; value = wind-up seconds; data {"dir": Vector3 locked charge
##   direction}. BOSS_DASH: entity = the boss; other = the target; data {"dir": Vector3, "speed": m/s, "duration": s}.
##   A dash that hits a player emits BITTEN (victim = player, other = boss, data {"max_hp", "dash": true}).
## - BOSS_STUNNED: entity = the boss; other = who dealt the last damage. BOSS_DEFEATED: entity = the boss; other = the
##   finishing player; data {"pos": Vector3}; followed in the same tick by DIED (boss) and FOOD_SPAWNED (giant remains).
## - VICTORY (once per world): entity = the finishing player; data {"run_ticks": int, "deaths": int, "mutations":
##   PackedStringArray}.
## Bite feel (F1; appended at the end of the enum so the older ordinals stay stable):
## - BITE_MISSED: entity = the player whose ready bite found nothing in its cone (a pending BITE or the Bite-Dash end
##   bite); value 0. Players only; not emitted while the bite is on cooldown; at most once per
##   rules.bite_miss_cooldown_s. The pending bite keeps retrying, so a BITTEN may follow within rules.bite_buffer_s.
## Food sites (food task; FoodSites ids are NOT entity ids; appended after BITE_MISSED, older ordinals stay stable):
## - SITE_BITTEN: entity = the biting player; value = damage; data {"site": int, "type": StringName, "pos": Vector3 site
##   centre, "max_hp": float, "hp": float HP left (<= 0 on the killing bite, a SITE_EATEN follows in the same tick)}.
## - SITE_EATEN: entity = the eating player; value = XP gained; data {"site", "type", "pos", "soft": bool (swallowed
##   soft site; false = a hard site killed by a bite)}.
## - SITE_RESPAWNED: entity -1; data {"site", "type", "pos"}; emitted in the tick the site is back (respawn_s after
##   its SITE_EATEN).

enum Type { ENTITY_SPAWNED, EATEN, BITTEN, DIED, BAND_UP, BAND_DOWN, RESPAWNED, INFLATED, SPIKED, FOOD_SPAWNED, HIDDEN, REVEALED,
	SCHOOL_MEMBER_PROMOTED, SCHOOL_MEMBER_DEMOTED, SCHOOL_MEMBER_EATEN, SCHOOL_MEMBER_RESPAWNED, PLANKTON_EATEN,
	MUTATION_OFFERED, MUTATION_PICKED, ABILITY_USED, DASH_STARTED, DASH_ENDED, SONAR_PULSE,
	BOSS_ENGAGED, BOSS_TELL, BOSS_DASH, BOSS_DISENGAGED, BOSS_STUNNED, BOSS_DEFEATED, VICTORY, BITE_MISSED,
	SITE_BITTEN, SITE_EATEN, SITE_RESPAWNED }

var type: Type = Type.ENTITY_SPAWNED
## Tick at which the event happened (SimWorld.tick at that moment).
var tick: int = 0
var entity_id: int = 0
## Second entity involved, -1 when n/a.
var other_id: int = -1
var value: float = 0.0
var data: Dictionary = {}


static func create(p_type: Type, p_tick: int, p_entity_id: int, p_other_id: int = -1, p_value: float = 0.0) -> SimEvent:
	var e := SimEvent.new()
	e.type = p_type
	e.tick = p_tick
	e.entity_id = p_entity_id
	e.other_id = p_other_id
	e.value = p_value
	return e

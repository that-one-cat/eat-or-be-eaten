class_name SimRules
extends RefCounted
## Pure eat / bite / growth / hunger formulas (GAME_DESIGN sections 2-3). Static, stateless, no content lookups:
## every number comes in as an argument (callers read it from game/data), so the same rules serve players and NPCs.


## Swallow whole: the target is at most `swallow_ratio` of the eater's length.
static func can_swallow(eater_len: float, target_len: float, swallow_ratio: float) -> bool:
	return target_len <= eater_len * swallow_ratio


## NPC max HP: base_hp(species) * length^2.
static func creature_max_hp(base_hp: float, length_m: float) -> float:
	return base_hp * length_m * length_m


## bite_power(band of the eater) * eater_length^2 * multipliers (species bite_mult, later mutations).
static func bite_damage(bite_power: float, eater_len: float, mult: float) -> float:
	return bite_power * eater_len * eater_len * mult


## Full `target_xp` while target_len / eater_len >= falloff.full_at_ratio; below that the multiplier falls linearly
## in log(ratio) to falloff.min_mult at falloff.min_ratio and stays there for even smaller targets.
static func xp_gain(target_xp: float, eater_len: float, target_len: float, falloff: Dictionary) -> float:
	var full_at: float = float(falloff.get("full_at_ratio", 0.0))
	var min_ratio: float = float(falloff.get("min_ratio", 0.0))
	var min_mult: float = float(falloff.get("min_mult", 1.0))
	if eater_len <= 0.0 or target_len <= 0.0:
		return target_xp * min_mult
	var ratio: float = target_len / eater_len
	if ratio >= full_at:
		return target_xp
	if ratio <= min_ratio or full_at <= min_ratio:
		return target_xp * min_mult
	var t: float = (log(ratio) - log(min_ratio)) / (log(full_at) - log(min_ratio))
	return target_xp * lerpf(min_mult, 1.0, clampf(t, 0.0, 1.0))


## 1-based band index for `xp` (highest band whose xp_to_reach <= xp; band 1 below every threshold).
static func band_for_xp(xp: float, bands: Array) -> int:
	var band: int = 1
	for i in bands.size():
		if xp >= float(bands[i].get("xp_to_reach", INF)):
			band = i + 1
	return band


## Player length for `xp`: inside the band reached, length goes from length_m.min to length_m.max on a log scale
## as XP moves from xp_to_reach to xp_full_length (= the next band's threshold; the last band keeps growing to its
## max at its own xp_full_length). Clamped at both ends; 0 without bands.
static func length_for_xp(xp: float, bands: Array) -> float:
	if bands.is_empty():
		return 0.0
	var b: Dictionary = bands[band_for_xp(xp, bands) - 1]
	var lengths: Dictionary = b.get("length_m", {})
	var lo: float = float(lengths.get("min", 0.0))
	var hi: float = float(lengths.get("max", lo))
	var from_xp: float = float(b.get("xp_to_reach", 0.0))
	var to_xp: float = float(b.get("xp_full_length", from_xp))
	var t: float = clampf((xp - from_xp) / (to_xp - from_xp), 0.0, 1.0) if to_xp > from_xp else 1.0
	if lo <= 0.0 or hi <= lo:
		return lerpf(lo, hi, t)
	return lo * pow(hi / lo, t)


## 1-based band whose length range contains `length_m` (max inclusive, so a shared boundary belongs to the lower
## band; NPCs use it for bite power and the swim tables); clamped to the first / last band, 1 without bands.
static func band_for_length(length_m: float, bands: Array) -> int:
	for i in bands.size():
		var lengths: Dictionary = bands[i].get("length_m", {})
		if length_m <= float(lengths.get("max", INF)):
			return i + 1
	return maxi(bands.size(), 1)


## Hunger lost per tick: full (hunger_max) to empty in full_to_empty_s seconds, scaled by the band's hunger_drain_mult.
static func hunger_drain_per_tick(hunger_max: float, full_to_empty_s: float, band_mult: float, tick_dt: float) -> float:
	if full_to_empty_s <= 0.0:
		return 0.0
	return hunger_max / full_to_empty_s * band_mult * tick_dt


## Hunger restored by eating something worth `xp` (before XP falloff: hunger tracks food, not progression).
static func hunger_from_xp(xp: float, hunger_per_xp: float) -> float:
	return xp * hunger_per_xp


## True when `point` is inside the mouth cone of a fish at `origin` facing unit `heading`: within `reach` and within
## the half-angle whose cosine is `cos_half` (a point at the origin counts as inside).
static func in_cone(origin: Vector3, heading: Vector3, point: Vector3, reach: float, cos_half: float) -> bool:
	var to: Vector3 = point - origin
	var d2: float = to.length_squared()
	if d2 > reach * reach:
		return false
	if d2 < 1e-12:
		return true
	return heading.dot(to) >= cos_half * sqrt(d2)


## Bite check (SimWorld bite resolution and NpcBrain use the same test): the target's centre is within
## reach + its collision `radius` (a big body can be bitten before its centre is in reach) and the direction to the
## centre is within the half-angle `half_rad` of `heading` (a centre at the origin counts as inside).
static func sphere_in_cone(origin: Vector3, heading: Vector3, center: Vector3, radius: float, reach: float, half_rad: float) -> bool:
	return in_cone(origin, heading, center, reach + maxf(radius, 0.0), cos(half_rad))

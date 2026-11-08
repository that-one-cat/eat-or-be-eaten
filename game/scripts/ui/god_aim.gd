class_name GodAim
extends RefCounted
## The "crosshair" of the God spawn commands (the game has none): a terrain-clipped ray from the player along the aim
## direction. Pure and static (read-only on the world), so a plain SimWorld can test it.
##
## aim_point(): distance = clamp(REACH_LENGTHS * player.length_m, MIN_REACH_M, MAX_REACH_M); the ray is marched in
## MARCH_STEPS fixed steps and stops at the first step that is in the seabed, inside an obstacle (CLEARANCE_M margin),
## above the surface or outside the map box; the result is the last free point (the player's own position at worst).

const REACH_LENGTHS: float = 12.0
const MIN_REACH_M: float = 3.0
const MAX_REACH_M: float = 40.0
const MARCH_STEPS: int = 40
## Free space kept around the returned point (so a spawned fish does not start inside a rock).
const CLEARANCE_M: float = 0.6


## Distance the aim ray travels for a player of `length_m`.
static func reach_m(length_m: float) -> float:
	return clampf(REACH_LENGTHS * length_m, MIN_REACH_M, MAX_REACH_M)


## `dir` need not be normalised; a zero / non-finite `dir` falls back to the player's heading.
static func aim_point(world: SimWorld, player: SimEntity, dir: Vector3) -> Vector3:
	var d: Vector3 = dir if dir.is_finite() and not dir.is_zero_approx() else player.heading
	d = d.normalized() if not d.is_zero_approx() else Vector3.FORWARD
	var origin: Vector3 = player.position
	var step: float = reach_m(player.length_m) / float(MARCH_STEPS)
	var last: Vector3 = origin
	for i in range(1, MARCH_STEPS + 1):
		var p: Vector3 = origin + d * (step * float(i))
		if _blocked(world, p):
			break
		last = p
	return last


static func _blocked(world: SimWorld, p: Vector3) -> bool:
	if p.y > -CLEARANCE_M:
		return true
	var half: float = float(world.map.get("size_m", 0.0)) * 0.5
	if half > 0.0 and (absf(p.x) > half - CLEARANCE_M or absf(p.z) > half - CLEARANCE_M):
		return true
	if world.seabed == null:
		return false
	return p.y < world.seabed.height_at(p.x, p.z) + CLEARANCE_M or not world.seabed.obstacle_clear(p, CLEARANCE_M)

class_name AimSmoothing
extends RefCounted
## Pure step of the `smoothed` control mode (T1.4, docs/data/controls.md): moves the aim direction sent in MOVE commands toward
## the raw mouse aim. Input layer only: no node, no sim state, no window needed (PlayerInput feeds it, tests call it directly).
##
## step(current, target, dt, tau, max_turn_deg_s): the direction turns along the great circle toward `target` by the fraction
## 1 - exp(-dt / tau) of the remaining angle (frame-rate independent: n small steps equal one big step; never overshoots;
## tau = time constant in seconds, after tau about 63% of the offset is gone). A positive `max_turn_deg_s` additionally caps
## the turn to max_turn_deg_s x dt per step (0 = no cap). tau <= 0 without a cap returns the target (passthrough); tau <= 0
## with a cap only turns at the cap; dt <= 0 returns the current direction. The result is always a finite unit vector.

## Hardest dt the maths is fed (a stalled frame): 1e12 s is "infinity" for every tau yet keeps dt / tau finite.
const MAX_DT_S: float = 1.0e12
## Remaining angle (radians) below which the target is taken as reached.
const SNAP_RAD: float = 1.0e-9


static func step(current: Vector3, target: Vector3, dt: float, tau: float, max_turn_deg_s: float = 0.0) -> Vector3:
	var cur: Vector3 = _unit(current, Vector3.FORWARD)
	var tar: Vector3 = _unit(target, cur)
	var cap_rad_s: float = deg_to_rad(max_turn_deg_s) if max_turn_deg_s > 0.0 and is_finite(max_turn_deg_s) else 0.0
	var time_const: float = 0.0 if is_nan(tau) else tau
	if time_const <= 0.0 and cap_rad_s <= 0.0:
		return tar
	if not (dt > 0.0):
		return cur
	var angle: float = cur.angle_to(tar)
	if angle < SNAP_RAD:
		return tar
	var turn: float = angle
	if time_const > 0.0:
		turn = angle * (1.0 - exp(-minf(dt, MAX_DT_S) / time_const))
	if cap_rad_s > 0.0:
		turn = minf(turn, cap_rad_s * minf(dt, MAX_DT_S))
	turn = minf(turn, angle)
	var axis: Vector3 = cur.cross(tar)
	if axis.length_squared() < 1.0e-18:  # exactly opposite (or equal): any axis perpendicular to `cur` will do
		axis = cur.cross(Vector3.UP)
		if axis.length_squared() < 1.0e-18:
			axis = cur.cross(Vector3.RIGHT)
	var out: Vector3 = cur.rotated(axis.normalized(), turn)
	return _unit(out, cur)


# `v` normalized; `fallback` (already a unit vector) when `v` is zero, tiny or not finite.
static func _unit(v: Vector3, fallback: Vector3) -> Vector3:
	if not v.is_finite() or not is_finite(v.length_squared()) or v.length_squared() < 1.0e-18:
		return fallback
	return v.normalized()

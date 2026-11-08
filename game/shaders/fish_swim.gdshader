// Fish swim: palette toon look + vertex swim (side-to-side, yaw around a pivot, body wave
// growing towards the tail; optional vertical wing flap for the ray archetype). Works on MeshInstance3D (incl. juvenile/adult blend shapes,
// which Godot applies before vertex()) and on MultiMeshInstance3D crowds.
//
// Mesh convention (tools/blender/README.md): unit body length along Z, nose towards -Z,
// origin at the centre of mass. All amplitudes are in body lengths, so the node scale
// (= fish length in metres) scales the motion with the fish.
//
// Per-fish phase: INSTANCE_CUSTOM.x in [0, 1) for MultiMesh (set use_custom_data before
// instance_count), plus the swim_phase instance uniform for single MeshInstance3D nodes.
// INSTANCE_CUSTOM.y in [-1, 1]: brightness tint (+-TINT_AMOUNT), 0 on single nodes.
//
// School wobble (ambient crowds, AmbientRenderer): with school_wobble_m > 0 every instance is
// offset in the school frame (the node or instance frame, -Z = school heading) by the same
// formula as SchoolSystem.member_wobble():
//   wobble = school_wobble_m * (sin(w t + a), 0.5 sin(1.7 w t + b), cos(w t + a)),
//   w = school_wobble_w, t = school_time (sim seconds, set per frame), a = TAU * INSTANCE_CUSTOM.z,
//   b = TAU * INSTANCE_CUSTOM.w. The instance scale (= fish length) is divided out, so the offset
//   is in metres. Promoted members take over at the sim slot without a visible jump. The
//   constants 0.5 / 1.7 mirror SchoolSystem._WOBBLE_Y / _WOBBLE_Y_FREQ. Off by default (0).
//
// Krill drift (AmbientRenderer krill swarms; uniforms copied from the KrillField, which evaluates the same
// offset in the sim so the krill a player swallows is the one drawn at its mouth): with drift_m > 0 every instance
// (basis = uniform scale = critter length, no rotation) is offset in world metres by
//   th = drift_w t + TAU w, side = (sin th, 0, cos th), u = weave_w s t + TAU z, s = 1 + 0.25 y,
//   offset = side * (drift_m + weave_m sin u) + up * bob_m sin(1.3 u + TAU x),
// t = school_time, (x, y, z, w) = INSTANCE_CUSTOM (phase, tint, weave phase, drift phase), and the body (nose -Z)
// is turned along d(offset)/dt. weave_m < drift_m keeps the forward speed positive (never swims backwards).
// Off by default (drift_m 0).
//
// Glow pulse (plankton swarm, M_Palette_PlanktonDrift): glow swatch + glow_body emission x
// (1 + glow_pulse_amp * sin(TAU * (glow_pulse_hz * TIME + INSTANCE_CUSTOM.x))). Off by default
// (amp 0, glow_body 0): the fish presets do not set them, so their look is unchanged.
shader_type spatial;
render_mode cull_back;

#define PALETTE_TINT
#define PALETTE_GLOW_PULSE
#include "res://shaders/palette_toon.gdshaderinc"

const float TINT_AMOUNT = 0.08;

group_uniforms swim;
/// Tail beat speed in radians per second.
uniform float swim_speed : hint_range(0.0, 30.0) = 7.0;
/// Whole-body sideways sway (body lengths).
uniform float side_amp : hint_range(0.0, 0.2) = 0.012;
/// Yaw swing around the pivot (radians).
uniform float yaw_amp : hint_range(0.0, 0.6) = 0.07;
/// Pivot of the yaw swing along Z (body lengths, head side is negative).
uniform float yaw_pivot_z : hint_range(-0.5, 0.5) = -0.2;
/// Body wave amplitude at the tail tip (body lengths).
uniform float wave_amp : hint_range(0.0, 0.3) = 0.07;
/// Wave number along the body (radians per body length).
uniform float wave_freq : hint_range(0.0, 20.0) = 5.0;
/// Amplitude curve exponent: 1 = linear towards the tail, 2 = mostly the tail.
uniform float wave_exp : hint_range(0.5, 4.0) = 1.8;
/// Z of the nose in mesh space (unit-length mesh, origin at the centre of mass, which sits
/// in front of the middle for big-headed fish: about -0.35 for the reef fish and the ray).
uniform float nose_z : hint_range(-1.0, 0.0) = -0.35;
/// Vertical wing flap at the wing tips (body lengths; rays use this instead of a tail wave).
uniform float flap_amp : hint_range(0.0, 0.3) = 0.0;
/// Half wingspan used to normalise the flap (body lengths).
uniform float flap_span : hint_range(0.05, 1.0) = 0.5;
group_uniforms;

group_uniforms school;
/// School wobble amplitude in metres (0 = off; rules schools.wobble_m on ambient crowds).
uniform float school_wobble_m = 0.0;
/// School wobble angular speed, rad/s (TAU * rules schools.wobble_hz).
uniform float school_wobble_w = 0.0;
/// Sim time in seconds the wobble is evaluated at (set every frame by the crowd renderer).
uniform float school_time = 0.0;
group_uniforms;

group_uniforms krill;
/// Cloud drift radius in metres (0 = off).
uniform float drift_m = 0.0;
/// Cloud drift angular speed, rad/s (the collective turn).
uniform float drift_w = 0.0;
/// Sideways weave of every critter, metres (keep below drift_m).
uniform float weave_m = 0.0;
/// Weave angular speed, rad/s (x 1 + 0.25 tint per critter).
uniform float weave_w = 0.0;
/// Vertical bob, metres.
uniform float bob_m = 0.0;
group_uniforms;

group_uniforms pulse;
/// Relative glow swing (0 = steady glow; 0.5 = glow between 0.5x and 1.5x).
uniform float glow_pulse_amp : hint_range(0.0, 1.0) = 0.0;
/// Pulses per second (phase offset per instance from INSTANCE_CUSTOM.x).
uniform float glow_pulse_hz : hint_range(0.0, 4.0) = 0.5;
group_uniforms;

instance uniform float swim_phase = 0.0;

void vertex() {
	float phase = TIME * swim_speed + INSTANCE_CUSTOM.x * TAU + swim_phase;
	float along = clamp(VERTEX.z - nose_z, 0.0, 1.0); // 0 = nose, 1 = tail tip

	// Body wave travelling from head to tail.
	VERTEX.x += wave_amp * pow(along, wave_exp) * sin(phase - along * wave_freq);

	// Yaw swing around a pivot near the head (head and tail swing opposite ways).
	float yaw = yaw_amp * sin(phase + 1.2);
	float c = cos(yaw);
	float s = sin(yaw);
	float dz = VERTEX.z - yaw_pivot_z;
	VERTEX.xz = vec2(VERTEX.x * c + dz * s, -VERTEX.x * s + dz * c + yaw_pivot_z);
	NORMAL.xz = vec2(NORMAL.x * c + NORMAL.z * s, -NORMAL.x * s + NORMAL.z * c);

	// Wing flap: grows towards the tips, travels outwards.
	float span = clamp(abs(VERTEX.x) / flap_span, 0.0, 1.0);
	VERTEX.y += flap_amp * span * span * sin(phase - span * 1.5);

	// Whole-body sway.
	VERTEX.x += side_amp * sin(phase + 2.4);

	// School wobble (metres in the school frame; the instance scale is the fish length).
	float wa = school_wobble_w * school_time + INSTANCE_CUSTOM.z * TAU;
	float wb = 1.7 * school_wobble_w * school_time + INSTANCE_CUSTOM.w * TAU;
	vec3 wobble = school_wobble_m * vec3(sin(wa), 0.5 * sin(wb), cos(wa));
	VERTEX += wobble / max(length(MODEL_MATRIX[0].xyz), 1e-4);

	// Krill drift (see the header): offset + heading along the velocity.
	if (drift_m > 0.0) {
		float sk = 1.0 + 0.25 * INSTANCE_CUSTOM.y;
		float th = drift_w * school_time + TAU * INSTANCE_CUSTOM.w;
		float u = weave_w * sk * school_time + TAU * INSTANCE_CUSTOM.z;
		float ub = 1.3 * u + TAU * INSTANCE_CUSTOM.x;
		vec3 side = vec3(sin(th), 0.0, cos(th));
		vec3 fwd = vec3(cos(th), 0.0, -sin(th));
		float r = drift_m + weave_m * sin(u);
		vec3 vel = fwd * (drift_w * r) + side * (weave_m * weave_w * sk * cos(u)) + vec3(0.0, bob_m * 1.3 * weave_w * sk * cos(ub), 0.0);
		vec3 f = normalize(vel);
		vec3 rt = normalize(cross(f, vec3(0.0, 1.0, 0.0)));
		mat3 rot = mat3(rt, cross(rt, f), -f);
		VERTEX = rot * VERTEX + (side * r + vec3(0.0, bob_m * sin(ub), 0.0)) / max(length(MODEL_MATRIX[0].xyz), 1e-4);
		NORMAL = rot * NORMAL;
	}

	v_tint = 1.0 + TINT_AMOUNT * INSTANCE_CUSTOM.y;
	v_glow = 1.0 + glow_pulse_amp * sin(TAU * (glow_pulse_hz * TIME + INSTANCE_CUSTOM.x));
}

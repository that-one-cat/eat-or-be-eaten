class_name SimRng
extends RefCounted
## Deterministic PRNG owned by the simulation (never the global RNG).
## Algorithm: PCG32 (XSH-RR variant, O'Neill 2014): 64-bit LCG state, fixed odd increment, 32-bit output.
## The whole generator state is one 64-bit int, so get_state()/set_state() round-trip exactly.
## GDScript ints are signed 64-bit and wrap on overflow (documented engine behaviour), which gives the
## mod 2^64 LCG step for free; logical right shifts are emulated with masks because `>>` is arithmetic.

const _MULT: int = 6364136223846793005
const _INC: int = 1442695040888963407  # odd stream constant (PCG reference default)
const _U32: int = 0xFFFFFFFF
const _TWO_POW_32: float = 4294967296.0

var _state: int = 0


func _init(p_seed: int = 0) -> void:
	# PCG reference seeding: step, add seed, step.
	_state = 0
	next_u32()
	_state += p_seed
	next_u32()


## Next value in [0, 2^32 - 1].
func next_u32() -> int:
	var old: int = _state
	_state = old * _MULT + _INC
	# logical shifts: (x >> n) & ((1 << (64 - n)) - 1)
	var xorshifted: int = ((((old >> 18) & 0x3FFFFFFFFFFF) ^ old) >> 27) & _U32
	var rot: int = (old >> 59) & 31
	return ((xorshifted >> rot) | (xorshifted << ((32 - rot) & 31))) & _U32


## Uniform float in [0, 1).
func next_float() -> float:
	return float(next_u32()) / _TWO_POW_32


## Uniform int in [lo, hi] (inclusive). Returns lo when hi <= lo. Span must not exceed 2^32 (modulo bias is negligible for small spans).
func range_int(lo: int, hi: int) -> int:
	if hi <= lo:
		return lo
	return lo + next_u32() % (hi - lo + 1)


## Uniform float in [lo, hi).
func range_float(lo: float, hi: float) -> float:
	return lo + (hi - lo) * next_float()


func get_state() -> int:
	return _state


func set_state(state: int) -> void:
	_state = state

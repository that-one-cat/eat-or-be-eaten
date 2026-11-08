extends SceneTree
## Data validation entry point.
## Usage: godot --headless --path game --script res://tests/validate_data.gd [-- --root=<data_dir>]
## Loads the data root (default res://data) through ContentDB, prints "DATA ERROR: <message>" per
## problem and exits 1, or prints "DATA: OK (<counts>)" and exits 0.


func _initialize() -> void:
	var root: String = "res://data"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.trim_prefix("--root=")

	var db := ContentDB.load_from_dir(root)
	if not db.is_valid():
		for e in db.errors:
			print("DATA ERROR: %s" % e)
		print("DATA: FAILED (%d errors in %s)" % [db.errors.size(), root])
		quit(1)
		return

	print("DATA: OK (%d species, %d bands, %d mutations, %d abilities, %d maps)" % [
		db.species_ids().size(), db.band_count(), db.mutation_ids().size(),
		db.ability_ids().size(), db.map_ids().size(),
	])
	quit(0)

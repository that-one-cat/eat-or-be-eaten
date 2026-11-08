# scripts/net - multiplayer (placeholder, stage 2)

Empty on purpose: single-player ships first. Design constraints already fixed (details: Vault `godot-multiplayer-and-steam`):

- Server-authoritative; host/listen server over Steam relay first (friend lobbies 4-8), dedicated headless Linux server later (16 players + NPC fish + AI "fake players").
- No `MultiplayerSynchronizer` per NPC fish. Players: custom quantized snapshots (about 20 Hz send, 30 Hz server tick). NPC schools: deterministic seeds + events.
- Interest management through the shared spatial grid in `scripts/sim/`.
- Web builds cannot host and have no ENet/UDP.

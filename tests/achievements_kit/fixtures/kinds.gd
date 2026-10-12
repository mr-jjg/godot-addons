extends RefCounted
## Test fixture: the trigger kinds the achievements_kit suite reports (shaped like a game's
## hand-written kinds file).

const KINDS := {
	&"boards_cleared": {
		"label": "Boards cleared (lifetime)",
		"mode": &"count",
		"doc": "The last block on the board broke.",
		"params": {},
	},
	&"round_reached": {
		"label": "Round reached in one run",
		"mode": &"max",
		"doc": "The round now being played.",
		"params": {
			"source": {"type": "enum", "values": ["", "quick_play", "curated"], "default": ""},
		},
	},
	&"unlock_earned": {
		"label": "Unlock earned",
		"mode": &"count",
		"doc": "An unlock was earned.",
		"params": {
			"unlock": {"type": "enum", "values": ["", "outer_wilds", "gold"], "default": ""},
		},
	},
	&"flags": {
		"label": "Flagged event",
		"mode": &"count",
		"doc": "Exercises every param type.",
		"params": {
			"tag": {"type": "string", "default": ""},
			"level": {"type": "int", "default": 0},
			"hard": {"type": "bool", "default": false},
		},
	},
}

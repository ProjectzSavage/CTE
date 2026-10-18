"""Generates src/Workspace/Arena.rbxmx -- the static party arena.

Layout (all studs, Y up), matching the Config.Arena* values:

  * Floor slab 128 x 128, top face at Y = 0.
  * Playable square = 120 x 120: four translucent boundary walls whose inner
    faces sit at +/-60 on X/Z (wall height 5, thickness 2).
  * Gold center pad (cylinder, diameter 12, non-collidable) marking the egg
    zone, plus an invisible EggSpawnPoint marker part at Y = 3. The future
    EggService reads Workspace.Arena.EggSpawnPoint for respawns.
  * 6 SpawnLocations on a hex ring at radius 48 (one per party color).

Everything is anchored, simple Parts -- visuals get polished later.
The file is regenerated on every `python3 tools/build_place.py` run, and Rojo
consumes the very same .rbxmx when syncing/building.
"""

from __future__ import annotations

import itertools
import math
import os

from rbxlx import Item, make_part, make_simple, make_spawn_location, wrap_roblox

# ---------------------------------------------------------------------------
# Arena dimensions -- KEEP IN SYNC WITH Config.Arena* (src/ReplicatedStorage/Modules/Config.lua)
# ---------------------------------------------------------------------------
FLOOR_SIZE = 128.0        # outer slab
PLAY_SIZE = 120.0         # playable square inside the walls
WALL_HEIGHT = 5.0
WALL_THICKNESS = 2.0
SPAWN_RADIUS = 48.0
SPAWN_COUNT = 6
PAD_DIAMETER = 12.0
PAD_THICKNESS = 0.4
EGG_SPAWN_HEIGHT = 3.0

# Palette
FLOOR_COLOR = (102, 108, 120)      # slate
WALL_COLOR = (80, 220, 255)        # bright cyan "energy" boundary
WALL_TRANSPARENCY = 0.35
PAD_COLOR = (255, 200, 60)         # gold egg zone
SPAWN_COLORS = [                   # six party colors
    (235, 80, 80),    # red
    (245, 155, 60),   # orange
    (250, 215, 80),   # yellow
    (95, 205, 100),   # green
    (80, 160, 240),   # blue
    (180, 110, 230),  # purple
]

SPAWN_SIZE = (6.0, 1.0, 6.0)


def build_arena() -> Item:
    """Builds the Arena model (returned as an rbxlx Item tree)."""
    arena = make_simple("Arena", "Model")

    # Floor slab: top face at Y = 0.
    arena.child(
        make_part(
            "Baseplate",
            size=(FLOOR_SIZE, 1.0, FLOOR_SIZE),
            pos=(0.0, -0.5, 0.0),
            color=FLOOR_COLOR,
        )
    )

    # Boundary walls: inner faces at +/- PLAY_SIZE/2. North/south walls span
    # the full width plus the east/west thickness so the corners are closed.
    half = PLAY_SIZE / 2.0
    wall_y = WALL_HEIGHT / 2.0
    long_len = PLAY_SIZE + 2 * WALL_THICKNESS
    arena.child(make_part(
        "BoundaryNorth",
        size=(long_len, WALL_HEIGHT, WALL_THICKNESS),
        pos=(0.0, wall_y, half + WALL_THICKNESS / 2.0),
        color=WALL_COLOR, transparency=WALL_TRANSPARENCY,
    ))
    arena.child(make_part(
        "BoundarySouth",
        size=(long_len, WALL_HEIGHT, WALL_THICKNESS),
        pos=(0.0, wall_y, -(half + WALL_THICKNESS / 2.0)),
        color=WALL_COLOR, transparency=WALL_TRANSPARENCY,
    ))
    arena.child(make_part(
        "BoundaryEast",
        size=(WALL_THICKNESS, WALL_HEIGHT, PLAY_SIZE),
        pos=(half + WALL_THICKNESS / 2.0, wall_y, 0.0),
        color=WALL_COLOR, transparency=WALL_TRANSPARENCY,
    ))
    arena.child(make_part(
        "BoundaryWest",
        size=(WALL_THICKNESS, WALL_HEIGHT, PLAY_SIZE),
        pos=(-(half + WALL_THICKNESS / 2.0), wall_y, 0.0),
        color=WALL_COLOR, transparency=WALL_TRANSPARENCY,
    ))

    # Center pad: cylinder whose local X axis (the cylinder axis) is rotated
    # to point up: CFrame.Angles(0, 0, 90deg). Non-collidable decoration.
    rot_z90 = ((0, -1, 0), (1, 0, 0), (0, 0, 1))
    arena.child(make_part(
        "CenterPad",
        size=(PAD_THICKNESS, PAD_DIAMETER, PAD_DIAMETER),
        pos=(0.0, 0.0, 0.0),
        rot=rot_z90,
        color=PAD_COLOR,
        can_collide=False,
        shape=2,  # Enum.PartType.Cylinder
    ))

    # Invisible marker: where EggService (later) respawns the egg after it
    # leaves the arena. Found via Workspace.Arena:FindFirstChild("EggSpawnPoint").
    arena.child(make_part(
        "EggSpawnPoint",
        size=(1.0, 1.0, 1.0),
        pos=(0.0, EGG_SPAWN_HEIGHT, 0.0),
        transparency=1.0,
        can_collide=False,
    ))

    # Six spawn pads on a hex ring around the edge.
    for i in range(SPAWN_COUNT):
        angle = 2 * math.pi * i / SPAWN_COUNT
        x = SPAWN_RADIUS * math.cos(angle)
        z = SPAWN_RADIUS * math.sin(angle)
        arena.child(make_spawn_location(
            f"Spawn{i + 1}",
            size=SPAWN_SIZE,
            pos=(x, SPAWN_SIZE[1] / 2.0, z),
            color=SPAWN_COLORS[i % len(SPAWN_COLORS)],
        ))

    return arena


def write_rbxmx(path: str) -> str:
    """Serializes the arena to an .rbxmx file and returns the XML text."""
    xml = wrap_roblox(build_arena().serialize(itertools.count()))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(xml)
    return xml


def extract_first_item(xml_text: str) -> str:
    """Returns the raw XML of the first top-level <Item> block in a roblox file."""
    start = xml_text.index("<Item")
    end = xml_text.rindex("</Item>") + len("</Item>")
    return xml_text[start:end]


if __name__ == "__main__":
    import sys
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(repo_root, "src", "Workspace", "Arena.rbxmx")
    write_rbxmx(out)
    print(f"Wrote {out} ({os.path.getsize(out)} bytes)", file=sys.stdout)

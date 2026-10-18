"""Builds ClutchTheEgg.rbxlx -- a runnable Roblox place file -- from source.

Inputs (single source of truth):
  * default.project.json : structure manifest (Rojo project format subset:
                           $className / $path / nested named children).
  * src/**/*.lua         : script sources. Instance kind is inferred exactly
                           like Rojo:  *.server.lua -> Script,
                                       *.client.lua -> LocalScript,
                                       *.lua        -> ModuleScript.
                           The instance name is the filename stem.
  * src/Workspace/Arena.rbxmx : static arena, regenerated first by this script
                           (see tools/gen_arena.py).

Usage:
    python3 tools/build_place.py            # -> ClutchTheEgg.rbxlx at repo root
    python3 tools/build_place.py -o X.rbxlx

Pure Python, no Roblox/Rojo install required. If you use Rojo locally you can
ignore this script entirely: `rojo build` / `rojo serve` consume the same
manifest and sources.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gen_arena  # noqa: E402
from rbxlx import Item, RawXml, make_script, make_simple, serialize_tree, wrap_roblox  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

LUA_SUFFIXES = (".lua", ".luau")


def script_kind(filename: str) -> tuple[str, str]:
    """Returns (Script/LocalScript/ModuleScript, instance name) for a lua file."""
    stem = filename
    for suffix in LUA_SUFFIXES:
        if stem.endswith(suffix):
            stem = stem[: -len(suffix)]
            break
    else:
        raise ValueError(f"Not a Lua source file: {filename}")

    if stem.endswith(".server"):
        return "Script", stem[: -len(".server")]
    if stem.endswith(".client"):
        return "LocalScript", stem[: -len(".client")]
    if stem.endswith(".shared"):
        return "ModuleScript", stem[: -len(".shared")]
    return "ModuleScript", stem


def read_source(path: str) -> str:
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def materialize_path(dir_path: str) -> list[Item | RawXml]:
    """Turns a source directory into Rojo-style children (deterministic order)."""
    children: list[Item | RawXml] = []
    for entry in sorted(os.listdir(dir_path), key=str.lower):
        full = os.path.join(dir_path, entry)
        if os.path.isdir(full):
            folder = make_simple(entry, "Folder")
            for sub in materialize_path(full):
                folder.child(sub)
            children.append(folder)
        elif entry.endswith(LUA_SUFFIXES):
            cls, name = script_kind(entry)
            children.append(make_script(name, cls, read_source(full)))
        elif entry.endswith(".rbxmx") or entry.endswith(".rbxmx.xml"):
            xml_text = read_source(full)
            children.append(RawXml(gen_arena.extract_first_item(xml_text)))
        elif entry.endswith(".meta.json") or entry == ".gitkeep":
            continue  # Rojo metadata / placeholders: nothing to emit
        else:
            raise ValueError(f"Don't know how to sync file: {full}")
    return children


def build_item(name: str, node: dict) -> Item:
    """Builds one manifest node (dict) into an Item tree."""
    class_name = node.get("$className", "Folder")
    item = make_simple(name, class_name)

    if "$properties" in node:
        raise NotImplementedError("$properties is not supported by this builder")

    if "$path" in node:
        for child in materialize_path(os.path.join(REPO_ROOT, node["$path"])):
            item.child(child)

    for key, value in node.items():
        if key.startswith("$"):
            continue
        if not isinstance(value, dict):
            raise ValueError(f"Manifest node '{name}.{key}' must be an object")
        item.child(build_item(key, value))

    return item


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "-o", "--output",
        default=os.path.join(REPO_ROOT, "ClutchTheEgg.rbxlx"),
        help="output place file path",
    )
    args = parser.parse_args()

    # 1) Regenerate the arena model so rbxmx + place never drift apart.
    arena_path = os.path.join(REPO_ROOT, "src", "Workspace", "Arena.rbxmx")
    gen_arena.write_rbxmx(arena_path)
    print(f"arena      : {os.path.relpath(arena_path, REPO_ROOT)} regenerated")

    # 2) Load the manifest and build every top-level service.
    with open(os.path.join(REPO_ROOT, "default.project.json"), "r", encoding="utf-8") as fh:
        project = json.load(fh)

    tree = project["tree"]
    if tree.get("$className") != "DataModel":
        raise ValueError("default.project.json root must be a DataModel")

    services = [build_item(name, node) for name, node in tree.items() if not name.startswith("$")]

    # 3) Serialize the place file.
    place_xml = wrap_roblox(serialize_tree(services))

    # 4) Validate: well-formed XML + a few structural assertions.
    root = ET.fromstring(place_xml)
    problems = validate(root)
    if problems:
        for problem in problems:
            print(f"VALIDATION FAILED: {problem}", file=sys.stderr)
        return 1

    with open(args.output, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(place_xml)
    print(f"place file : {os.path.relpath(args.output, REPO_ROOT)} written "
          f"({os.path.getsize(args.output)} bytes)")

    print("\nDataModel contents:")
    print_tree(root, indent=1)
    return 0


EXPECTED_REMOTES = [
    "RequestAttack", "RequestThrow", "RequestDash", "RequestBlockStart", "RequestBlockEnd",
    "EggPossessionChanged", "HoldTimeUpdated", "MatchStateChanged", "RoundEnded",
    "MatchEnded", "FeedbackEvent", "DebugCommand",
]


def validate(root: ET.Element) -> list[str]:
    """Structural checks against the Task-1 acceptance list."""
    problems: list[str] = []

    def find(path: list[tuple[str, str | None]]) -> ET.Element | None:
        node: ET.Element | None = root
        for cls, name in path:
            found = None
            for item in node.findall("Item"):  # type: ignore[union-attr]
                if item.get("class") != cls:
                    continue
                if name is not None:
                    prop = item.find("./Properties/string[@name='Name']")
                    if prop is None or prop.text != name:
                        continue
                found = item
                break
            if found is None:
                return None
            node = found
        return node

    # All 11 RemoteEvents exist under ReplicatedStorage.Remotes
    remotes_folder = find([("ReplicatedStorage", None), ("Folder", "Remotes")])
    if remotes_folder is None:
        problems.append("ReplicatedStorage/Remotes folder missing")
    else:
        present = {
            item.find("./Properties/string[@name='Name']").text
            for item in remotes_folder.findall("Item")
            if item.get("class") == "RemoteEvent"
        }
        for remote in EXPECTED_REMOTES:
            if remote not in present:
                problems.append(f"RemoteEvent missing: {remote}")

    # Config ModuleScript exists and carries key tunables
    config = find([("ReplicatedStorage", None), ("Folder", "Modules"), ("ModuleScript", "Config")])
    if config is None:
        problems.append("ReplicatedStorage/Modules/Config ModuleScript missing")
    else:
        source = config.find("./Properties/ProtectedString[@name='Source']").text or ""
        for needle in ("WalkSpeed = 16", "CarrySpeed = 12", "AttackRange = 5",
                       "AttackKnockback = 25", "AttackCooldown = 0.6", "ThrowSpeed = 60",
                       "BlockKnockbackReduction = 0.6", "BlockSpeedMultiplier = 0.5",
                       "BlockStaminaDrain = 15", "RoundLength = 75", "RoundsPerMatch = 3",
                       "EggRespawnDelay = 3", "MaxPlayers = 6"):
            if needle not in source:
                problems.append(f"Config.lua missing tunable: {needle}")

    # Server services + bootstrap
    sss = find([("ServerScriptService", None)])
    if sss is None:
        problems.append("ServerScriptService missing")
    else:
        names = {
            item.find("./Properties/string[@name='Name']").text: item.get("class")
            for item in sss.findall("Item")
        }
        if names.get("Main") != "Script":
            problems.append("ServerScriptService/Main must be a Script")
        for service in ("MatchService", "EggService", "CombatService", "ScoringService", "DataService"):
            if names.get(service) != "ModuleScript":
                problems.append(f"ServerScriptService/{service} must be a ModuleScript")

    # Client input stub
    client_input = find([("StarterPlayer", None), ("StarterCharacterScripts", None),
                         ("LocalScript", "ClientInput")])
    if client_input is None:
        problems.append("StarterCharacterScripts/ClientInput LocalScript missing")

    # Arena: model, 6 spawns, egg marker
    arena = find([("Workspace", None), ("Model", "Arena")])
    if arena is None:
        problems.append("Workspace/Arena model missing")
    else:
        spawns = [i for i in arena.findall("Item") if i.get("class") == "SpawnLocation"]
        if len(spawns) != 6:
            problems.append(f"expected 6 SpawnLocations, found {len(spawns)}")
        names = {
            item.find("./Properties/string[@name='Name']").text
            for item in arena.findall("Item")
        }
        for required in ("Baseplate", "BoundaryNorth", "BoundarySouth", "BoundaryEast",
                         "BoundaryWest", "CenterPad", "EggSpawnPoint"):
            if required not in names:
                problems.append(f"Workspace/Arena/{required} missing")

    return problems


def print_tree(node: ET.Element, indent: int = 0) -> None:
    for item in node.findall("Item"):
        cls = item.get("class")
        prop = item.find("./Properties/string[@name='Name']")
        name = prop.text if prop is not None else "?"
        print(f"{'    ' * indent}- {name} ({cls})")
        print_tree(item, indent + 1)


if __name__ == "__main__":
    raise SystemExit(main())

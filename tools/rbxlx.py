"""Tiny writer for Roblox place/model XML (.rbxlx / .rbxmx, format version 4).

Only the pieces Clutch the Egg needs are implemented: services, folders,
models, parts / spawn locations, Script / LocalScript / ModuleScript and
RemoteEvent. Property serialization mirrors what Roblox Studio itself writes:

  * Part.Size   -> <Vector3 name="size">        (yes, lowercase "size")
  * Part.Shape  -> <token name="shape">         (lowercase "shape"; Ball=0, Block=1, Cylinder=2)
  * CFrame      -> <CoordinateFrame name="CFrame"> with X/Y/Z + R00..R22
  * Colors      -> <Color3uint8 name="Color3uint8"> (0xAARRGGBB, alpha always 255)
  * Sources     -> <ProtectedString name="Source"><![CDATA[...]]></ProtectedString>
"""

from __future__ import annotations

import itertools
import re
from typing import Iterable, Sequence

REFERENT_RE = re.compile(r'referent="RBX\d+"')

# Roblox place-file root element, exactly as Studio writes it.
ROBLOX_ROOT_OPEN = (
    '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
    'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">'
)
ROBLOX_ROOT_CLOSE = "</roblox>"

# Identity rotation matrix (rows R00..R22).
IDENTITY_ROT: Sequence[Sequence[float]] = ((1, 0, 0), (0, 1, 0), (0, 0, 1))


def _esc(text: str) -> str:
    """Escape text for a plain XML text node."""
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def _fmt(value: float) -> str:
    """Format a number the way Studio does (ints stay clean, floats keep precision)."""
    if isinstance(value, int):
        return str(value)
    if float(value).is_integer():
        return str(int(value))
    return f"{value:.10g}"


class Item:
    """One <Item class="..."> element with properties and children."""

    def __init__(self, class_name: str):
        self.class_name = class_name
        self._props: list[str] = []
        self.children: list["Item | RawXml"] = []

    # -- property helpers (each appends one serialized <prop> line) --------
    def string(self, name: str, value: str) -> "Item":
        self._props.append(f'<string name="{name}">{_esc(value)}</string>')
        return self

    def bool(self, name: str, value: bool) -> "Item":
        self._props.append(f'<bool name="{name}">{"true" if value else "false"}</bool>')
        return self

    def int(self, name: str, value: int) -> "Item":
        self._props.append(f'<int name="{name}">{int(value)}</int>')
        return self

    def float(self, name: str, value: float) -> "Item":
        self._props.append(f'<float name="{name}">{_fmt(value)}</float>')
        return self

    def token(self, name: str, value: int) -> "Item":
        self._props.append(f'<token name="{name}">{int(value)}</token>')
        return self

    def color3uint8(self, name: str, rgb: tuple[int, int, int]) -> "Item":
        r, g, b = rgb
        packed = (255 << 24) | (r << 16) | (g << 8) | b
        self._props.append(f'<Color3uint8 name="{name}">{packed}</Color3uint8>')
        return self

    def vector3(self, name: str, xyz: tuple[float, float, float]) -> "Item":
        x, y, z = xyz
        self._props.append(
            f'<Vector3 name="{name}"><X>{_fmt(x)}</X><Y>{_fmt(y)}</Y><Z>{_fmt(z)}</Z></Vector3>'
        )
        return self

    def cframe(
        self,
        name: str,
        pos: tuple[float, float, float],
        rot: Sequence[Sequence[float]] = IDENTITY_ROT,
    ) -> "Item":
        x, y, z = pos
        rows = "".join(
            f"<R{r}{c}>{_fmt(rot[r][c])}</R{r}{c}>" for r in range(3) for c in range(3)
        )
        self._props.append(
            f'<CoordinateFrame name="{name}">'
            f"<X>{_fmt(x)}</X><Y>{_fmt(y)}</Y><Z>{_fmt(z)}</Z>{rows}"
            f"</CoordinateFrame>"
        )
        return self

    def physical_properties_default(self) -> "Item":
        self._props.append(
            '<PhysicalProperties name="CustomPhysicalProperties">'
            "<CustomPhysics>false</CustomPhysics></PhysicalProperties>"
        )
        return self

    def protected_string(self, name: str, value: str) -> "Item":
        # CDATA-safe: split any "]]>" occurring in the source.
        body = value.replace("]]>", "]]]]><![CDATA[>")
        self._props.append(
            f'<ProtectedString name="{name}"><![CDATA[{body}]]></ProtectedString>'
        )
        return self

    # -- structure ----------------------------------------------------------
    def set_name(self, name: str) -> "Item":
        return self.string("Name", name)

    def child(self, item: "Item | RawXml") -> "Item":
        self.children.append(item)
        return item

    def serialize(self, counter: Iterable[int]) -> str:
        referent = f"RBX{next(counter)}"  # type: ignore[arg-type]
        parts = [f'<Item class="{self.class_name}" referent="{referent}">', "<Properties>"]
        parts.extend(f"\t{p}" for p in self._props)
        parts.append("</Properties>")
        for child in self.children:
            parts.append(child.serialize(counter))
        parts.append("</Item>")
        return "\n".join(parts)


class RawXml:
    """Pre-serialized XML (used to embed Arena.rbxmx verbatim).

    Referent ids must be unique across the whole place file, so any
    referent="RBXn" attributes inside the raw block are renumbered to
    continue the host document's sequence when serialized.
    """

    def __init__(self, xml: str):
        self._xml = xml

    def serialize(self, counter: Iterable[int]) -> str:
        def renumber(_match: "re.Match[str]") -> str:
            return f'referent="RBX{next(counter)}"'  # type: ignore[arg-type]

        return REFERENT_RE.sub(renumber, self._xml)


def wrap_roblox(inner: str) -> str:
    return f"{ROBLOX_ROOT_OPEN}\n{inner}\n{ROBLOX_ROOT_CLOSE}\n"


# ---------------------------------------------------------------------------
# Convenience builders for the instance kinds this project uses
# ---------------------------------------------------------------------------

def make_part(
    name: str,
    *,
    cls: str = "Part",
    size: tuple[float, float, float],
    pos: tuple[float, float, float],
    rot: Sequence[Sequence[float]] = IDENTITY_ROT,
    color: tuple[int, int, int] = (200, 200, 200),
    transparency: float = 0.0,
    anchored: bool = True,
    can_collide: bool = True,
    shape: int | None = 1,  # Enum.PartType: Ball=0, Block=1, Cylinder=2
) -> Item:
    part = Item(cls)
    part.bool("Anchored", anchored)
    part.bool("CanCollide", can_collide)
    part.cframe("CFrame", pos, rot)
    part.color3uint8("Color3uint8", color)
    part.physical_properties_default()
    part.string("Name", name)
    if shape is not None:
        part.token("shape", shape)
    part.vector3("size", size)
    part.float("Transparency", transparency)
    return part


def make_spawn_location(
    name: str,
    *,
    size: tuple[float, float, float],
    pos: tuple[float, float, float],
    color: tuple[int, int, int],
) -> Item:
    spawn = make_part(name, cls="SpawnLocation", size=size, pos=pos, color=color)
    spawn.bool("AllowTeamChangeOnTouch", False)
    spawn.int("Duration", 10)  # standard spawn forcefield, same as Studio default
    spawn.bool("Enabled", True)
    spawn.bool("Neutral", True)  # not tied to any team
    return spawn


def make_script(name: str, cls: str, source: str) -> Item:
    """cls is one of Script / LocalScript / ModuleScript."""
    script = Item(cls)
    if cls != "ModuleScript":
        script.bool("Disabled", False)
    script.string("Name", name)
    script.protected_string("Source", source)
    return script


def make_simple(name: str, cls: str) -> Item:
    """Named instance with no other properties (Folder, RemoteEvent, services...)."""
    return Item(cls).set_name(name)


def serialize_tree(root_items: Sequence[Item]) -> str:
    counter = itertools.count()
    return "\n".join(item.serialize(counter) for item in root_items)

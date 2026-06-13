# PassWithoutATrace

A Windower addon for Final Fantasy XI that automates Sneak and Invisible for your entire party across multiple characters.

## How It Works

The addon runs on every character in the party. When triggered, it collects each character's job, level, known spells, items, and buffs, then picks the best strategy:

1. **Scholar AoE** -- If a SCH with Accession is available and has stratagem charges, they cast Accession + Sneak and Accession + Invisible.
2. **Multi-Caster Round Robin** -- If multiple characters can cast Sneak/Invisible (WHM, RDM, SCH at sufficient level), they split the work between them.
3. **Single Caster, Items On** -- Characters use items if available, caster handles all other targets sequentially.
4. **Single Caster, Items off** -- Single caster casts on everyone sequentially. 
4. **Spectral Jig** -- DNC characters (main or sub, level 25+) use Spectral Jig for themselves when they can't cast.
5. **Items** -- Non-casters with Silent Oil and Prism Powder use those items. Characters without items and without an available caster alert that they can't sneak/invisible.

## Commands

All commands use the prefix `//pwat` (or `//passwithoutatrace`).

| Command | Description |
|---|---|
| `//pwat` | Sneak and Invisible the whole party |
| `//pwat items [on\off]` | Toggle item usage (default: ON) |
| `//pwat jig [on\off]` | Toggle Spectral Jig usage (default: ON) |
| `//pwat status` | Show the cached state of all party members |
| `//pwat cancel` | Cancel all pending actions on all characters |
| `//pwat help` | Show in-game help |

## Examples

### Example 1: SCH/RDM + 3 DPS

**Party:**
- Character A: SCH/RDM (level 99) with Accession and 2+ stratagem charges
- Character B: SAM/WAR (has Silent Oil + Prism Powder)
- Character C: THF/NIN (has Silent Oil + Prism Powder)
- Character D: MNK/WAR (no items)

**Result:** Scholar AoE strategy. Character A uses Light Arts, Accession, casts Sneak on self, then Accession again and casts Invisible on self.

### Example 2: WHM/SCH + RDM/DNC + 2 DPS

**Party:**
- Character A: WHM/SCH (level 75, no Accession since sub-SCH is capped)
- Character B: RDM/DNC (level 75, has Spectral Jig but also can cast)
- Character C: BLU/NIN (has Silent Oil + Prism Powder)
- Character D: WAR/SAM (no items)

**Result:** Multi-caster round robin. Character B is not assigned to Spectral Jig because they can cast. With items ON, Character C uses Silent Oil + Prism Powder. Character D is the only cast target, so the two casters split minimal work: one caster handles Character D's Sneak and Invisible, both casters handle their own buffs.

### Example 3: DNC/NIN + 2 melee (no casters)

**Party:**
- Character A: DNC/WAR (level 99, has Spectral Jig)
- Character B: THF/WAR (has Silent Oil + Prism Powder)
- Character C: BST/DNC (level 30 sub, below Spectral Jig threshold, has Silent Oil + Prism Powder)

**Result:** Character A uses Spectral Jig. With items ON, Characters B and C each use their own Silent Oil and Prism Powder.

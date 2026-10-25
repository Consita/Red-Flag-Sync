# Red Flag Sync

Adds **guild lists** to [Red Flag](https://www.curseforge.com/wow/addons/red-flag) and shares them
with your guild members. For World of Warcraft **TBC Anniversary**.

Red Flag on its own is a personal blacklist. Red Flag Sync adds a second list per guild that every
guild member running Red Flag Sync sees and can add to – with the same private warnings, tooltips
and personal notes as your personal list.

## Requirements
- [Red Flag](https://www.curseforge.com/wow/addons/red-flag) (CurseForge)
- [Ace3](https://www.curseforge.com/wow/addons/ace3)

## Installation
**WowUp:** *Get Addons* → *Install from URL* → paste `https://github.com/Consita/Red-Flag-Sync`

**Manually:** download `RedFlagSync-x.y.zip` from the latest
[release](https://github.com/Consita/Red-Flag-Sync/releases) and extract it into
`World of Warcraft\_anniversary_\Interface\AddOns\` (you should end up with an `AddOns\RedFlagSync` folder).

Restart the game completely after installing.

## What you get
- **Guild tabs** in the Red Flag window (`/rf`): *Players* and *Guilds* of your guild's list, next to
  *My Players* and *My Guilds* (your personal list).
- **Share with Guild** copies a personal entry to the guild list, **Add to Personal** does the reverse.
- **Community notes** on guild-list entries, shared with your guild. Your personal notes stay private.
- **One list per guild** – alts in other guilds have their own list and never see or send yours.

## Sync & privacy
- Syncs **only with members of your own guild** who run Red Flag Sync, in the background –
  nothing is ever posted in chat and flagged players are never contacted.
- **Both sides check** every message against the current guild roster and the rank settings:
  - *Share my list with* – who your client sends the list to
  - *Accept changes from* – whose additions, edits and removals your client takes in

  e.g. *All ranks* / *Officer & above*: everyone gets warned, only officers can edit.
  These are per-player settings – every client applies its own.
- Changes sync instantly; on login you catch up on everything you missed.
- Your **personal list and personal notes are never sent**.
- When **none of your characters is in a guild anymore**, that guild's list is deleted automatically.
  Use *Add to Personal* first for anything you want to keep.

## Commands
| Command | |
|---|---|
| `/rfs` | Open the Red Flag Sync settings |
| `/rfs sync` | Request a sync from online guild members |
| `/rfs list` | Open the guild list |

## Compatibility
Red Flag Sync only uses Red Flag's stable add-on interface (`RedFlagAPI` version 1), so it keeps
working when Red Flag is updated.

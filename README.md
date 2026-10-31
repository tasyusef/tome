# Tome

Tome puts the same row of tabs on the windows you open most in World of Warcraft: Forever. Character, Spellbook, Talents, Guild, Collections and Group Finder all get it, so getting from one to another takes one click instead of hunting for the right button. There's a Bags tab as well, which opens your bags next to whatever you have up.

It works in combat. The tabs never open anything themselves. They press the same buttons Blizzard's own menu bar uses, and the game is fine with that mid-fight.

## Installing

Put the `Tome` folder in `_forever_/Interface/AddOns`, inside your World of Warcraft folder. On a Mac that's:

`/Applications/World of Warcraft/_forever_/Interface/AddOns/Tome`

If `Interface` or `AddOns` aren't there yet, just make them. If you downloaded this from GitHub, check the folder is called exactly `Tome`, since the game wants it to match `Tome.toc`. Then restart the game.

## Using it

Open any of those windows and the tabs are along the top. Click one to jump to that window.

It's worth setting a key for it under Options, Keybindings, Tome. That key closes whatever's open, and pressing it again brings back the last tab you were on.

If you'd rather have the tabs down the right side, type `/tome side`, and `/tome top` puts them back. You can also click the little gear at the end of the tabs, or find Tome under Options, AddOns. Each character remembers its own choice.

## Good to know

- Guild, Collections, Group Finder and Talents don't load until the first time you open them. If that first time is in the middle of a fight, their tabs show up once combat ends.
- Tome doesn't resize anything. Resizing windows in combat is exactly what the game blocks, so every window keeps its usual size.
- Side tabs go on the right, under Blizzard's own tabs, because a few windows already use that edge.
- Moving the tabs between top and side waits until you're out of combat.

## Trying it out

Open your character sheet and click through every tab, including Bags. Then go hit a training dummy and do it again, keybind included. Nothing should complain, and you shouldn't see any "action blocked" messages.

If something breaks, type `/console scriptErrors 1` and then `/reload` so errors show up on screen, and send me a screenshot.

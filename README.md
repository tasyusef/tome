# Tome

Tome puts the same row of tabs on the windows you open most in World of Warcraft: Forever. Character, Spellbook, Talents, Guild, Collections and Group Finder all get it, so getting from one to another takes one click instead of hunting for the right button. Your bags are a tab too, with every bag in one window.

They all open in the bottom right corner, where the game puts your bags, and only one is up at a time, so it feels like a single window.

It works in combat. The tabs never open anything themselves. They press the same buttons Blizzard's own menu bar uses, and the game is fine with that mid-fight.

## Installing

Put the `Tome` folder in `_forever_/Interface/AddOns`, inside your World of Warcraft folder. On a Mac that's:

`/Applications/World of Warcraft/_forever_/Interface/AddOns/Tome`

If `Interface` or `AddOns` aren't there yet, just make them. If you downloaded this from GitHub, check the folder is called exactly `Tome`, since the game wants it to match `Tome.toc`. Then restart the game.

## Using it

Open any of those windows and the tabs are along the top. Click one to jump to that window. Your bag key (B) and the backpack button open the Bags tab, and Escape closes it.

It's worth setting a key for it under Options, Keybindings, Tome. That key closes whatever's open, and pressing it again brings back the last tab you were on.

If you'd rather have the tabs down the right side, type `/tome side`, and `/tome top` puts them back. You can also click the little gear at the end of the tabs, or find Tome under Options, AddOns. Each character remembers its own choice.

## Good to know

- Guild, Collections, Group Finder and Talents don't load until the first time you open them. If that first time is in the middle of a fight, their tabs show up once combat ends.
- Tome doesn't resize anything. Resizing windows in combat is exactly what the game blocks, so every window keeps its usual size.
- A tab goes grey when the game hasn't opened that window to you yet, like Talents before your first talent point or Group Finder before its level. Hover it to see why. Clicking it does nothing, so you stay on the window you're on.
- On a narrow window, like the small Spellbook, the top tabs drop their names and show just their icons. Hover one for its name.
- Side tabs go on the right, beside Blizzard's own tabs, because a few windows already use that edge. On a short window they shrink to fit.
- Moving the tabs between top and side waits until you're out of combat.
- A window you open in the middle of a fight opens in its usual spot and moves to the corner once combat ends. If you opened more than one, the newest stays and the rest close.
- The Bags tab works in combat, but the backpack and bag buttons on your action bar show the game's own bags until the fight is over. B always opens the Bags tab.
- While the Bags tab is open, Escape closes it before anything else.

## Trying it out

Open your character sheet and click through every tab, including Bags. Press B, use a potion from the Bags tab, and visit a vendor. Then go hit a training dummy and do it all again, keybinds included. Nothing should complain, and you shouldn't see any "action blocked" messages.

If something breaks, type `/console scriptErrors 1` and then `/reload` so errors show up on screen, then send me a screenshot or [open an issue](../../issues).

## License

Tome is free software. You can share it and change it under the GNU General Public License, version 3 or any later version. The full text is in [LICENSE](LICENSE).

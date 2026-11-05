# Tome

Tome puts one set of tabs beside every window the menu bar opens in World of Warcraft: Forever. Character, Professions, Spellbook, Talents, Legacy, Quest Log, Housing, Guild, Group Finder, Collections and the Adventure Guide all get them, so getting from one to another takes one click instead of hunting for the right button. Your bags are a tab too, with every bag in one window.

The tabs run down the left side and stay put. Whichever one you pick opens right beside them at its usual size, and only one is up at a time, so it feels like a single window.

It works in combat. The tabs never open anything themselves. They press the same buttons Blizzard's own menu bar uses, and the game is fine with that mid-fight.

## Installing

Put the `Tome` folder in `_forever_/Interface/AddOns`, inside your World of Warcraft folder. On a Mac that's:

`/Applications/World of Warcraft/_forever_/Interface/AddOns/Tome`

If `Interface` or `AddOns` aren't there yet, just make them. If you downloaded this from GitHub, check the folder is called exactly `Tome`, since the game wants it to match `Tome.toc`. Then restart the game.

## Using it

Open any of those windows and the tabs are down its left side. Click one to jump to that window. Your bag key (B) and the bag buttons on your action bar open the Bags tab, in combat too, and Escape closes it.

It's worth setting a key for it under Options, Keybindings, Tome. That key closes whatever's open, and pressing it again brings back the last tab you were on.

To move everything, drag a window by any empty spot, like its title bar, or drag the little gear under the tabs. Click the gear to lock them in place or put them back where they started. You can also type `/tome lock`, `/tome unlock` or `/tome reset`, or find Tome under Options, AddOns. Each character remembers its own spot.

## Good to know

- Most of these windows don't load until the first time you open them. If that first time is in the middle of a fight, their tabs show up once combat ends.
- The shop, the game menu and Help stay on the menu bar. They aren't windows Tome can put tabs on.
- A full screen world map stays where the game puts it, without tabs. Shrink it back down and it goes back beside them.
- Tome doesn't resize anything. Every window keeps its usual size, so a big one like the map reaches further across the screen than a small one like your character sheet.
- A tab goes grey when the game hasn't opened that window to you yet, like Talents before your first talent point or Group Finder before its level. Hover it to see why. Clicking it does nothing, so you stay on the window you're on.
- Moving the tabs waits until you're out of combat.
- If you open more than one window in the middle of a fight, the newest stays and the rest close.
- While the Bags tab is open, Escape closes it before anything else.

## Trying it out

Open your character sheet and click through every tab, including Bags. Press B, click your backpack button, use a potion from the Bags tab, and visit a vendor. Drag a window somewhere else and check the others open there too. Then go hit a training dummy and do it all again, keybinds included. Nothing should complain, and you shouldn't see any "action blocked" messages.

If something breaks, type `/console scriptErrors 1` and then `/reload` so errors show up on screen, then send me a screenshot or [open an issue](../../issues).

## License

Tome is free software. You can share it and change it under the GNU General Public License, version 3 or any later version. The full text is in [LICENSE](LICENSE).

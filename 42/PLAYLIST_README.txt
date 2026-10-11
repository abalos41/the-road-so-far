Customize the Station - Singleplayer

Normal use:
No setup is required. Enable the mod and play; the station uses the default
playlist included with The Road So Far FM. Do not run the BAT file unless you
want to customize the songs.
When a song starts, its title is sent as a short radio transmission.

Optional song customization:
All files are stored inside the mod folder:
media\sound\TheRoadSoFarFM\SingleplayerPlaylist

Generated sound registrations are stored in:
media\sound\TheRoadSoFarFM\SingleplayerPlaylist_Generated
Do not edit that folder manually.

1. Open the mod folder and go to 42\tools.
2. Run Build-SingleplayerPlaylist.bat once to initialize the folder and copy
   in any default songs that are not already there.
3. Add or remove .mp3 or .ogg files in SingleplayerPlaylist.
4. Run Build-SingleplayerPlaylist.bat again after every change.
5. Restart the game so Project Zomboid loads the registered sounds.

The custom playlist replaces the station's song list in singleplayer. The
rest of the mod's behavior remains unchanged.

Project Zomboid must register each sound at startup. Run the generator after
changing the files; adding or removing files alone is not enough. The
generator registers MP3 files without converting them and keeps OGG files
unchanged. Both formats are passed to the game's audio system.

The custom playlist is only used in singleplayer. Multiplayer keeps the
standard playlist and current synchronization behavior.

When a radio is turned off or tuned away from 99.6 MHz, its current playback
session ends. Tuning it back to the station starts a fresh shuffled sequence.

Important: the custom playlist folder is inside the Workshop mod. Back up
SingleplayerPlaylist before Steam updates the mod, in case the update replaces
locally added or removed files.

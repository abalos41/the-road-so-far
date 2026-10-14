No action is needed for normal use: The Road So Far FM plays its default playlist on 99.6 MHz.

Use this folder only if you want to create a separate custom playlist for
singleplayer. User Tracks FM broadcasts on 100.2 MHz and is not available in
multiplayer.

To add your music:
1. Copy your MP3 or OGG files into this UserTracks folder.
2. Run 42/tools/Build-SingleplayerPlaylist.bat.
3. Restart Project Zomboid so it loads the generated playlist and sound definitions.
4. Tune a radio to 100.2 MHz and turn it on.

To change the playlist later, add or remove MP3/OGG files in this folder and
run the BAT again. The generator uses the filenames as track titles and
registers the files directly without making extra copies. If the folder has no
MP3 or OGG files, the generator completes normally, removes the custom playlist
definitions and generated sound files, and leaves this folder ready for songs
to be added later. 100.2 MHz will not be registered until songs are generated.

The default 99.6 MHz playlist is not changed by this process.

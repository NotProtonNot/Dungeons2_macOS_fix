# Minecraft Dungeons II on macOS

**AI USAGE NOTE: This is a fork of Kubas556's Minecraft Dungeons II fix for Linux. That fix appears, to my eyes, to be end-to-end vibe coded and was commited by Cursor Agent. I forked it, fixed major problems with it (online sign in was broken in their version, among other things) and adapted it to work on macOS. As the original code was made by AI, this fix is not suitable for upstreaming Wine itself...**

A local 'stand in' for Microsoft Gaming Services so Minecraft Dungeons II can run under CrossOver. The game looks for `xgameruntime.dll`, which is a GDK component that is not present on non-Windows platforms. Some GDK games ship with deliberate Proton/Wine GDK compatibility, this one rudely does not. So this is a replacement for the missing component.

## Installation Instructions

CrossOver is required. This may work with other tools, it may not. 

Download the release zip. Extract it. Copy the DLL to the following locations....

**If using CrossOver itself**

Open CrossOver. Select your Steam bottle. Click  'Open C: Drive'. Go to Windows, System32. Copy the DLL into there.

Now go back to the top (root) of the C drive. Go to the folder where you have Steam installed. Then go to steamapps/common/Minecraft Dungeons II. Copy the DLL to that folder. Now go to <path to Steam>/steamapps/common/Minecraft Dungeons II/Dungeons/Binaries/Win64 and copy the DLL there as well. You are now done copying files.

Go back to CrossOver itself. Go to Wine Configuration, libraries, add 'xgameruntime' in the list. This part is not strictly speaking required.

Now you can start Steam. Launch the game.

**If using NotProton**

Your Steam library is at ```~/Library/Application Support/Steam/steamapps/common```. This being the Library folder that is in your macOS home folder. You can right click MineCraft Dungeons II in Steam and select 'Manage - Browse Local Files' to get to it easily. 

Go to the Minecraft Dungeons II folder inside ```common```. Paste xgameruntime.dll there. Go to <path to Steam>/steamapps/common/Minecraft Dungeons II/Dungeons/Binaries/Win64 and paste xgameruntime.dll there as well.

For the system32 part, go back a few directories to the ```steamapps``` folder. Go to compatdata, 1912410, pfx, drive_c. Then make your way to system32 and paste xgameruntime.dll. 

Right click the game in Steam, go to Properties, paste this in as a launch argument: WINEDLLOVERRIDES="xgameruntime=n". This part is not strictly speaking required.

## First Launch Quirks

When you launch the game for the first time, your browser will be opened to MS sign in and a dialog box will appear with a Microsoft Account sign in code. Enter that code, login to your Microsoft account, click through the process to authorize Minecraft Dungeons II to use your MS account. Once done, you can close your browser and click okay on the dialog box. 

## Building instructions

To build it yourself, you will need the MinGW-w64 cross compiler (`brew install mingw-w64`):

```sh
x86_64-w64-mingw32-gcc -shared -O2 -Wall -Wextra -o src/xgameruntime.dll src/xgameruntime.c src/xauth.c -lwinhttp -lbcrypt
```

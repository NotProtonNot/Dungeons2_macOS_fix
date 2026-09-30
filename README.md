# Minecraft Dungeons II on macOS

**AI USAGE NOTE: This is a fork of Kubas556's Minecraft Dungeons II fix for Linux. That fix appears, to my eyes, to be end-to-end vibe coded and was commited by Cursor Agent. I forked it, fixed major problems with it (online sign in was broken in their version) and adapted it to work on macOS. As the original code was made by AI, this fix is not suitable for upstream.**

A local 'stand in' for Microsoft Gaming Services so Minecraft Dungeons II (Steam app `1912410`) can run under CrossOver. The game looks for `xgameruntime.dll`, which is a GDK component that is not present under Linux. Some GDK games ship with deliberate Proton/Wine compatibility, this one rudely does not. So this is a replacement for it.

## Install

CrossOver is required. This may work with other tools, it may not. 

Download the release zip. Extract it. Copy the DLL to the following locations....

**If using CrossOver itself**

Open CrossOver. Select your Steam bottle. Click  'Open C: Drive'. Go to Windows, System32. Copy the DLL into there.

Now go back to the top (root) of the C drive. Go to the folder where you have Steam installed. Then go to steamapps/common/Minecraft Dungeons II. Copy the DLL to that folder. Now go to <path to Steam>/steamapps/common/Minecraft Dungeons II/Dungeons/Binaries/Win64 and copy the DLL there as well. You are now done copying files.

You may also want to delete the 'GamingRepair' EXE that the game comes with, as that will slow down game launch and the 'repair' will never work, as you are not actually running Windows. It is located in ```<path to Steam>/steamapps/common/Minecraft Dungeons II\Engine\Extras\ThirdPartyNotUE\GamingRepair\exe```. You could also delete the installscript files in the root of the game's folder instead. Or just wait for the 'repair' to silently fail and the game to then launch.

Go back to CrossOver itself. Go to Wine Configuration, libraries, add 'xgameruntime' in the list. This part is not strictly speaking required.

Now you can start Steam. Launch the game.

**If using NotProton**

Same rough procedure, just different paths. Your Steam library is at ```~/Library/Application Support```. This being the Library folder that is in your macOS home folder. You can right click MineCraft Dungeons II in Steam and select 'Manage - Browse Local Files' to get to it easily.

For the system32 part, go back a few directories to the ```steamapps``` folder. Go to compatdata, 1912410, pfx, drive_c. Then make your way to system32 and paste the file. 

Right click the game in Steam, go to Properties, paste this in as a launch argument: WINEDLLOVERRIDES="xgameruntime=n". This part is not strictly speaking required.

You may also want to delete the 'GamingRepair' EXE that the game comes with, as that will slow down game launch and the 'repair' will never work, as you are not actually running Windows. It is located in ```<path to Steam>/steamapps/common/Minecraft Dungeons II\Engine\Extras\ThirdPartyNotUE\GamingRepair\exe```. You could also delete the installscript files in the root of the game's folder instead. Or just wait for the 'repair' to silently fail and the game to then launch.

## First sign-in

Start the game from Steam. A window shows a code and opens <https://www.microsoft.com/link>. Enter the code, then sign in with the Microsoft account that you want to use.

## Building instructions

To build it yourself you need the MinGW-w64 cross compiler (`brew install mingw-w64`):

```sh
x86_64-w64-mingw32-gcc -shared -O2 -Wall -Wextra -o src/xgameruntime.dll src/xgameruntime.c src/xauth.c -lwinhttp -lbcrypt
./install.sh
```

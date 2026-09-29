# Minecraft Dungeons II on macOS

**AI USAGE NOTE: This is a fork of Kubas556's Minecraft Dungeons II fix for Linux. That fix appears, to my eyes, to be end-to-end vibe coded and was commited by Cursor Agent. I forked it, fixed major problems with it (online sign in was broken in their version) and adapted it to work on macOS. As the original code was made by AI, this fix is not suitable for upstream.**

A local 'stand in' for Microsoft Gaming Services so Minecraft Dungeons II (Steam app `1912410`) can run under CrossOver. The game looks for `xgameruntime.dll`. This repository builds a replacement for that library. It does not modify the game and it does not include Microsoft's library. 

On first launch it signs you in with your own Microsoft account through the normal device-code page at <https://www.microsoft.com/link>, then caches the Xbox tokens in `tokens.txt`. Later launches reuse that cache until it expires.

## Install

CrossOver is required. Sign-in runs inside the DLL, so nothing else needs installing. Clone this repository into the directory the DLL searches:

```sh
git clone git@github.com:NotProtonNot/Dungeons2_macOS_fix.git ~/.local/share/dungeons2-compat
cd ~/.local/share/dungeons2-compat
chmod +x install.sh
./install.sh
```

`install.sh` copies `src/xgameruntime.dll` to three places:

- next to `Dungeons.exe`
- next to `Dungeons-Win64-Shipping.exe`
- into the game's Wine prefix, `steamapps/compatdata/1912410/pfx/drive_c/windows/system32`

If the game lives in another Steam library, the script reads `libraryfolders.vdf`. Point `STEAM_ROOT` at your Steam install if it is not `~/Library/Application Support/Steam`.

In Steam, open the game's properties and set the launch option:

```text
WINEDLLOVERRIDES="xgameruntime=n" 
```

In CrossOver itself, go to Wine Configuration, libraries, add 'xgameruntime' in the list. Put the DLL in the system32 folder for the CrossOver bottle. Put it alongside both game EXEs as well. Launch the game. You may also want to delete the 'GamingRepair' EXE that the game ships, as that will slow down game launch and the 'repair' will never work, as you are not actually running Windows.

## First sign-in

Start the game from Steam. A window shows a code and opens <https://www.microsoft.com/link>. Enter the code, then sign in with the Microsoft account that should own the Xbox profile. Leave that page as `https://www.microsoft.com/link` with no extra query string.

The token file is `~/.local/share/dungeons2-compat/tokens.txt` (mode `0600`, in a `0700` directory). If the repository isn't cloned there, it's `drive_c/users/steamuser/AppData/Local/Dungeons2/tokens.txt` inside the game's Wine prefix instead. Do not share it. When it expires, the next launch refreshes it or asks you to sign in again.

## Rebuild

The DLL already in `src/` is ready to install. To build it yourself you need the MinGW-w64 cross compiler (`brew install mingw-w64`):

```sh
x86_64-w64-mingw32-gcc -shared -O2 -Wall -Wextra -o src/xgameruntime.dll src/xgameruntime.c src/xauth.c -lwinhttp -lbcrypt
./install.sh
```

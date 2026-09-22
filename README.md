# okpaint

Persistent personal decals for Counter-Strike: Source. Paint on the world, on props,
on clips and on triggers, saved per map and per player.

It runs on its own. With [showbrushes](https://github.com/ddyfad/okbrushes) loaded as
well, players can also paint the trigger and clip surfaces showbrushes draws.

## What you need

* SourceMod 1.11 or newer
* `addons/sourcemod/plugins/okpaint.smx` (a current build is in the repo)
* `addons/sourcemod/gamedata/okpaint.games.txt`, which holds the signatures used to
  paint on non-solid surfaces
* A MySQL or SQLite entry in `databases.cfg`, named by `sm_okpaint_database`
  (default `storage-local`). Settings are in `cfg/sourcemod/okpaint.cfg`, written on
  first load.
* Optional: the StaticProps extension, for painting nonsolid static props. A CS:S
  Linux build is in `addons/sourcemod/extensions/`, source in `extensions/staticprops/`.
* Optional: shavit's `shavit-core`, for chat colours that follow the timer's

okpaint keeps zaspaint's database table names, so paint saved by earlier versions is
still there.

## Building

```
spcomp -i addons/sourcemod/scripting/include \
       -o addons/sourcemod/plugins/okpaint.smx \
       addons/sourcemod/scripting/okpaint.sp
```

`showbrushes.inc` is a copy of showbrushes' API; update it when that changes.

StaticProps builds with AMBuild like any SourceMod extension:

```
mkdir build && cd build
python3 ../extensions/staticprops/configure.py --sdks=css \
    --hl2sdk-root=<sdks> --mms-path=<mmsource> --sm-path=<sourcemod>
ambuild
```

## Credits

* **zasbu** ([zasbu](https://github.com/zasbu)) for okpaint, originally zaspaint.
* **sigsegv** ([sigsegv-mvm](https://github.com/sigsegv-mvm/StaticProps)) for the
  StaticProps extension (Simplified BSD).

# gd-steam-ldb

Steam leaderboards for Godot 4, in one script.

It creates boards for you, holds scores until the board exists, stores extra
numbers on each entry, and attaches replay files.

Needs [GodotSteam](https://godotsteam.com). MIT licensed.

**Early release. The API may still change.** See [Feedback](#feedback).

## Install

1. Copy `steam_leaderboard.gd` into your project.
2. Open **Project > Project Settings > Globals** and add it as
   `SteamLeaderboard`.
3. Call `configure()` once, after `Steam.steamInit()`.

## Your first board

```gdscript
SteamLeaderboard.configure({"prefix": "MyGame_"})

SteamLeaderboard.set_group("level_01")      # when a level loads
SteamLeaderboard.submit(score)              # when the run ends
```

That makes one board per level, named `MyGame_level_01`. You do not create it in
the Steamworks dashboard. The first time a player finishes the level, the board
appears.

To read it back:

```gdscript
SteamLeaderboard.board_ready.connect(func() -> void:
    SteamLeaderboard.fetch(SteamLeaderboard.RequestType.GLOBAL, _on_entries, 1, 10)
)


func _on_entries(entries: Array) -> void:
    for entry: Dictionary in entries:
        print("#%d  %d" % [entry["global_rank"], entry["score"]])
```

Wait for `board_ready` before fetching. Until it fires there is no board to read
from.

For a game with one score per level, that is everything.

## Three things to know

### Group

The thing being played: a level, a track, a course. One string.

```gdscript
SteamLeaderboard.set_group("level_01")
```

Each group gets its own board. Switching groups clears the old one's state.

### Axis

A category that splits a board in two or more. Add one and you get a board for
every combination.

```gdscript
SteamLeaderboard.configure({
    "prefix": "MyGame_",
    "axes": [
        {
            "id": "difficulty",
            "default": 0,
            "tokens": {1: "HARD"},
        },
    ],
})
```

Board names read `PREFIX_TOKEN_TOKEN_group`:

| difficulty | board |
|---|---|
| 0 (the default) | `MyGame_level_01` |
| 1 | `MyGame_HARD_level_01` |

The default value adds no token. That is deliberate: the plain board keeps its
plain name, so you can add a new axis later and every board you already have
keeps working. Steam never renames or deletes a board, so this is worth getting
right the first time.

Two axes with two values each is four boards per level. `boards_per_group()`
tells you the number. Check it before you ship, because each axis multiplies it.

### Variant

Which axis values are picked right now. There are two, and they do different
jobs:

| | |
|---|---|
| `set_variant()` | What the player is playing. Scores go here. |
| `set_view()` | What the menu is showing. Reading only. |

`set_view()` lets a player look at the hard board while still playing normal.
Their score still goes to normal. Use the wrong one and scores land on whatever
board the player last looked at.

## Axis settings

```gdscript
{
    "id": "difficulty",       # name you use in set_variant, required
    "default": 0,             # the value that adds no token
    "tokens": {1: "HARD"},    # value -> the text in the board name
    "always_token": false,    # give the default a token too
}
```

### Naming both sides

Some categories have no "normal" side. Inbounds and out of bounds are both real
runs, so leaving one unnamed looks like a mistake. Set `always_token` and give
the default a token:

```gdscript
{
    "id": "bounds",
    "default": 0,
    "always_token": true,
    "tokens": {
        0: "IB",
        1: "OB",
    },
}
```

You get `MyGame_IB_level_01` and `MyGame_OB_level_01`.

### What is not an axis

**Anything worked out from the score.** Medals, ranks and tiers come from the
time or points the player got. They are not a category to split on. Work them
out in your own code and put the answer in `extra_info`. Making one an axis
doubles your boards and splits the leaderboard by result, which is not what you
want. See `examples/bloodthief.gd`.

**Boards your server writes.** A global ranking built from every level's scores
is still a group you can read with `set_group()` and `fetch()`. Just never
`submit()` to it, or your server's next update wipes what you wrote. See
`examples/surf_timer.gd`.

**Categories that keep growing.** An axis needs a fixed list of values. If yours
grows over time, like bonus course 1, 2, 3, put it in the group name instead:

```gdscript
SteamLeaderboard.set_group("B1_level_01")
```

That is two groups, no axis.

## Storing extra numbers

Steam keeps up to 64 whole numbers next to each entry. Name the slots with
`extra_keys`, then pass a dictionary:

```gdscript
SteamLeaderboard.configure({
    "prefix": "MyGame_",
    "extra_keys": ["split1", "split2", "medal"],
})

SteamLeaderboard.submit(score, {"split1": 12340, "split2": 9870, "medal": 2})

var extra: Dictionary = SteamLeaderboard.decode_extra(entry["details"])
print(extra["medal"])
```

The order of `extra_keys` decides which slot each key uses. Keys you leave out
are stored as 0, and a key you add later reads as 0 on older entries. **Adding a
key to the end is always safe.** Reordering or removing keys changes what every
existing entry means, so change the `prefix` if you need to do that.

Only whole numbers fit. For anything else, convert it first: multiply a float by
1000, or store a number instead of a word.

## Replays

```gdscript
SteamLeaderboard.attach_replay("run_1234.rpl", bytes)

SteamLeaderboard.download_replay(entry["ugc_handle"], func(data: PackedByteArray) -> void:
    if not data.is_empty():
        _play_ghost(data)
)
```

The file name cannot contain `:` or `/`. Steam rejects those without telling
you, so the script checks first.

The board is picked when you call `attach_replay()`, not when the upload
finishes. A slow upload cannot land on the wrong board after a level change.

## Settings

`prefix` goes in front of every board name. It keeps your boards separate from
other games, and changing it is how you wipe a season: pick a new prefix and the
next lookup makes fresh boards, leaving the old ones untouched.

If you leave off the trailing `_`, one is added, so `"MyGame"` and `"MyGame_"`
do the same thing.

```gdscript
SteamLeaderboard.configure({
    "prefix": "MyGame_",     # required
    "axes": [],              # see above
    "extra_keys": [],        # names the number slots on each entry
    "descending": false,     # true when a higher score is better
    "excluded": [],          # groups that get no board
    "timeout": 10.0,         # seconds before a fetch gives up
    "ranks": {},             # percentile -> label, for rank_label()
    "debug": false,          # print what the script is doing
}, steam_id, read_only)
```

`read_only` looks boards up without making them, and blocks all uploads. Use it
to keep an old season readable after you change the prefix.

## Signals

```gdscript
board_ready                          # the board is ready to read
score_submitted(success, context)
score_dropped(context)               # no board, score thrown away
replay_attached(success)
```

`context` is a dictionary you hand to `submit()` and get back later. Put the
replay file name and level in it. A callback can arrive after the player has
moved on, and then reading the current level tells you the wrong thing:

```gdscript
SteamLeaderboard.submit(score, extra_info, {"replay": file_name})


func _on_dropped(context: Dictionary) -> void:
    DirAccess.remove_absolute("user://replays/" + context["replay"])
```

## Functions

| | |
|---|---|
| `configure(config, steam_id, read_only)` | Call once after Steam starts |
| `set_group(name)` | Pick a level, clears the last one |
| `set_variant(axis, value)` | Change where scores go |
| `set_view(axis, value)` | Change what you are reading |
| `submit(score, extra_info, context, keep_best)` | Send a score |
| `fetch(type, callback, start, end, users)` | Read entries |
| `attach_replay(name, bytes)` | Attach a replay to your entry |
| `download_replay(handle, callback)` | Get somebody else's replay |
| `board_name(group, variant)` | See what a board would be called |
| `parse_name(name)` | Split a board name back apart |
| `encode_extra()` / `decode_extra()` | Swap between a dictionary and the stored numbers |
| `rank_label(rank)` | Turn a rank into a label |
| `boards_per_group()` | How many boards each level makes |
| `validate()` | List settings problems |
| `reset()` | Clear level state by hand, `set_group()` does it for you |

`fetch()` types are `PERSONAL`, `FRIENDS`, `GLOBAL`, `AROUND` and `GROUP`. The
callback always runs. If the fetch fails or times out it gets an empty array, so
nothing waits forever.

## Common mistakes

**Board names last forever.** Steam has no way to delete a leaderboard. A typo
in `prefix`, a renamed token, or reordering `axes` leaves every old board
stranded and unreachable. Run `validate()` while you work: it catches repeated
tokens, tokens with `_` in them, and default-token mix-ups.

**Fetching too early.** Nothing is sent until `board_ready` has fired.

**Reading live state in an axis.** If an axis follows the equipped weapon or the
active controller, a change mid-run moves the score to a different board. Set it
once when the run starts.

**Changing `descending` later.** Steam ignores it for boards that already exist.

## Where this came from

This was pulled out of
[SurfsUp](https://store.steampowered.com/app/3454830/SurfsUp/), a Source-style
surf and movement game. It runs the leaderboards there: 40 boards per map across
four movement modes, five styles and a separate controller ranking, with stage
split times, ghost replays, and an old season kept readable.

The SurfsUp version had its own modes and styles written into the code, and
reached into four other parts of the game to work. Making it reusable meant
turning all of that into settings. `examples/surf_timer.gd` is the same setup
with the names changed.

## Examples

Each one is a full working script. Start with whichever is closest to your game.

| | |
|---|---|
| `examples/simple.gd` | One board per level. No axes. |
| `examples/speedrun.gd` | Weapon and category axes, split times, ghosts. |
| `examples/bloodthief.gd` | `always_token` on both axes, and medals worked out from the time instead of being an axis. |
| `examples/surf_timer.gd` | The full setup from SurfsUp. Three axes, bonus courses as groups, splits, ghosts, and a read-only old season. |

## What is tested

Tested in an empty Godot 4.7 project with no game attached: every axis
combination survives `board_name()` and `parse_name()`, level names with `_` in
them still parse, `encode_extra()` and `decode_extra()` match, a key added later
reads as 0 on old entries, the 64-number limit holds, `validate()` catches bad
settings, and `rank_label()` works across the range.

**The Steam calls are not tested on their own.** Finding, uploading, fetching
and replay handling come from SurfsUp, where they run every day, but the pulled
out version has only run against a fake Steam. Try it with your own app ID
first, and use a throwaway prefix while you do, because the boards you make are
permanent.

## Feedback

This came out of one game, so the parts most likely to be wrong are the ones
that game never used. Worth telling me about:

- **Board names that will not fit.** Axes assume tokens join into one name. If
  your boards need a different shape, I want to know.
- **`extra_keys`.** Fixed slots are the simplest thing that works, but a run
  with any number of splits fits badly.
- **Steam behaviour I have not seen.** Rate limits, very large boards, `AROUND`
  and `GROUP` fetches, and replays on macOS.
- **Anything that took too long to work out.** That means the docs or the names
  are wrong.

Issues and pull requests welcome. If you ship a game with it, tell me.

## License

MIT. See [LICENSE](LICENSE).

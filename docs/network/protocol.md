# The network format

This file says what machines send each other in a match. The examples in `exchanges.json` say the
same thing as data, and every implementation tests itself against them.

## The idea

Every machine runs the whole game. The machines send only what each player pressed. A machine runs
a pass of the game when it has the buttons of every player for that pass. This is called lockstep.

One set of messages serves two ways to connect:

- A relay. Each machine connects to the relay. The relay passes each message on to the other
  machines of the room.
- A direct connection. One machine is the host, and the others connect to it. The host passes each
  message on, as the relay does.

A machine cannot tell which one it is using. The relay and the host never play the game and never
read the buttons.

## The messages

A message is one JSON object. It is sent as one WebSocket text message, or as one line on a socket.
Every message has two fields:

- `"v"`: the version of this format. This file is version 1.
- `"type"`: the name of the message.

The room adds `"from"` to each message it passes on. This is the number of the sender in the room.
A machine cannot set it. The room replaces any `"from"` the sender wrote. The number of a machine
in the room is also its player number. The first machine, which made the room, is player 1.

### Before the match

| type | sent by | fields | meaning |
|---|---|---|---|
| `join` | a joining machine, to the host | `game`, `console`, `digest` | "Let me into the match." It says which game, for which console, and the digest of the program. |
| `welcome` | the host | `to`, `seed`, `input_delay`, `checkpoint_every`, `players` | The machine `to` is let in. These numbers are the same on every machine, and only the host chooses them. |
| `refuse` | the host | `to`, `reason`, `game`, `console`, `digest` | The machine `to` is not let in. `reason` is `different_game`, `different_console`, `started` or `full`. |
| `joined` | the host | `player` | A machine was let in. Every machine can show who is here. |
| `start` | the host | `players` | The match begins. `players` is the list of player numbers. |

The digest is a SHA-256 of the program as the build made it, and the name of the console. Two
machines that have the same digest run the same game.

### During the match

| type | fields | meaning |
|---|---|---|
| `buttons` | `pass`, `mask` | The buttons the sender's player holds on pass `pass`, one bit for each button (a, b, select, start, right, left, up, down, r, l, x, y, c). It is sent `input_delay` passes before that pass is played. |
| `checkpoint` | `pass`, `crc` | The CRC-32 of the whole game state of the sender after pass `pass`. A machine that sees two different numbers for one pass stops the match and names the pass. |
| `left` | none | Said by the room, never by a machine. The sender (in `from`) has gone. The room passes on every message the sender sent before it says this. So every machine knows the same last pass of that player. |

Pass 1 is the pass in which the game sets itself up. It reads no buttons. Pass 2 is the first pass
that does. The buttons for passes 2 to `input_delay` + 1 are nothing, for every player, and are not
sent.

### With the relay

These messages are between one machine and the relay. The relay does not pass them on.

| type | sent by | fields | meaning |
|---|---|---|---|
| `make_room` | a machine | none, or `public`, `digest`, `name`, `seats` | "Make a room, and put me in it." With `"public": true` the room is listed (see below). |
| `room_made` | the relay | `code`, `you` | The room is made. Give `code` to the others. `you` is 1. |
| `join_room` | a machine | `code` | "Put me in the room with this code." |
| `room_joined` | the relay | `code`, `you`, `members` | You are in the room. `you` is your number. `members` lists the numbers already there. |
| `list_rooms` | a machine | `digest` | "Which public rooms are there for the game with this digest?" |
| `rooms` | the relay | `rooms` | The answer: a list of `{ code, name, members, seats }`, in the order the rooms were made. |
| `error` | the relay | `reason`, `words`, `supported` | The relay did not do what the machine asked. |

### Public rooms

A room is private unless its `make_room` says `"public": true`. A public room gives the `digest` of its
game, a `name`, and its `seats`: how many machines the match holds. The name tells nobody who made the
room, and a room with no name is listed as "Room" and its code. The relay lists a public room, in answer to
`list_rooms` with the same `digest`, while it has a seat free. It drops the room from the list when the room
fills (it has as many machines as `seats`), and when it empties. A machine that asks about another game's
digest is told of none of the room. A private room is listed to nobody.

A machine in the list joins with `join_room` and the `code` of the room, as it would with a code a person typed.

The reasons in an `error` are:

- `version`: the message has a version the relay does not know. `supported` lists the versions it
  knows.
- `bad_message`: the text is not a message of this format.
- `no_such_room`: no room has that code.
- `room_full`: the room has 16 machines.
- `not_in_a_room`: the machine sent a match message before it made or joined a room.
- `already_in_a_room`: the machine asked for a room when it is in one.

`words` is a sentence for a person. A machine can show it, or write its own sentence for the reason.
The numbers in a room are never used again for another machine.

## Versions

The version in `"v"` rises when a change would make an older reader misunderstand a message. A new
message, or a new optional field, does not raise it. A reader ignores the fields it does not know.

A machine that reads a message with a version it does not know must say so in plain words, and must
not guess. The words say which version each side knows, so a person can tell which of the two to
update. A newer game that talks to an older relay gets an `error` with the reason `version`.

## Chat and the game

Chat messages, when there are some, never reach the game. They are not buttons, and no state hash
covers them.

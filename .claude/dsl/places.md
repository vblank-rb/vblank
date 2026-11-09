# DSL reference: Places

The map of every page is `.claude/rules/dsl-reference.md`. **On this page** has a line for each
verb here; the entries after it tell each one in full.

## On this page

- `place :cube do … end` or `points:, faces:` (data), `viewer`, `draw_place` (`at:`, `facing:`), `screen_spot`, `change_picture` — 3D, lit by `shading` (`image shading:`).

## In full

A first-person view of a place built from flat faces, seen from a spot the game chooses. The words:
a **place** is points in space and the faces that join them; a **point** is three numbers, across
(x, to the right), up (y) and ahead (z); a **face** is a flat side joining three or four points in
order, with a **picture** on it; a face's **corners** say where on its picture each of its points
falls; a **viewer** is the spot the place is seen from and which way it faces (three arrows of length
one, **right**, **up** and **ahead**). Worked example: `test/console/gba/vblank/builder/test_places_on_the_advance.rb`.

## Declaring a place

- `place :cube do … end` → the place — declare a place. Inside the block, `point x, y, z` makes a
  point and returns its number, and `face a, b, c, d, picture: :crate, on_picture: [[0, 0], [64, 0],
  [64, 64], [0, 64]]` joins three or four points with a picture. `on_picture:` is one `[across, down]`
  for each point, in the picture's own pixels and in the same order. **The picture repeats past its
  edges like wallpaper**, so a corner can fall at 200 on a picture 64 pixels wide, or at -70, and the
  picture's width and height must each be 1, 2, 4, 8, 16, 32, 64, 128 or 256 pixels (a friendly error
  otherwise). A point's numbers go from -8191 to 8191, with fractions, and so do the viewer's: half of
  what a fraction holds, so no point is ever too far from the viewer to measure. A corner falls from
  -8191 to 8191 picture pixels. The place is written into the cartridge as it is declared and does not
  change shape as the game runs. **Each face shows its picture through a slot**, one for each picture
  the place lists, named after it; a place declared in a scene or a `part` the game starts over shows
  each slot its own picture again. Friendly errors: neither a block nor data (the next entry), no faces, a face of other than three or
  four points, a point the place does not have, a picture that is not declared, `on_picture:` that does
  not give one spot for each point, a number out of range, a name with two underscores in a row or one
  at its end, and a second place of the same name.
- **A place from data**, as a game reads a level from a file: `place :mine, points: [[x, y, z], ...],
  faces: [{ points: [0, 1, 2, 3], picture: :rock, on_picture: [[0, 0], [64, 0], [64, 64], [0, 64]],
  light: 0.5 }, ...]`, with no block. Each face is a hash of what `face` takes, its points by their
  number in `points:` (from 0); `light:` may be left out. `pictures: %i[rock moss]` lists pictures
  first, as `pictures` does in a block (it works beside a block too), so a face can name its picture
  by its number among them (`picture: 1`), as a level file numbers its pictures; `face` in a block
  takes a number the same way. `shading:` works as for a block. The place is the one the same `point`
  and `face` calls make, checked the same way, and builds the same bytes. A JSON file read with
  `JSON.parse(text, symbolize_names: true)` gives faces as they are wanted: its picture names come as
  strings, and a picture's name may be a string here and in `face` and `pictures`. Friendly errors, each
  naming the point or face by its number in its list: a face naming a point past the points, a face
  of other than 3 or 4 points, a picture number the place does not list or a picture name that is not
  declared, a point that is not three numbers, a face that is not a hash, a key it does not take (or
  string keys), a face with no `points:`, `picture:` or `on_picture:`, both a block and data, and
  `points:` without `faces:` or the other way round. **What it costs**: building costs what the block form
  costs, a small part of a second for a place of about a thousand faces on any console. Drawn whole,
  a floor of about a thousand faces, half of them out of view, draws at least eight times a second on
  the Advance with `perspective: :none` (`PlaceGames.big_floor`, held by a cost test), and takes several
  frames a drawing in perspective; on the PlayStation it takes four frames a drawing without perspective
  and five with `:every_8_pixels` (held by a cost test too). The faces out of view cost little (see "How
  it is drawn"). A game of that size still does best drawing only the faces it can see (`faces:` and
  `window:` below).
- **Walls whose picture changes**: a door sliding through its frames, a wall of lava, a forcefield.
  Inside the place, `pictures :door0, :door1, :door2` lists pictures the place can show, numbered in a
  row after those listed before (a face's `picture:` lists its picture too, where it first names it);
  list a door's frames first, so they are 0, 1, 2. `hall.picture_number(:door1)` gives a picture's
  number. As the game runs, `change_picture :hall, slot: :door0, to: :door2` points the slot named
  for `:door0` at `:door2`: every face that starts with `:door0` shows `:door2` from that drawing on,
  until the slot is pointed again. `to:` is a picture the place lists, by name or number, or a whole
  number the game works out (`to: frame + hall.picture_number(:door0)`); a worked-out number that is
  not one of the place's pictures is passed over and the slot keeps what it shows. `slot:` is a
  picture's name or number. A place that never changes a picture builds the same as before. Friendly
  errors: a slot or a picture the place does not list, a picture number out of range, and a fraction.
  **Each console**: on the Advance, a change by name is a store; by a worked-out number, about 18
  instructions more than working the number out (two tests and a store). The PlayStation keeps every
  picture the place lists in video memory from the start, so a change copies nothing. The Game Boy
  Color, the Super Nintendo and the Genesis change the slot as well, though they refuse to draw the
  place. Worked examples: `examples/cube3d.rb` (hold START), and `PlaceGames.changing_door` in
  `test/place_games.rb`, a door through three pictures by a worked-out number.

## The viewer

- `viewer :eye, at: [x, y, z], facing: { right: [1, 0, 0], up: [0, 1, 0], ahead: [0, 0, 1] }` →
  the viewer — the spot a place is seen from, and which way it faces. `facing:` is three arrows,
  each three numbers of length one and square to the other two (a friendly error otherwise); left out,
  the viewer faces along the place's own arrows. A viewer is twelve variables, and the game moves and
  turns it as it runs:
  - `eye.move :ahead, by: 0.05` — along its own arrows: `:ahead`, `:back`, `:left`, `:right`, `:up`,
    `:down`, by a number or a value the game works out (a whole number or a fraction).
  - `eye.turn :left, by: 2` — degrees, `:left`, `:right`, `:up` (tip up) or `:down`; `eye.roll :left,
    by: 2` rolls round the way it faces, `:left` or `:right`. The angle is a number written in the
    game, or a value the game works out (`eye.turn :right, by: spin`): whole or a fraction, below
    nought or past a whole turn (a fraction holds no more than 32767 degrees either way). A written angle's sine and cosine are
    settled while the game is built; a worked-out one reads them from a table of the sine of each
    whole degree (1804 bytes, in the cartridge only of a game that turns by one), stepped between two
    entries for a fraction of a degree, so a whole degree turns exactly as the same number written
    does. **Every turn keeps the arrows square and
    of length one**, so a game can turn for as long as it likes and the place never comes out
    stretched: each turn ends by making ahead length one, taking from up whatever part of it lies along
    ahead, making up length one, and making right from the two.
  - `eye.at x, y, z` and `eye.face right: [...], up: [...], ahead: [...]` — set the spot, or the three
    arrows, from numbers or values the game works out (a game with a flight model of its own hands its
    arrows straight in; they are taken as given, not squared up).
  - `eye.spot`, `eye.right_arrow`, `eye.up_arrow`, `eye.ahead_arrow` — read them back, three fractions
    each; `eye.facing` gives all three arrows as `facing:` takes them.

  Worked example: `examples/cube3d.rb`, a crate flown round with the buttons.

## Drawing a place

- `draw_place :cube, seen_by: eye` — draw the place as the viewer sees it, across the screen or the
  `inside` area it is drawn in. Each point is turned to the viewer, put on the screen, and each face
  filled with its picture, a later face over an earlier one. **A face that reaches nearer than the near
  limit is cut there**, so a wall beside the viewer is drawn up to the limit. **A face is seen from its
  front only**: the side from which its points go round clockwise. Settings: `near: 0.25` (the near
  limit, in wholes, more than 0 and not more than 16), `view_angle: 90` (degrees across, 10 to 170),
  `both_sides: true` (draw a face from behind as well), and **`perspective:`**: how a picture lies on
  a face that leans away. `:every_8_pixels`, the default, works the place on the picture out exactly
  every eight pixels across a row and steps straight between, so a wall's picture stays put as you
  move; `:every_pixel` works it out at every pixel; `:none` stretches it straight between the
  corners, cheaper, and it swims on a face that leans steeply. The choice is per call: a game of rooms
  can draw its near rooms in perspective and its far ones with `:none`, as the old games did. A
  setting that is not one of these three is a friendly error. **Needs `screen :bitmap, tear_free: true`** (a friendly error on any
  other screen): a place is drawn over a whole frame, and on one page the player would see it drawn. It
  draws over what is there and clears nothing.

  **Drawing only what the game can see.** A place of many rooms is too much to draw whole, and which
  rooms show, in what order, and how far the look goes is the game's to decide (the old first-person
  games walked from the player's room through each doorway it could see). Two settings and one verb
  let it:
  - `faces: list` — draw only the faces whose numbers (what `face` gives back) a `list` holds, in its
    order, a later one over an earlier. Its length is read as the drawing starts; a number that is not a
    face of the place is passed over. A list that is not a list, or holds fractions, is a friendly error.
  - `window: [left, top, right, bottom]` — hold the faces to a rectangle the game works out as it runs:
    whole numbers or variables, the right and bottom just past the last pixel, as `inside` counts. It is
    held inside the view; the projection does not move. Anything but four whole numbers is a friendly
    error.
  - `corner = screen_spot :rooms, point, seen_by: eye` → `ScreenSpot` — where point `point` (a number
    `point` gave, or a whole-number value) lands, worked out as the game runs exactly as a face's corner
    is: `corner.x`, `corner.y` (the first pixel whose middle is at or past it; off the screen when the
    point is), and `corner.behind?`, true when the point is behind the viewer or nearer than the near
    limit (then `x` and `y` are 0). It takes `near:` and `view_angle:` as `draw_place` does, and the same
    `inside` area, so give it the same. Write it inside `game_loop`: each line keeps its answers in
    variables of its own, worked out each time the line runs. A point the place does not have is a
    friendly error. It works on every console (only sums).

  **A shape drawn where the game says**: a robot that flies and turns in a room, from one shape
  declared once and drawn as many times a pass as there are robots. Declare the shape round its own
  middle (a place like any other), and give the drawing two settings:
  - `at: [x, y, z]` — where the shape's middle (the place's 0, 0, 0) stands now: numbers, or values
    the game works out (whole or fractions).
  - `facing: { right: [...], up: [...], ahead: [...] }` — which way the shape's own arrows point now,
    three arrows of three numbers or values, as `viewer` takes them; left out, the shape faces as it
    was declared. The arrows are taken as given, as `eye.face` takes them, so arrows that are not of
    length one and square to each other draw the shape bent.

  A robot that moves and turns with the viewer's own words keeps a viewer of its own and hands it
  over: `bot = viewer :bot, at: [3.0, 0.0, 8.0]`, `bot.turn :left, by: spin`, then
  `draw_place :robot, seen_by: eye, at: bot.spot, facing: bot.facing`. A game with a flight model of
  its own gives its numbers straight in. `screen_spot :robot, point, seen_by: eye, at:, facing:` with
  the same stance says where a point of the moved shape lands, to the pixel. `window:`, `faces:`,
  `perspective:`, lighting and picture slots work as for a shape drawn where it was declared; the
  slots and the point lights belong to the shape, so every robot drawn from it shows the same. The
  shape where it stands, its points included, must stay within -8191 to 8191, as a place's points
  must. Each drawing at another stance turns the shape's points afresh: they are not shared with a
  drawing at another stance. Friendly errors: `at:` that is not three numbers or values, a written
  number out of range, `facing:` that is not three arrows of three, and written arrows that are not
  of length one and square. A written `at:` is checked, but not where it puts the shape's points: a
  point that lands past the place's reach raises nothing and draws wrong. **What it costs on the
  Advance**: the viewer is moved into the shape's own arrows once a drawing (a routine of 18
  products, about 900 cycles; three subtractions for `at:` alone), and the shape's points are turned
  afresh (a square's four, about 3000 cycles); nothing more for each point than a fixed place's first
  drawing costs. A shape whose spot puts it wholly out of view (behind the viewer, nearer than
  `near:`, or past an edge of the view) is passed over before any point is turned: the ball round
  its points is tested once, about the cost of turning one point, so robots round the player cost
  only for the ones in view. The picture is the same as drawing it. Worked examples in
  `test/place_games.rb`: `PlaceGames.moved_shapes`, one shape drawn at two stances that change every
  pass, `PlaceGames.stance_against_declared`, a moved shape against the same shape declared where it
  stands, and `PlaceGames.shapes_at_edges`, shapes at the edges of the view against the same declared.

  A game of rooms draws each room with its own call, far rooms first: the box round a doorway's
  `screen_spot`s is the window of the room beyond (any corner behind: the whole screen; all behind: not
  seen). Worked example: `examples/two_rooms.rb`.

## Lighting a place

Each corner of a face has a light, from 0 (the darkest level) to 1 (the
brightest), blended smoothly across the face, and each pixel is drawn in the colour the game's own
**shading** gives for its colour at the light it has reached. Worked example: `examples/lit_corridor.rb`,
a corridor whose lamp flickers.
- `shading :lamplight, colors: [...], levels: [[...], ...]` — the game's colours (as `rgb` gives, or
  names), and for each level of light, darkest first, one number for each colour: the place in
  `colors:` of the colour it becomes at that level. A game's own shading tables come over as they are
  (32 levels, say). A colour not in `colors:` is drawn as it is. Friendly errors: a level whose length
  is not the number of colours, a place out of range, no levels, a second shading of the same name.
- **Two places of one colour that darken apart**: a shading finds a pixel's darkening by its colour,
  so where `colors:` holds one colour at two places with different levels (a game's palette nearly
  always repeats some), a picture of colours darkens all of it by the first place's levels.
  `image :wall, width: 64, height: 64, shading: :lamplight, places: [...]` gives the picture as
  NUMBERS into the shading's `colors:` instead, one for each pixel, as a game's own art counts into the
  palette its fade tables were made for: each pixel is the colour at its place, and a face lit by that
  shading darkens each pixel by its own place's levels. Every place is a colour (none is see-through).
  Anything else that draws the picture, and a face lit by another shading, draws its colours. The
  Advance gives each such place a number of its own on the tear-free screen, holding the same colour,
  one of its 256 for each colour and darkening; a screen given `colors:` must hold that colour once more
  for it (a game whose screen list and shading list are one list holds it already). A game that
  gives no picture of numbers builds as before. Friendly errors: a shading not declared yet, `colors:`
  as well, places of the wrong count or that the shading does not hold, and a screen's `colors:`
  with no second slot of the colour. Worked example: `PlaceGames.twin_whites` in `test/place_games.rb`.
- `place :hall, shading: :lamplight do … end` lights the place. `face …, light: 0.5` gives every
  corner of the face that light, and `light: [1.0, 0.5, 0.5, 1.0]` one for each corner in order;
  left out, 1. A number outside 0 to 1 is a friendly error. A light is held to just under 1.
- `hall.point_lights[point] = value` — light the game adds to a point as it runs (a lamp, a flash,
  a flicker), a fraction from a list the place has, one for each point, all 0 at the start. A
  corner's light is its face's `light:` plus its point's, held to 0..1.
- `draw_place :hall, seen_by: eye, lit: false` draws a lit place unlit, as its pictures are.
- The levels step evenly across a face whatever the `perspective:`. A light of 0.5 with 8 levels is
  level 4. Every lit colour is in the tear-free screen's 256 colours, so a shading of many colours
  takes room there.
- **Each console**: the Advance looks each pixel up in a table the build makes from the shading, so
  every pixel is exactly the colour the shading gives. A lit pixel costs one load more than an unlit
  one: about two thirds again the unlit fill's cost with `:none`, and about a third again with
  `:every_8_pixels`. A game that lights no place carries none of it. The PlayStation lights a
  face the way its own games did: its graphics chip shades each triangle, carrying a colour at each
  corner from the corner's light and multiplying every texel's red, green and blue by the colour it
  steps across the triangle. So the light falls smoothly rather than in the shading's steps, and a lit face
  costs about what it does unlit however many levels its shading has and however steeply its light
  falls. Where the shading darkens each colour evenly (a game's fade tables), a pixel is within a level
  of the shading's colour; a shading that does anything else (a tint, a fog) is drawn as the colour
  made darker. Any picture can be lit there; a picture given as numbers is its colours made darker, as
  the chip shades by colour and reads no tables.

## How it is drawn

For work on VBlank itself: the classes named here are VBlank's own, and a game reaches none of them.

The same on every lowering: the turn, the cut and the projection are statements
the lowering makes like any other (`IR::PlaceDrawing`, fractions with sixteen bits through `mul_fix`
and `div_fix`), and only the fill of a face, of three to eight corners, is written by hand for each
(`Reference#exec_fill_face` is the rule every one follows). So the interpreter and every build draw the same pixels.
Each point is turned and put on the screen once, however many faces share it, and once for all the
drawings and `screen_spot`s in a row seen from the same viewer with the same `view_angle:` and `inside`
area, and with the same `near:` or a farther one than the first (`IR::PlaceDrawing::TURN_PARTS`); a
drawing without perspective shares the points one in perspective turned, and on the PlayStation the
other way round too: a game of rooms that asks where each room's corners land and then
draws each room with its own call turns a doorway's corners once, not once for the asking and once
for each room beside it. A `screen_spot` with a nearer `near:` than the drawings' still shares. A
drawing or `screen_spot` handed the same viewer and the same view as the one before it costs a
comparison for each of the viewer's numbers and one for the view, and nothing more: the viewer and the view are
handed over by a routine of the place's own, which writes only what changed, and the points' count is
looked at only when something did (`IR::PlaceDrawing`, "HANDED OVER UNCHANGED"). On a
console whose processor runs its code from a small cache (the PlayStation's) a face's corners are
worked in a loop, so a face's code stays in the cache from one face to the next. **Each point gets a
code as it is turned** (`IR::PlaceDrawing`, "POINT CODES"), as Descent's points did: which edges of the
view it lies past, or that it is behind the viewer. A face whose corners share such a bit (all behind,
or all past one edge of the view) is passed over before any of its corners is read, and a face with no
corner behind is handed to the fill as it is, with none of the cut's tests. Where the near limit was
nearer when the points were turned (a `screen_spot` with its own `near:`), only the behind bit is used,
and the rest goes to the cut as before. A face drawn whole and seen from behind is passed over before
its corners are handed on (on the PlayStation, as they are handed on, in the loop), and on every
console but the PlayStation so is one whose corners all lie between two rows' middles, which draws
nothing (most of a far floor). On the PlayStation a face the graphics chip can draw as it is (up to four
corners; without perspective on the screen, in perspective inside its window and inside one of
the squares it is cut into; its picture reaching no further than the chip's texture coordinates) is
sent to the chip straight from its corners,
and a drawing's corners are kept in the processor's scratchpad, where the fill reads them. On every lowering a
face whose corners, once it is cut at `near:`, all lie past one edge of the screen or the window is
passed over before it is tested for which way it faces or filled, a face reaching behind the viewer
included, so a game that draws a room through a doorway's window pays little for the faces the window
hides. The Advance's fill makes that test itself; every other lowering makes it in the shared drawing,
as the cut hands each corner on (`IR::PlaceDrawing::OUTCODE_EDGES`). **What it
costs on the Advance**, a face covering the whole screen with a picture with no see-through pixel:
about 15 of the console's cycles a pixel with `perspective: :none` (two pixels worked out together
and written as one pair; 20 pictures a second), about 30 with `:every_8_pixels` (each stretch of
eight worked out exactly at its far end, then two pixels at a time; 12 a second), and about 90 with
`:every_pixel`. A picture with see-through pixels reads each pixel's pair back first, about 37 without
perspective. `examples/cube3d.rb` runs at 30 a second and `examples/two_rooms.rb` at 10, both in
perspective. **Perspective is the same everywhere**: one over each corner's distance travels with its
corner, and the place on the picture is found from it through one shared table (`IR::Reciprocals`),
which every lowering reads, so all of them draw the same pixels. `rom.profile`
names the fill "filling the faces of a place with their pictures".

## Each console

The Advance and the PlayStation draw a place, lit or not (their pages say how). The Game Boy Color, the Super
Nintendo and the Sega Genesis refuse `draw_place` in plain words (see their pages); `screen_spot` works
on all four.

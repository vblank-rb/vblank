# DSL reference: Places

The whole story of these verbs. The one-line index is `.claude/rules/dsl-reference.md`.

A first-person view of a place built from flat faces, seen from a spot the game chooses. The words:
a **place** is points in space and the faces that join them; a **point** is three numbers, across
(x, to the right), up (y) and ahead (z); a **face** is a flat side joining three or four points in
order, with a **picture** on it; a face's **corners** say where on its picture each of its points
falls; a **viewer** is the spot the place is seen from and which way it faces (three arrows of length
one, **right**, **up** and **ahead**). Worked example: `test/console/gba/vblank/builder/test_places_on_the_advance.rb`.

- `place :cube do … end` → `DSL::Place` — declare a place. Inside the block, `point x, y, z` makes a
  point and returns its number, and `face a, b, c, d, picture: :crate, on_picture: [[0, 0], [64, 0],
  [64, 64], [0, 64]]` joins three or four points with a picture. `on_picture:` is one `[across, down]`
  for each point, in the picture's own pixels and in the same order. **The picture repeats past its
  edges like wallpaper**, so a corner can fall at 200 on a picture 64 pixels wide, or at -70, and the
  picture's width and height must each be 1, 2, 4, 8, 16, 32, 64, 128 or 256 pixels (a friendly error
  otherwise). A point's numbers go from -8191 to 8191, with fractions, and so do the viewer's: half of
  what a fraction holds, so no point is ever too far from the viewer to measure. A corner falls from
  -8191 to 8191 picture pixels. The place is written into the cartridge as it is declared and does not
  change shape as the game runs. **Each face shows its picture through a slot** (one for each picture
  the place names), kept in a list the game will be able to re-point as it runs, for walls whose picture
  changes; nothing re-points one yet. The list is declared showing each slot its own picture, so a place
  declared in a scene or a `part` the game starts over shows the same. Friendly errors: no block, no
  faces, a face of other than three or four points, a point the place does not have, a picture that is
  not declared, `on_picture:` that does not give one spot for each point, a number out of range, a name
  with two underscores in a row or one at its end, and a second place of the same name.
- `viewer :eye, at: [x, y, z], facing: { right: [1, 0, 0], up: [0, 1, 0], ahead: [0, 0, 1] }` →
  `DSL::Viewer` — the spot a place is seen from, and which way it faces. `facing:` is three arrows,
  each three numbers of length one and square to the other two (a friendly error otherwise); left out,
  the viewer faces along the place's own arrows. A viewer is twelve variables, and the game moves and
  turns it as it runs:
  - `eye.move :ahead, by: 0.05` — along its own arrows: `:ahead`, `:back`, `:left`, `:right`, `:up`,
    `:down`, by a number or a value the game works out (a whole number or a fraction).
  - `eye.turn :left, by: 2` — degrees, `:left`, `:right`, `:up` (tip up) or `:down`; `eye.roll :left,
    by: 2` rolls round the way it faces, `:left` or `:right`. The angle is a number written in the
    game (one the game works out is refused as not made yet). **Every turn keeps the arrows square and
    of length one**, so a game can turn for as long as it likes and the place never comes out
    stretched: each turn ends by making ahead length one, taking from up whatever part of it lies along
    ahead, making up length one, and making right from the two.
  - `eye.at x, y, z` and `eye.face right: [...], up: [...], ahead: [...]` — set the spot, or the three
    arrows, from numbers or values the game works out (a game with a flight model of its own hands its
    arrows straight in; they are taken as given, not squared up).
  - `eye.spot`, `eye.right_arrow`, `eye.up_arrow`, `eye.ahead_arrow` — read them back, three fractions
    each.

  Worked example: `examples/cube3d.rb`, a crate flown round with the buttons.
- `draw_place :cube, seen_by: eye` — draw the place as the viewer sees it, across the screen or the
  `inside` area it is drawn in. Each point is turned to the viewer, put on the screen, and each face
  filled with its picture, a later face over an earlier one. **A face that reaches nearer than the near
  limit is cut there**, so a wall beside the viewer is drawn up to the limit. **A face is seen from its
  front only**: the side from which its points go round clockwise. Settings: `near: 0.25` (the near
  limit, in wholes, more than 0 and not more than 16), `view_angle: 90` (degrees across, 10 to 170),
  `both_sides: true` (draw a face from behind as well), and `perspective: :none` (a picture stretched
  straight between the corners of its face; `:every_8_pixels` and `:every_pixel` are refused as not
  made yet). **Needs `screen :bitmap, tear_free: true`** (a friendly error on any
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

  A game of rooms draws each room with its own call, far rooms first: the box round a doorway's
  `screen_spot`s is the window of the room beyond (any corner behind: the whole screen; all behind: not
  seen). Worked example: `examples/two_rooms.rb`.

**How it is drawn**, the same on every lowering: the turn, the cut and the projection are statements
the lowering makes like any other (`IR::PlaceDrawing`, fractions with sixteen bits through `mul_fix`
and `div_fix`), and only the fill of a face, of three to eight corners, is written by hand for each
(`Reference#exec_fill_face` is the rule every one follows). So the interpreter and every build draw the same pixels.
Each point is turned and put on the screen once a drawing, however many faces share it, and on the
Advance a face wholly outside the screen or the window is passed over before it is filled, so a
game that draws a room through a doorway's window pays little for the faces the window hides. **What it
costs on the Advance**: the fill takes about 15 of the console's cycles a pixel for a picture with
no see-through pixel (two pixels worked out together and written as one pair), and about 37 for one
with see-through pixels (each pixel reads its pair back first), so a face covering the whole screen
runs at 20 pictures a second, or 10. `examples/cube3d.rb` runs at 60 with 37% of each frame spare,
and `examples/two_rooms.rb`, its walls covering the screen, at 15. `rom.profile`
names the fill "filling the faces of a place with their pictures".

**Each console**: the Advance draws a place (its page says how). The Game Boy Color, the Super
Nintendo and the Sega Genesis refuse `draw_place` in plain words (see their pages); `screen_spot` works
on all four.

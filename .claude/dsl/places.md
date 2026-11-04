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
  otherwise). A point's numbers go from -16383 to 16383, with fractions; a corner from -8191 to 8191
  picture pixels. The place is written into the cartridge as it is declared and does not change shape
  as the game runs. **Each face shows its picture through a slot** (by default the picture's own name),
  kept in a list the game will be able to re-point as it runs, for walls whose picture changes; nothing
  re-points one yet. Friendly errors: no block, no faces, a face of other than three or four points, a
  point the place does not have, a picture that is not declared, `on_picture:` that does not give one
  spot for each point, a number out of range, and a second place of the same name.
- `viewer :eye, at: [x, y, z], facing: { right: [1, 0, 0], up: [0, 1, 0], ahead: [0, 0, 1] }` →
  `DSL::Viewer` — the spot a place is seen from, and which way it faces. `facing:` is three arrows,
  each three numbers of length one and square to the other two (a friendly error otherwise); left out,
  the viewer faces along the place's own arrows. A viewer is twelve variables, so it can be moved and
  turned later; this build sets it where it is declared and nothing moves it yet.
- `draw_place :cube, seen_by: eye, perspective: :none` — draw the place as the viewer sees it, 90
  degrees across the screen, or across the `inside` area it is drawn in. Each point is turned to the
  viewer, put on the screen, and each face filled with its picture, a later face over an earlier one.
  **A face with a corner nearer than a quarter of a whole to the viewer is left out whole** (cutting it
  at that distance is not made yet), and a face is drawn from both sides. `perspective: :none` stretches
  a picture straight between the corners of its face; `:every_8_pixels` and `:every_pixel` are refused
  as not made yet. **Needs `screen :bitmap, tear_free: true`** (a friendly error on any other screen):
  a place is drawn over a whole frame, and on one page the player would see it drawn. It draws over what
  is there and clears nothing.

**How it is drawn**, the same on every lowering: the turn and the projection are statements the
lowering makes like any other (`IR::PlaceDrawing`, fractions with sixteen bits through `mul_fix` and
`div_fix`), and only the fill of a face is written by hand for each (`Reference#exec_fill_face` is
the rule every one follows). So the interpreter and every build draw the same pixels. **What it
costs on the Advance**: the fill takes about 36 of the console's cycles a pixel, so a face covering
the whole screen runs at 12 pictures a second and one 120 pixels square at 30. `rom.profile`
names the fill "filling the faces of a place with their pictures".

**Each console**: the Advance draws a place (its page says how). The Game Boy Color, the Super
Nintendo and the Sega Genesis refuse `draw_place` in plain words naming what they lack (see their pages).

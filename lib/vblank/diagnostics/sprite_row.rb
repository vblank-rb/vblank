# frozen_string_literal: true

module VBlank
  module Diagnostics
    # One sprite the console is drawing, as a test gets it back from {Verifier#sprites}.
    #
    # The console keeps a table of 128 of these and composes the picture from it, and reading that
    # table is how a test asks where something is instead of hunting for its pixels — which cannot
    # tell a hidden sprite from one drawn in the backdrop colour, from one behind a background, or
    # from one a pixel off the edge.
    #
    # What each field is. +name+ is the one the author declared, or nothing for a sprite the
    # framework drew for something nobody named (a letter of text). +x+ and +y+ are where the
    # PICTURE starts — the corner of the canvas the art was drawn on, which is where the game put
    # the sprite — while +piece_x+ and +piece_y+ are the numbers the console itself carries, which
    # are further along by however much the build trimmed the pose being shown. +colors+ is the
    # colours it is wearing and +color_count+ gives how many it draws from, 16 or 256 (see
    # Verifier#colors_drawn_from). The rest — +slot+, +tile+, +palette+, +priority+, +shape+,
    # +size+, the three about being drawn backwards or turned — are the console's own entry.
    # +picture+ is the one of the sprite's pictures it is showing, by the name the game gave it
    # (a mirrored one by the name `mirror` gave back), as the interpreter's row names it: on the
    # first row of a picture cut into pieces, nil on the others and on a row nobody named.
    #
    # Why it is a type rather than a hash, which is what it was. Sixteen fields in a plain Hash
    # means a key that is not one of them reads back as nothing at all, so a test asserting on a
    # name it got slightly wrong passes, or fails for a reason that is not the one it looks like.
    # That is the quiet kind of wrong answer this reader exists to stop giving.
    #
    # There is deliberately no square-bracket reader. One would have kept every place that reads
    # a sprite working untouched, and that is exactly what makes it the wrong trade: the names
    # would still be symbols handed to a lookup, so a wrong one would still fail at the read
    # rather than at the line that wrote it, and nothing would be any safer than the Hash was.
    # Written as +row.color_count+ it is a method, and a name that does not exist cannot be run.
    SpriteRow = Data.define(:name, :x, :y, :slot, :tile, :palette, :color_count, :colors,
                            :priority, :shape, :size, :mirrored_across, :mirrored_down,
                            :turned, :piece_x, :piece_y, :picture)

    # One sprite the reference interpreter drew, which is the oracle's half of the same question
    # (see IR::Backends::Reference#sprites).
    #
    # It has four fields and not seventeen because the interpreter has no console to keep them in:
    # there is no table of 128 places, so there is no place number, no tile, no colour group and
    # nothing about how the picture is stored — and naming a place was the thing worth being rid
    # of. +picture+ is the one of the sprite's pictures the pose selector picked, given as the
    # name the author drew rather than as a number counting into the set.
    #
    # +name+, +x+, +y+ and +picture+ mean exactly what they mean on a {SpriteRow}, and that is the point of
    # them being methods on both: a test comparing the two backends reads them the same way, and
    # neither type will quietly answer a question the other one can.
    DrawnSprite = Data.define(:name, :x, :y, :picture)

    # The sprites a running cartridge showed from one frame's pass, as DrawnSprites, the way the
    # interpreter's `sprites` gives them on that frame (see Verifier#sprites_by_frame).
    SpritesFrame = Data.define(:frame, :sprites)
  end
end

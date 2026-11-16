# frozen_string_literal: true

require "digest"

# A MADE-UP LITTLE ROOM READ FROM A DATA PACK: a computer original that keeps a level as data (as
# Descent keeps its mines), and a game that draws it as a lit place from the pack's slots, its
# shading and its viewer's start too (Builder::PackPlaces). Beside it, the same game written in Ruby,
# which is its answer key.
#
# The room is a back wall and a floor, lit unevenly, with a third face in the faces slot that the
# pack says is not used: a big wall across the view, which shows only if the count is not read.
# The viewer starts a little up and back, turned a little left, and turns each pass.
module PackPlaceGames
  # Colours, places of the pictures, and the shading's two levels, darkest first.
  PALETTE = [0x0000, 0x2108, 0x001F, 0x7FFF].freeze
  ROCK = Array.new(64) { |at| ((at / 8) + at).even? ? 2 : 3 }.freeze
  MOSS = Array.new(64) { |at| (at % 3).zero? ? 1 : 3 }.freeze
  LEVELS = [[0, 0, 1, 1], [0, 1, 2, 3]].freeze

  POINTS = [[-2.0, 1.0, 4.0], [2.0, 1.0, 4.0], [2.0, -1.0, 4.0], [-2.0, -1.0, 4.0],
            [-2.0, -1.0, 1.0], [2.0, -1.0, 1.0],
            [-5.0, 5.0, 2.0], [5.0, 5.0, 2.0], [5.0, -5.0, 2.0], [-5.0, -5.0, 2.0]].freeze
  CORNERS = [[0, 0], [32, 0], [32, 16], [0, 16]].freeze
  FACES = [{ points: [0, 1, 2, 3], picture: 0, on_picture: CORNERS, light: [1.0, 0.75, 0.25, 0.5] },
           { points: [3, 2, 5, 4], picture: 1, on_picture: CORNERS, light: [0.25, 0.25, 0.75, 0.75] }].freeze
  # The face the pack holds and does not use.
  UNUSED_FACE = { points: [6, 7, 8, 9], picture: 0, on_picture: CORNERS, light: [1.0, 1.0, 1.0, 1.0] }.freeze
  # The most the game says there can be.
  MOST_POINTS = 12
  MOST_FACES = 4

  START_AT = [0.0, 0.25, -0.5].freeze
  START_FACING = { right: [0.8, 0.0, -0.6], up: [0.0, 1.0, 0.0], ahead: [0.6, 0.0, 0.8] }.freeze

  # Where each part is in the made-up copy.
  PARTS = { points: 0x000, faces: 0x100, sizes: 0x300, palette: 0x310, fades: 0x320, start: 0x330, walls: 0x400 }.freeze
  COPY_SIZE = 0x480

  PASSES = 6

  # Shareable, since a test may run in a Ractor.
  VBlank::Testing::InRactors.share_constants(self)

  module_function

  def fraction(number) = VBlank::DSL::Fraction.scale(number, VBlank::DSL::Fraction::DEFAULT_BITS)

  # A face as the pack keeps it: its picture, then four corners of point, across, down and light.
  def face_record(face)
    corners = face[:points].zip(face[:on_picture], face[:light]).map do |point, (across, down), light|
      [point, fraction(across), fraction(down), fraction(light)]
    end
    [face[:picture], *corners.flatten]
  end

  def copy_bytes
    copy = "\0".b * COPY_SIZE
    points = POINTS.flatten.map { |number| fraction(number) }
    copy[PARTS[:points], points.length * 4] = points.pack("l<*")
    faces = [*FACES, UNUSED_FACE].flat_map { |face| face_record(face) }
    copy[PARTS[:faces], faces.length * 4] = faces.pack("l<*")
    copy[PARTS[:sizes], 4] = [FACES.length].pack("l<")
    copy[PARTS[:palette], 8] = PALETTE.pack("v*")
    copy[PARTS[:fades], 8] = LEVELS.flatten.pack("C*")
    start = [*START_AT, *START_FACING.values_at(:right, :up, :ahead).flatten].map { |number| fraction(number) }
    copy[PARTS[:start], 48] = start.pack("l<*")
    copy[PARTS[:walls], 128] = [*ROCK, *MOSS].pack("C*")
    copy
  end

  # The made-up original, written into +folder+.
  def original(folder)
    copy = copy_bytes
    path = File.join(folder, "made_up_level.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up Level", setting: "MADE_UP_LEVEL", env: { "MADE_UP_LEVEL" => path }, platform: :pc,
                               settings_file: File.join(folder, "made_up_level.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The room's data pack, declared on +builder+ from the original +from+.
  def room_pack(builder, from)
    builder.data_pack(from: from, version: "1") do |slots|
      slots.numbers :points, at: PARTS[:points], count: MOST_POINTS * 3, width: :word, signed: true
      slots.numbers :faces, at: PARTS[:faces], count: MOST_FACES * VBlank::IR::PlaceDrawing::FACE_STRIDE, width: :word, signed: true
      slots.numbers :sizes, at: PARTS[:sizes], count: 1, width: :word, signed: true
      slots.colors :palette, at: PARTS[:palette], count: PALETTE.length, layout: :gba
      slots.numbers :fades, at: PARTS[:fades], count: LEVELS.flatten.length, width: :byte, signed: false
      slots.numbers :start, at: PARTS[:start], count: 12, width: :word, signed: true
      slots.pixels :walls, at: PARTS[:walls], count: 128
    end
  end

  # The game drawing the room from the pack, built as +options+ say: its program and the pack file
  # it made (nil with the pack left out).
  def pack_room_game(folder, options)
    from = original(folder)
    builder = VBlank::Builder.new(options: options)
    builder.instance_eval do
      pack = PackPlaceGames.room_pack(self, from)
      screen :bitmap, tear_free: true
      image :rock, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].pixels(0, 64)
      image :moss, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].pixels(64, 64)
      shading :fade, colors: pack[:palette], levels: pack[:fades]
      place :room, points: pack[:points], faces: pack[:faces], faces_used: pack[:sizes].number(0),
                   pictures: %i[rock moss], shading: :fade
      eye = viewer :eye, at: pack[:start].as_numbers(at: 0, count: 3, width: :word, signed: true),
                         facing: pack[:start].as_numbers(at: 12, count: 9, width: :word, signed: true)
      PackPlaceGames.play_room(self, eye)
    end
    builder.finalize_program
    [builder.program, builder.made_data_pack_file]
  end

  # The same game with its room written in Ruby: the answer key.
  def ruby_room_game
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap, tear_free: true
      image :rock, width: 8, height: 8, data: ROCK.map { |place| PALETTE[place] }
      image :moss, width: 8, height: 8, data: MOSS.map { |place| PALETTE[place] }
      shading :fade, colors: PALETTE, levels: LEVELS
      place :room, points: POINTS.first(6), faces: FACES, pictures: %i[rock moss], shading: :fade
      eye = viewer :eye, at: START_AT, facing: START_FACING
      PackPlaceGames.play_room(self, eye)
    end
    builder.finalize_program
    builder.program
  end

  # What both games do each pass: draw the room, then turn the viewer.
  def play_room(game, eye)
    game.instance_eval do
      game_loop do
        clear_screen :black
        draw_place :room, seen_by: eye, both_sides: true
        eye.turn :left, by: 2
        wait_vblank
      end
    end
  end
end

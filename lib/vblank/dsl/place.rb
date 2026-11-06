# frozen_string_literal: true

module VBlank
  module DSL
    # What `place :cube do ... end` hands back: a place made of flat faces, to be drawn as a viewer
    # sees it (`draw_place :cube, seen_by: eye`).
    #
    # A place is POINTS — spots in space, each three numbers: across (x, to the right), up (y)
    # and ahead (z) — and FACES, each a flat side joining three or four of the points in order,
    # with a picture on it. A face's CORNERS set where on its picture each of its points falls
    # (`on_picture:`, in the picture's own pixels, across then down). The picture repeats past
    # its edges like wallpaper, so a corner may fall at 200 on a picture 64 pixels wide, or at -70.
    #
    #   place :cube do
    #     a = point -1.0, -1.0, 1.0
    #     ...
    #     face a, b, c, d, picture: :crate, on_picture: [[0, 0], [64, 0], [64, 64], [0, 64]]
    #   end
    #
    # The block runs while the game is built. Its numbers are written into the cartridge as they
    # are; nothing about the place's shape changes as the game runs. Which picture each face shows
    # is kept in a picture SLOT, one for each picture the place lists and named after it, and the
    # game can point a slot at any of the place's pictures as it runs (Builder#change_picture):
    # every face that starts with that picture then shows the other.
    class Place
      # The most a point's number can be either way, and the viewer's: half of what a fraction
      # holds, so a point is never further from the viewer than a fraction holds, along any
      # arrow (see IR::PlaceDrawing, "WHY NOTHING OVERFLOWS").
      FURTHEST = IR::PlaceDrawing::FURTHEST

      # The most a corner can fall past the picture's corner, in picture pixels, either way.
      FURTHEST_ON_PICTURE = 8_191

      # The keys a face takes when the place is declared from data (#declare_from_data), and the
      # ones it cannot do without.
      FACE_KEYS = %i[points picture on_picture light].freeze
      NEEDED_FACE_KEYS = %i[points picture on_picture].freeze

      # What each of a point's numbers, and each of a corner's on its picture, is called in a refusal.
      POINT_AXES = %w[x y z].freeze
      PICTURE_AXES = %w[across down].freeze

      # How a refusal names a point or a face of the block form; a place from data names each by
      # its number in its list instead (#declare_from_data).
      POINT_LABEL = "a point"
      FACE_LABEL = "a face"

      # The most of a value's inspect a refusal shows.
      INSPECT_LENGTH = 60

      # +name+ is the place's name, and +images+ each declared picture's [width, height] by name.
      def initialize(name, images)
        @name = name
        @images = images
        @points = []
        @faces = []
        @listed_pictures = []
        @point_label = POINT_LABEL
        @face_label = FACE_LABEL
      end

      attr_reader :name

      # Each point, [x, y, z] as fractions with sixteen bits.
      attr_reader :points

      # Each face, its slot number and its corners, each [point, u, v, light] (each a fraction with
      # sixteen bits), four of them: a face of three gives its last corner twice.
      attr_reader :faces

      # Every picture the place lists, by number: the picture each slot shows to start with.
      attr_reader :listed_pictures

      # The shading the place is lit by (`place :mine, shading: :fade`), or nil.
      attr_accessor :shading

      # For a place with a shading, the light the game adds to each point as it runs, a List of
      # fractions by point number, all nought to start with: a lamp that flickers, a light the
      # viewer carries. A corner's light is its face's own for it and its point's here, held to 1.
      attr_accessor :point_lights

      # A spot in the place: +x+ across, +y+ up and +z+ ahead, each a number. Returns the point,
      # for `face` to name.
      def point(x, y, z)
        coordinates = [x, y, z].zip(POINT_AXES).map { |number, axis| point_number(number, axis) }
        @points << coordinates
        @points.length - 1
      end

      # A flat side joining +points+ (three or four, from `point`, in order round the face), showing
      # +picture+, its corners falling on it where +on_picture+ sets ([across, down] for each
      # point, in the same order). +light+ is how lit each corner is, from 0 (dark) to 1 (as
      # bright as the shading goes), one for each point, or one for them all; a place drawn with a
      # shading blends it across the face.
      #
      # +picture+ is a declared picture's name, or the number of one the place lists already (see
      # #pictures), as a level file numbers its pictures. A name may be a String, as a file read
      # with JSON gives one.
      def face(*points, picture:, on_picture:, light: 1.0)
        refuse_wrong_point_count!(points)
        points.each { |point| refuse_unknown_point!(point) }
        picture = listed_picture_named(picture) if picture.is_a?(Integer)
        picture = picture.to_sym if picture.is_a?(String)
        refuse_unknown_picture!(picture)
        refuse_mismatched_corners!(points, on_picture)
        lights = corner_lights(points, light)
        corners = points.zip(on_picture, lights).map do |point, spot, lit|
          [point, *spot.zip(PICTURE_AXES).map { |number, axis| scale_corner_on_picture(number, axis) }, lit]
        end
        corners << corners.last if corners.length == 3
        list_picture(picture)
        @faces << [@listed_pictures.index(picture), corners]
        @faces.length - 1
      end

      # Pictures the place can show that no face starts with: the frames a door slides through, or
      # a wall's animation, for the game to point a slot at as it runs (Builder#change_picture).
      # Each is given a number, after the pictures listed before it, and has a slot of its own.
      # A name may be a String, as a file read with JSON gives one.
      def pictures(*names)
        names.map { |picture| picture.is_a?(String) ? picture.to_sym : picture }.each do |picture|
          refuse_unknown_picture!(picture)
          list_picture(picture)
        end
      end

      # The number of +picture+ (a name, or a number already) among the pictures the place lists, in
      # the order it lists them: what `change_picture ..., to:` takes as a value the game works out.
      # A picture's slot has the same number. Raises a friendly error for a picture not listed.
      def picture_number(picture)
        return picture if listed_number?(picture)

        if picture.is_a?(Integer)
          raise ArgumentError, "place :#{@name} has no picture #{picture}. It lists #{@listed_pictures.length} " \
                               "pictures, numbered from 0. To fix this, give a number from 0 to " \
                               "#{@listed_pictures.length - 1}, or a picture's name."
        end

        @listed_pictures.index(picture) or
          raise ArgumentError, "place :#{@name} does not list the picture #{picture.inspect}. To fix this, name it " \
                               "in a face, or with `pictures #{picture.inspect}` in the place."
      end

      # The number of slot +slot+ (the name of the picture it starts with, or its number). Raises a
      # friendly error for a slot the place does not have.
      def slot_number(slot)
        return slot if listed_number?(slot)
        return @listed_pictures.index(slot) if @listed_pictures.include?(slot)

        raise ArgumentError, "place :#{@name} has no slot #{slot.inspect}. Each slot has the name of a picture that " \
                             "the place lists: #{@listed_pictures.map(&:inspect).join(', ')}. To fix this, give one " \
                             "of those names, or its number from 0 to #{@listed_pictures.length - 1}."
      end

      # THE PLACE FROM DATA, as a game reads a level from a file: +points+ is each point's [x, y, z],
      # and +faces+ each face as a Hash of what `face` takes, its points by their number in
      # +points+: { points: [0, 1, 2, 3], picture: :rock, on_picture: [...], light: 0.5 }. Each is
      # declared through #point and #face, so the place is the one those calls make, checked the
      # same way; a refusal names the point or face by its number in its list.
      #
      # While it runs, the label a refusal names the point or face by is that one's number in its
      # list ("face 12 (in faces:)") rather than the block form's "a face".
      def declare_from_data(points, faces)
        refuse_non_array!("points", points, "each [x, y, z]")
        refuse_non_array!("faces", faces, "each a hash like { points: [0, 1, 2], picture: :wall, on_picture: [...] }")
        points.each_with_index do |spot, k|
          @point_label = "point #{k} (in points:)"
          refuse_unfit_spot!(spot)
          point(*spot)
        end
        faces.each_with_index do |shown, k|
          @face_label = "face #{k} (in faces:)"
          refuse_unfit_face_data!(shown)
          face(*shown[:points], **shown.except(:points))
        end
      ensure
        @point_label = POINT_LABEL
        @face_label = FACE_LABEL
      end

      # The points as a table holds them: three numbers a point.
      def points_table = @points.flatten

      # The faces as a table holds them (see IR::PlaceDrawing::FACE_STRIDE).
      def faces_table = @faces.flat_map { |slot, corners| [slot, *corners.flatten] }

      private

      def list_picture(picture)
        @listed_pictures << picture unless @listed_pictures.include?(picture)
      end

      def listed_number?(number) = number.is_a?(Integer) && number.between?(0, @listed_pictures.length - 1)

      # The name of picture number +number+ among those the place lists, for a face that names its
      # picture by number. Raises a friendly error for a number the place does not list.
      def listed_picture_named(number)
        return @listed_pictures[number] if listed_number?(number)

        listed = case @listed_pictures.length
                 when 0 then "the place lists no pictures yet"
                 when 1 then "the place lists 1 picture, number 0"
                 else "the place lists #{@listed_pictures.length} pictures, numbered 0 to #{@listed_pictures.length - 1}"
                 end
        raise ArgumentError, "place :#{@name} has #{@face_label} with the picture #{number}, and #{listed}. A place " \
                             "lists the pictures in pictures:, then each picture that a face names first. To fix " \
                             "this, give a number that the place lists, or a picture's name."
      end

      # +text+'s inspect, cut to a length a message can hold.
      def shortened(text)
        shown = text.inspect
        shown.length > INSPECT_LENGTH ? "#{shown[0, INSPECT_LENGTH]}..." : shown
      end

      # +keys+ as a message lists them: "points:, picture:, on_picture:".
      def keys_listed(keys) = keys.map { |key| "#{key}:" }.join(", ")

      def refuse_non_array!(key, list, shape_of_each)
        return if list.is_a?(Array)

        raise ArgumentError, "place :#{@name} was given #{key}: #{shortened(list)}. #{key}: must be a list, " \
                             "#{shape_of_each}. To fix this, give #{key}: a list."
      end

      def refuse_unfit_spot!(spot)
        return if spot.is_a?(Array) && spot.length == 3

        raise ArgumentError, "place :#{@name} has #{@point_label} that is #{shortened(spot)}. A point is three " \
                             "numbers: x, y and z. To fix this, give [x, y, z]."
      end

      # A face from data is a Hash of the keys `face` takes, with symbols for keys, and its points a list.
      def refuse_unfit_face_data!(shown)
        refuse_face_not_hash!(shown)
        refuse_string_face_keys!(shown)
        refuse_unknown_face_key!(shown)
        refuse_missing_face_key!(shown)
        refuse_face_points_not_list!(shown)
      end

      def refuse_face_not_hash!(shown)
        return if shown.is_a?(Hash)

        raise ArgumentError, "place :#{@name} has #{@face_label} that is #{shortened(shown)}. A face is a hash with " \
                             "#{keys_listed(FACE_KEYS)}. To fix this, give a face like { points: [0, 1, 2, 3], " \
                             "picture: :wall, on_picture: [[0, 0], [64, 0], [64, 64], [0, 64]] }."
      end

      def refuse_string_face_keys!(shown)
        return unless shown.keys.any?(String)

        raise ArgumentError, "place :#{@name} has #{@face_label} whose keys are strings: " \
                             "#{shown.keys.map(&:inspect).join(', ')}. The keys of a face are symbols. To fix this, " \
                             "read the file with `JSON.parse(text, symbolize_names: true)`, or give symbols."
      end

      def refuse_unknown_face_key!(shown)
        unknown = shown.keys - FACE_KEYS
        return if unknown.empty?

        raise ArgumentError, "place :#{@name} has #{@face_label} with the key #{unknown.first.inspect}. A face takes " \
                             "#{keys_listed(FACE_KEYS)}. To fix this, remove that key."
      end

      def refuse_missing_face_key!(shown)
        missing = NEEDED_FACE_KEYS - shown.keys
        return if missing.empty?

        raise ArgumentError, "place :#{@name} has #{@face_label} with no #{missing.first}:. A face needs " \
                             "#{keys_listed(NEEDED_FACE_KEYS)}. To fix this, give it #{missing.first}:."
      end

      def refuse_face_points_not_list!(shown)
        return if shown[:points].is_a?(Array)

        raise ArgumentError, "place :#{@name} has #{@face_label} with points: #{shortened(shown[:points])}. In a " \
                             "face, points: is a list of point numbers. To fix this, give a list like [0, 1, 2]."
      end

      # Each corner's light as the faces table keeps it: sixteen bits of fraction, held just under
      # one (IR::Nodes::FillFace::LIGHTEST).
      def corner_lights(points, light)
        lights = light.is_a?(Array) ? light : [light] * points.length
        unless lights.length == points.length && lights.all? { |each| each.is_a?(Numeric) && each.between?(0, 1) }
          raise ArgumentError, "place :#{@name} has #{@face_label} with light: #{light.inspect}. light: is a number from 0 " \
                               "to 1, or one such number for each of the face's #{points.length} points. To fix " \
                               "this, give numbers like 1.0 or [1.0, 0.5, 0.5, 1.0]."
        end

        lights.map { |each| [Fraction.scale(each, Fraction::DEFAULT_BITS), IR::Nodes::FillFace::LIGHTEST].min }
      end

      def point_number(number, axis)
        unless number.is_a?(Numeric) && number.abs <= FURTHEST
          raise ArgumentError, "place :#{@name} has #{@point_label} whose #{axis} is #{number.inspect}. A point needs " \
                               "three numbers from -#{FURTHEST} to #{FURTHEST}. To fix this, give numbers in that range."
        end

        Fraction.scale(number, Fraction::DEFAULT_BITS)
      end

      def scale_corner_on_picture(number, axis)
        unless number.is_a?(Numeric) && number.abs <= FURTHEST_ON_PICTURE
          raise ArgumentError, "place :#{@name} has #{@face_label} with a corner #{number.inspect} pixels #{axis} its " \
                               "picture. A corner must fall from -#{FURTHEST_ON_PICTURE} to #{FURTHEST_ON_PICTURE} " \
                               "pixels. To fix this, give numbers in that range."
        end

        Fraction.scale(number, Fraction::DEFAULT_BITS)
      end

      def refuse_wrong_point_count!(points)
        return if [3, 4].include?(points.length)

        raise ArgumentError, "place :#{@name} has #{@face_label} with #{points.length} points. A face joins 3 or 4 points. " \
                             "To fix this, split the face into faces of 3 or 4 points."
      end

      def refuse_unknown_point!(point)
        return if point.is_a?(Integer) && point.between?(0, @points.length - 1)

        numbered = @points.empty? ? "It has no points yet" : "Its points are numbered 0 to #{@points.length - 1}"
        raise ArgumentError, "place :#{@name} has #{@face_label} with the point #{point.inspect}, and the place has no " \
                             "point #{point.inspect}. #{numbered}. To fix this, give the face the numbers of points " \
                             "that the place has."
      end

      def refuse_unknown_picture!(picture)
        size = @images[picture]
        unless size
          raise ArgumentError, "place :#{@name} has #{@face_label} with the picture #{picture.inspect}, and there is no such " \
                               "image. To fix this, declare it with `image :#{picture}, ...` before the place."
        end
        return if size.all? { |side| side.positive? && side <= 256 && (side & (side - 1)).zero? }

        raise ArgumentError, "place :#{@name} has #{@face_label} with the picture :#{picture}, which is #{size[0]} by " \
                             "#{size[1]} pixels. A picture on a face repeats past its edges, so each side must be " \
                             "1, 2, 4, 8, 16, 32, 64, 128 or 256 pixels. To fix this, make the picture one of those sizes."
      end

      def refuse_mismatched_corners!(points, on_picture)
        return if on_picture.is_a?(Array) && on_picture.length == points.length &&
                  on_picture.all? { |spot| spot.is_a?(Array) && spot.length == 2 }

        raise ArgumentError, "place :#{@name} has #{@face_label} of #{points.length} points, and its on_picture: does not " \
                             "give #{points.length} spots. To fix this, give one [across, down] for each point, " \
                             "in the same order."
      end
    end
  end
end

# frozen_string_literal: true

module VBlank
  module DSL
    # What `place :cube do ... end` hands back: a place made of flat faces, to be drawn as a viewer
    # sees it (`draw_place :cube, seen_by: eye`).
    #
    # A place is POINTS — spots in space, each three numbers: across (x, to the right), up (y)
    # and ahead (z) — and FACES, each a flat side joining three or four of the points in order,
    # with a picture on it. A face's CORNERS say where on its picture each of its points falls
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
    # is kept in a picture SLOT the face names (by default the picture's own name), so a later
    # change can swap the picture a slot shows while the game runs.
    class Place
      # The most a point's number can be either way, and the viewer's: half of what a fraction
      # holds, so a point is never further from the viewer than a fraction holds, along any
      # arrow (see IR::PlaceDrawing, "WHY NOTHING OVERFLOWS").
      FURTHEST = IR::PlaceDrawing::FURTHEST

      # The most a corner can fall past the picture's corner, in picture pixels, either way.
      FURTHEST_ON_PICTURE = 8_191

      # +name+ is the place's name, and +images+ each declared picture's [width, height] by name.
      def initialize(name, images)
        @name = name
        @images = images
        @points = []
        @faces = []
        @slots = []
      end

      attr_reader :name

      # Each point, [x, y, z] as fractions with sixteen bits.
      attr_reader :points

      # Each face, its slot number and its corners, each [point, u, v, light] (each a fraction with
      # sixteen bits), four of them: a face of three gives its last corner twice.
      attr_reader :faces

      # The picture each slot shows to start with, in slot order.
      attr_reader :slots

      # The shading the place is lit by (`place :mine, shading: :fade`), or nil.
      attr_accessor :shading

      # For a place with a shading, the light the game adds to each point as it runs, a List of
      # fractions by point number, all nought to start with: a lamp that flickers, a light the
      # viewer carries. A corner's light is its face's own for it and its point's here, held to 1.
      attr_accessor :point_lights

      # A spot in the place: +x+ across, +y+ up and +z+ ahead, each a number. Returns the point,
      # for `face` to name.
      def point(x, y, z)
        coordinates = [x, y, z].each_with_index.map { |number, axis| point_number(number, %w[x y z][axis]) }
        @points << coordinates
        @points.length - 1
      end

      # A flat side joining +points+ (three or four, from `point`, in order round the face), showing
      # +picture+, its corners falling on it where +on_picture+ says ([across, down] for each
      # point, in the same order). +light+ is how lit each corner is, from 0 (dark) to 1 (as
      # bright as the shading goes), one for each point, or one for them all; a place drawn with a
      # shading blends it across the face.
      def face(*points, picture:, on_picture:, light: 1.0)
        refuse_wrong_point_count!(points)
        points.each { |point| refuse_unknown_point!(point) }
        refuse_unknown_picture!(picture)
        refuse_mismatched_corners!(points, on_picture)
        lights = corner_lights(points, light)
        corners = points.zip(on_picture, lights).map do |point, spot, lit|
          [point, *spot.each_with_index.map { |number, axis| picture_number(number, %w[across down][axis]) }, lit]
        end
        corners << corners.last if corners.length == 3
        @slots << picture unless @slots.include?(picture)
        @faces << [@slots.index(picture), corners]
        @faces.length - 1
      end

      # The points as a table holds them: three numbers a point.
      def points_table = @points.flatten

      # The faces as a table holds them (see IR::PlaceDrawing::FACE_STRIDE).
      def faces_table = @faces.flat_map { |slot, corners| [slot, *corners.flatten] }

      private

      # Each corner's light as the faces table keeps it: sixteen bits of fraction, held just under
      # one (IR::Nodes::FillFace::LIGHTEST).
      def corner_lights(points, light)
        lights = light.is_a?(Array) ? light : [light] * points.length
        unless lights.length == points.length && lights.all? { |each| each.is_a?(Numeric) && each.between?(0, 1) }
          raise ArgumentError, "place :#{@name} has a face with light: #{light.inspect}. light: is a number from 0 " \
                               "to 1, or one such number for each of the face's #{points.length} points. To fix " \
                               "this, give numbers like 1.0 or [1.0, 0.5, 0.5, 1.0]."
        end

        lights.map { |each| [Fraction.scale(each, Fraction::DEFAULT_BITS), IR::Nodes::FillFace::LIGHTEST].min }
      end

      def point_number(number, axis)
        unless number.is_a?(Numeric) && number.abs <= FURTHEST
          raise ArgumentError, "place :#{@name} has a point whose #{axis} is #{number.inspect}. A point needs " \
                               "three numbers from -#{FURTHEST} to #{FURTHEST}. To fix this, give numbers in that range."
        end

        Fraction.scale(number, Fraction::DEFAULT_BITS)
      end

      def picture_number(number, axis)
        unless number.is_a?(Numeric) && number.abs <= FURTHEST_ON_PICTURE
          raise ArgumentError, "place :#{@name} has a face with a corner #{number.inspect} pixels #{axis} its " \
                               "picture. A corner must fall from -#{FURTHEST_ON_PICTURE} to #{FURTHEST_ON_PICTURE} " \
                               "pixels. To fix this, give numbers in that range."
        end

        Fraction.scale(number, Fraction::DEFAULT_BITS)
      end

      def refuse_wrong_point_count!(points)
        return if [3, 4].include?(points.length)

        raise ArgumentError, "place :#{@name} has a face with #{points.length} points. A face joins 3 or 4 points. " \
                             "To fix this, split the face into faces of 3 or 4 points."
      end

      def refuse_unknown_point!(point)
        return if point.is_a?(Integer) && point.between?(0, @points.length - 1)

        raise ArgumentError, "place :#{@name} has a face with the point #{point.inspect}, and the place has no such " \
                             "point. To fix this, give the face points that `point` made in this place."
      end

      def refuse_unknown_picture!(picture)
        size = @images[picture]
        unless size
          raise ArgumentError, "place :#{@name} has a face with the picture #{picture.inspect}, and there is no such " \
                               "image. To fix this, declare it with `image :#{picture}, ...` before the place."
        end
        return if size.all? { |side| side.positive? && side <= 256 && (side & (side - 1)).zero? }

        raise ArgumentError, "place :#{@name} has a face with the picture :#{picture}, which is #{size[0]} by " \
                             "#{size[1]} pixels. A picture on a face repeats past its edges, so each side must be " \
                             "1, 2, 4, 8, 16, 32, 64, 128 or 256 pixels. To fix this, make the picture one of those sizes."
      end

      def refuse_mismatched_corners!(points, on_picture)
        return if on_picture.is_a?(Array) && on_picture.length == points.length &&
                  on_picture.all? { |spot| spot.is_a?(Array) && spot.length == 2 }

        raise ArgumentError, "place :#{@name} has a face of #{points.length} points, and its on_picture: does not " \
                             "give #{points.length} spots. To fix this, give one [across, down] for each point, " \
                             "in the same order."
      end
    end
  end
end

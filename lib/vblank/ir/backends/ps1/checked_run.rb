# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # A PlayStation program played in the emulator (HeadlessRun), and then the same buttons, pass for
        # pass, played on the interpreter — stopping at the first pass the two disagree on, about any
        # variable, any list or pool, or any pixel (CartridgeCheck says how).
        #
        # It takes the interpreter's calls, so a test written against Reference.new can be handed one of
        # these instead and play its game on a PlayStation with nothing else changed. The interpreter plays
        # the program on the PlayStation's screen, 320×240, and the two pictures are compared over it.
        #
        # THE FACES OF A PLACE ARE THE CHIP'S. The PlayStation's graphics chip fills them, by rules of its
        # own (Runtime::Faces says why), so the interpreter is told to fill each face the way the chip
        # does: the triangles the runtime sends for it (FacePieces) drawn by the chip's rules
        # (PolygonFill). Everything the place's drawing works out — turning, cutting at
        # the near limit, where each corner lands, `screen_spot` — is still the interpreter's own, and the
        # whole picture is still compared, every pixel with none let off.
        class CheckedRun < HeadlessRun
          include CartridgeCheck

          def initialize(save: SaveImage.new)
            super
            @faces = FacesByChip.new(PolygonFill.new)
          end

          # The faces drawn on the interpreter's side with +polygon_fill+ (a PS1::PolygonFill)
          # in place of the chip's own rules: a test hands it a model with a rule wrong, to show the check
          # catches one. Returns self.
          def use_polygon_fill(polygon_fill)
            @faces = FacesByChip.new(polygon_fill)
            self
          end

          private

          def prepare_interpreter(interpreter) = interpreter.fill_faces_with(@faces)

          # Reference#fill_faces_with's filler: one face as the chip fills it.
          class FacesByChip
            def initialize(polygon_fill)
              @polygon_fill = polygon_fill
            end

            # The face the interpreter worked out, painted on +screen+ (a Reference::Framebuffer): its edges
            # held to the area drawing is held to, as the runtime holds them, then each triangle the
            # runtime sends filled inside them. Lit by +shade+ (a Reference::Shade), each triangle is shaded
            # by the chip: each texel multiplied by the colour stepped across it from its corners
            # (PolygonFill.modulated).
            def fill_face(screen, picture:, pixels:, corners:, edges:, spans:, shade:)
              area = screen.area || [0, 0, screen.width, screen.height]
              left, top, right, bottom = edges
              held = [[left, area[0]].max, [top, area[1]].max, [right, area[2]].min, [bottom, area[3]].min]
              triangles = FacePieces.triangles(corners: corners, edges: held, spans: spans, width: picture.width,
                                               height: picture.height, levels: shade ? shade.level_count : 0)
              drawing_area = [held[0], held[1], held[2] - 1, held[3] - 1]
              triangles.each do |triangle|
                @polygon_fill.fill(triangle.corners, drawing_area) do |x, y, u, v, c|
                  at = (((v & (picture.height - 1)) * picture.width) + (u & (picture.width - 1))) * 2
                  color = pixels.getbyte(at) | (pixels.getbyte(at + 1) << 8)
                  next if picture.transparent && color == picture.transparent

                  color = PolygonFill.modulated(color, c) if c
                  screen.set_pixel(x, y, color)
                end
              end
            end
          end
        end
      end
    end
  end
end

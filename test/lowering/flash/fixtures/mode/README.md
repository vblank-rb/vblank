# The original Mode's traces

`attract1.trace` and `attract2.trace` are what the original Mode (Adam Saltsman's flixel demo game, MIT licence)
did, update by update, while it played each of its two attract-mode replays from start-up. They are the answer key
the remake in `examples/mode/` is held to. One line each:

    update N HASH      after update N's picture is drawn: CRC-32 of the 320x240 picture, each pixel cut to
                       5 bits a channel and packed as a 15-bit colour (red lowest), two bytes each, low
                       byte first: the number VBlank's `picture-crc` line is, for a 15-bit picture
    sound NAME V PAN   a sound started (its embedded class's name, its volume, its pan), just before the
                       update line of the update that started it
    end N              the replay ended in update N (the replay's 22-second limit is 1,100 updates); it comes
                       just before the last update's own line, which is the picture after it

The picture is Ruffle's, not Flash Player's: text is drawn into bitmaps by Ruffle's renderer.

## How they were made

1. Sources, kept outside the repository: `Mode-source.tar.gz` (AdamAtomic/Mode at cb6bdaeaf8d5) and
   `flixel-4d6f5e8a.tar.gz` (AdamAtomic/flixel at 4d6f5e8a1986), unpacked beside each other as `Mode/` and
   `flixel/`. Apply the patch from that folder: `patch -p1 < instrument.patch`.
2. The Flex SDK 4.16.1 with `playerglobal-10.1.swc` copied to `frameworks/libs/player/10.1/playerglobal.swc`, and
   `PLAYERGLOBAL_HOME` set to `<sdk>/frameworks/libs/player`. For each replay N (1 or 2):

       mxmlc +playerglobal.version=10.1 -target-player=10.1 -swf-version=10 -omit-trace-statements=false \
         -define=CONFIG::attract,N -source-path+=Mode/src -source-path+=flixel \
         -static-link-runtime-shared-libraries=true -o ModeN.swf Mode/src/Mode.as

   (`-omit-trace-statements=false` keeps the traces, which mxmlc leaves out unless told.)
3. Play it in the harness, with the renderer (the game draws text into bitmaps, which the harness's null renderer
   cannot do; `--render` is software Vulkan, Mesa's lavapipe: `mesa-vulkan-drivers`), and keep standard output:

       VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json \
         flash_player_harness ModeN.swf --frames 1300 --render > attractN.trace

   A run takes about 40 seconds. Two runs give the same file.

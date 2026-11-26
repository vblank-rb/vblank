# ruby-flash-player

Plays a Flash program (a `.swf`) with no window and no sound device, a frame at a time, and reads
back what it traced. VBlank uses it to check the Flash build (`--format=flash`); building a game
needs none of it, only Haxe.

It is [Ruffle](https://ruffle.rs), the open-source Flash player, run by a small Rust program, the
harness (`harness/`). The harness takes Ruffle's crates by path from `ruffle/`, with Ruffle's own
`Cargo.lock`, so the libraries are the ones that release was built with and nothing else is fetched
but what that lock names.

    flash_player_harness GAME.swf --frames N [--tape TAPE] [--real-time] [--render]

Each `trace()` the movie makes is printed to standard output, one line each. A tape has one key
press a line, `FRAME KEY down` or `FRAME KEY up`; a key on frame F is pressed just before frame F
runs. Frames count from 1: the movie's first frame, which builds it, comes before frame 1. Keys are
`left right up down space enter escape tab backspace shift control f1`..`f9`, or one character. A movie
that plays by its own clock (`getTimer`, which is the machine's, not the player's) is given `--real-time`, which
waits out each frame. A movie that draws into bitmaps (`BitmapData.draw`: a text field into a bitmap, as flixel does)
is given `--render`: software Vulkan, Mesa's lavapipe (`mesa-vulkan-drivers`; `VK_ICD_FILENAMES` names its
`lvp_icd.json` where the loader does not find it). A movie that asks to stop (`fscommand("rg_exit", "CODE:MESSAGE")`)
ends the run early with that code.

    flash_player_harness GAME.swf --headless FRAMES [--picture-out FILE] [OPTIONS...]

For a game built to be tested (see `harness/src/bridge.rs`, and `runtime/rg_headless.hx` in the Flash build):
it is told the frames and the options, answers the buttons the game asks for from standard input, writes the
picture file when asked (the line `picture`), and exits with the code the game gives.

## Building it

1. Rust (the stable toolchain): `curl https://sh.rustup.rs -sSf | sh -s -- -y`.
2. Ruffle's source. `rake unpack_ruffle` unpacks it from the zip `RUFFLE_SOURCE_ZIP` names
   (`ruffle-nightly-2026_11_24-reproducible-source.zip`) into `ruffle/`. It needs no network.
3. `rake compile`, or `rake compile_flash_player` from the repository's root. The first build
   fetches Ruffle's libraries from crates.io, so it needs the network; it takes a few minutes.

The program is built into `harness/target/release/flash_player_harness`, and again only when its
source, its Cargo files or Ruffle's folder name changed. `VBLANK_FLASH_HARNESS` points VBlank at a
harness built somewhere else.

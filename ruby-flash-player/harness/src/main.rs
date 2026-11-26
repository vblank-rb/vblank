//! Plays a .swf in Ruffle with no window and no sound device, one frame at a time.
//!
//! flash_player_harness GAME.swf --frames N [--tape TAPE] [--real-time] [--render]
//!
//! Every trace() the movie makes is printed to standard output, one line each, as it happens. A tape has one
//! line per key press: "FRAME KEY down" or "FRAME KEY up". A key on frame F is pressed just before frame F
//! runs. Frames are numbered from 1; the movie's first, which builds it, is not counted. The movie's own
//! clock (getTimer) is the machine's, so a movie that plays by it is given --real-time, which waits out each
//! frame's time before the next. A movie that draws into bitmaps (BitmapData.draw) is given --render. A movie that asks to stop (fscommand "rg_exit", "CODE:MESSAGE") ends the run early.
//!
//! flash_player_harness GAME.swf --headless FRAMES [--picture-out FILE] [--save FILE] [OPTIONS...]
//!
//! The same, for a game built to be tested (see bridge.rs): what it asks of the harness is answered from
//! standard input, a line at a time, and it is told FRAMES and the options it did not take itself.
mod audio;
mod bridge;
mod keys;

use ruffle_core::backend::log::LogBackend;
use ruffle_core::limits::ExecutionLimit;
use ruffle_core::tag_utils::SwfMovieData;
use ruffle_core::{FloatDuration, PlayerBuilder, PlayerEvent};
use ruffle_input_format::AutomatedKey;
use std::cell::Cell;
use std::io::Write;
use std::process::exit;
use std::rc::Rc;

/// Prints each trace as it happens, and notes that the movie asked for buttons.
struct PrintingLog {
    asked_for_buttons: Rc<Cell<bool>>,
}

impl LogBackend for PrintingLog {
    fn avm_trace(&self, message: &str) {
        if message == "buttons?" {
            self.asked_for_buttons.set(true);
        }
        let mut out = std::io::stdout().lock();
        let _ = writeln!(out, "{message}");
        if message == "buttons?" {
            let _ = out.flush();
        }
    }

    fn avm_warning(&self, message: &str) {
        eprintln!("Warning: {message}");
    }
}

struct KeyPress {
    frame: u32,
    key: AutomatedKey,
    down: bool,
}

fn fail(message: &str) -> ! {
    eprintln!("flash_player_harness: {message}");
    exit(2);
}

fn key_named(name: &str) -> AutomatedKey {
    match name {
        "left" => AutomatedKey::ArrowLeft,
        "right" => AutomatedKey::ArrowRight,
        "up" => AutomatedKey::ArrowUp,
        "down" => AutomatedKey::ArrowDown,
        "space" => AutomatedKey::Space,
        "enter" => AutomatedKey::Enter,
        "escape" => AutomatedKey::Escape,
        "tab" => AutomatedKey::Tab,
        "backspace" => AutomatedKey::Backspace,
        "shift" => AutomatedKey::LeftShift,
        "control" => AutomatedKey::LeftControl,
        "f1" => AutomatedKey::F1,
        "f2" => AutomatedKey::F2,
        "f3" => AutomatedKey::F3,
        "f4" => AutomatedKey::F4,
        "f5" => AutomatedKey::F5,
        "f6" => AutomatedKey::F6,
        "f7" => AutomatedKey::F7,
        "f8" => AutomatedKey::F8,
        "f9" => AutomatedKey::F9,
        other => {
            let mut letters = other.chars();
            match (letters.next(), letters.next()) {
                (Some(letter), None) => AutomatedKey::Char(letter),
                _ => fail(&format!("no key is called {other:?}")),
            }
        }
    }
}

fn read_tape(path: &str) -> Vec<KeyPress> {
    let text = std::fs::read_to_string(path)
        .unwrap_or_else(|error| fail(&format!("cannot read tape {path}: {error}")));
    let mut presses = Vec::new();
    for (number, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let words: Vec<&str> = line.split_whitespace().collect();
        let frame = words.first().and_then(|word| word.parse::<u32>().ok());
        let (Some(frame), 3) = (frame, words.len()) else {
            fail(&format!("tape line {} is not FRAME KEY down|up", number + 1));
        };
        let down = match words[2] {
            "down" => true,
            "up" => false,
            _ => fail(&format!("tape line {} must end in down or up", number + 1)),
        };
        presses.push(KeyPress { frame, key: key_named(words[1]), down });
    }
    presses.sort_by_key(|press| press.frame);
    presses
}

/// A renderer that draws into a picture nobody sees, for a movie that draws into a BitmapData (BitmapData.draw,
/// which the null renderer does not do). It is software Vulkan (Mesa's lavapipe), so it needs no graphics card;
/// a machine without one stops here and says so.
fn drawing_renderer() -> ruffle_render_wgpu::backend::WgpuRenderBackend<ruffle_render_wgpu::target::TextureTarget> {
    use ruffle_render_wgpu::wgpu;
    ruffle_render_wgpu::backend::WgpuRenderBackend::for_offscreen((64, 64), wgpu::Backends::VULKAN, wgpu::PowerPreference::LowPower)
        .unwrap_or_else(|error| fail(&format!("--render needs a Vulkan driver (on Debian or Ubuntu, mesa-vulkan-drivers): {error}")))
}

fn main() {
    tracing_subscriber::fmt().with_writer(std::io::stderr).with_max_level(tracing::Level::WARN).init();

    let mut swf_path = None;
    let mut frames: Option<u32> = None;
    let mut tape_path = None;
    let mut headless = false;
    let mut real_time = false;
    let mut render = false;
    let mut picture_out = None;
    let mut save_file: Option<String> = None;
    let mut movie_options: Vec<String> = Vec::new();
    let mut arguments = std::env::args().skip(1);
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--frames" => {
                frames = arguments.next().and_then(|value| value.parse().ok());
                if frames.is_none() {
                    fail("--frames needs a number");
                }
            }
            "--tape" => tape_path = arguments.next(),
            "--real-time" => real_time = true,
            "--render" => render = true,
            "--headless" => {
                headless = true;
                frames = arguments.next().and_then(|value| value.parse().ok());
                if frames.is_none() {
                    fail("--headless needs the number of frames to play");
                }
            }
            "--save" if headless => {
                save_file = Some(arguments.next().unwrap_or_else(|| fail("--save needs a file")));
            }
            "--picture-out" if headless => {
                picture_out = Some(arguments.next().unwrap_or_else(|| fail("--picture-out needs a file")));
            }
            other if headless && swf_path.is_some() => movie_options.push(other.to_string()),
            other if swf_path.is_none() && !other.starts_with("--") => swf_path = Some(other.to_string()),
            other => fail(&format!("unknown argument {other}")),
        }
    }
    let swf_path = swf_path.unwrap_or_else(|| fail("usage: flash_player_harness GAME.swf --frames N [--tape TAPE]"));
    let frames = frames.unwrap_or_else(|| fail("--frames N is required"));
    let presses = tape_path.map(|path| read_tape(&path)).unwrap_or_default();

    let data = std::fs::read(&swf_path).unwrap_or_else(|error| fail(&format!("cannot read {swf_path}: {error}")));
    let movie = SwfMovieData::from_data(&data, format!("file://{swf_path}"), None, None)
        .unwrap_or_else(|error| fail(&format!("cannot read {swf_path} as a movie: {error}")));
    let frame_time = FloatDuration::from_millis(1000.0 / movie.frame_rate().to_f64());

    let asked_for_buttons = Rc::new(Cell::new(false));
    let exit_request = Rc::new(bridge::ExitRequest::default());
    let mut builder = PlayerBuilder::new()
        .with_log(PrintingLog { asked_for_buttons: asked_for_buttons.clone() })
        .with_audio(audio::SilentAudioBackend::default())
        .with_external_interface(Box::new(bridge::Provider))
        .with_fs_commands(Box::new(bridge::ExitCommand { request: exit_request.clone() }));
    if render {
        builder = builder.with_renderer(drawing_renderer());
    }
    let player = builder.with_movie(movie).with_autoplay(true).build();

    let mut stalled = 0u32;
    while !player.lock().unwrap().preload(&mut ExecutionLimit::exhausted()) {
        stalled += 1;
        if stalled > 100_000 {
            fail("the movie never finished loading");
        }
    }
    // The movie's first frame builds it and gets no ENTER_FRAME, so it is frame 0: the frames
    // a test counts begin after it.
    {
        let mut player = player.lock().unwrap();
        player.run_frame();
        player.update_timers(frame_time);
        player.audio_mut().tick();
    }

    if headless {
        bridge::play_headless(&player, frame_time, frames, &movie_options, picture_out.as_deref(), save_file.as_deref(), &asked_for_buttons, &exit_request);
    }

    let mut next_press = 0;
    let mut frame = 0;
    while frame < frames {
        frame += 1;
        while next_press < presses.len() && presses[next_press].frame <= frame {
            let press = &presses[next_press];
            let key = keys::automated_key_to_descriptor(press.key);
            let event = if press.down { PlayerEvent::KeyDown { key } } else { PlayerEvent::KeyUp { key } };
            player.lock().unwrap().handle_event(event);
            next_press += 1;
        }
        {
            let mut player = player.lock().unwrap();
            player.run_frame();
            player.update_timers(frame_time);
            player.audio_mut().tick();
        }
        if exit_request.requested.get() {
            let _ = std::io::stdout().flush();
            exit(exit_request.code.get());
        }
        if real_time {
            std::thread::sleep(std::time::Duration::from_secs_f64(frame_time.as_millis() / 1000.0));
        }
    }
    let _ = std::io::stdout().flush();
}

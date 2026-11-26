//! An audio backend that mixes in memory and plays nowhere, so a movie's generated sound runs.
use ruffle_core::backend::audio::{
    AudioBackend, AudioMixer, DecodeError, RegisterError, SoundHandle, SoundInstanceHandle,
    SoundStreamInfo, SoundTransform, swf,
};
use ruffle_core::impl_audio_mixer_backend;

pub struct SilentAudioBackend {
    mixer: AudioMixer,
    buffer: Vec<f32>,
}

impl Default for SilentAudioBackend {
    fn default() -> Self {
        Self {
            mixer: AudioMixer::new(Self::CHANNELS, Self::SAMPLE_RATE),
            buffer: vec![],
        }
    }
}

impl SilentAudioBackend {
    const CHANNELS: u8 = 2;
    const SAMPLE_RATE: u32 = 44100;
}

impl AudioBackend for SilentAudioBackend {
    impl_audio_mixer_backend!(mixer);
    fn play(&mut self) {}
    fn pause(&mut self) {}

    fn set_frame_rate(&mut self, frame_rate: f64) {
        let size = ((Self::CHANNELS as u32 * Self::SAMPLE_RATE) as f64 / frame_rate).round();
        self.buffer.resize(size as usize, 0.0);
    }

    fn tick(&mut self) {
        if !self.buffer.is_empty() {
            self.mixer.mix::<f32>(self.buffer.as_mut());
        }
    }
}

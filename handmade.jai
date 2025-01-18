GameOffscreenBuffer :: struct {
    memory          : *void;
    width           : s32;
    height          : s32;
    pitch           : s32;
}


GameSoundOutputBuffer  :: struct {
    samples_per_second : s32;
    sample_count       : s32;
    samples            : *s16;
}


game_output_sound :: (sound_buffer: *GameSoundOutputBuffer, tone_hz: s32) {
    sample_out: *s16 = sound_buffer.samples;
    tsine: float32;
    tone_volume: s16 = 3000;
    wave_period := sound_buffer.samples_per_second / tone_hz;

    sample_index: s32 = 0;
    while sample_index < sound_buffer.sample_count {
        defer sample_index += 1;

        sine_value: float32 = sin(tsine);
        sample_value := cast(s16) (sine_value * cast(float32) tone_volume);

        << sample_out = sample_value;
        sample_out += 1;
        << sample_out = sample_value;
        sample_out += 1;

        tsine += 2.0 * PI / (cast(float32) wave_period);
    }
}


game_update_and_render :: (buffer: *GameOffscreenBuffer,
                           x_offset: s32,
                           y_offset: s32,
                           sound_buffer: *GameSoundOutputBuffer,
                           tone_hz: s32) {
    // TODO(nahua): Allow sample offsets here for more robust platform options
    game_output_sound(sound_buffer, tone_hz);
    render_weird_gradient(buffer, x_offset, y_offset);
}


render_weird_gradient :: (buffer: *GameOffscreenBuffer, x_offset: s32, y_offset: s32) {
    row := cast(*u8) buffer.memory;

    for y: 0..buffer.height-1 {
        pixel := cast(*u32) row;
        for x: 0..buffer.width-1 {
            // Memory:   	BB GG RR XX
            // Register: 0x XX RR GG BB
            red   :   u8 = 0;
            green :   u8 = cast,no_check(u8) (y + y_offset); // need cast,no_check(u8) instead of xx
            blue  :   u8 = cast,no_check(u8) (x + x_offset);

            pixel.* = (cast(u32)red) << 16 | (cast(u32)green) << 8 | cast(u32)blue;
            pixel += 1;
        }
        row += buffer.pitch;
    }
}
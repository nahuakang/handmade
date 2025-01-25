#import "Basic";
#import "File";


Kilobytes :: (value: $T) -> T { return value * cast(T) 1024; }
Megabytes :: (value: $T) -> T { return Kilobytes(value) * cast(T) 1024; }
Gigabytes :: (value: $T) -> T { return Megabytes(value) * cast(T) 1024; }
Terabytes :: (value: $T) -> T { return Gigabytes(value) * cast(T) 1024; }


/*
DEBUG
*/
DebugReadFileResult :: struct {
    contents_size: u32;
    contents:      *void;
}


/*
Game Structs
*/

GameOffscreenBuffer :: struct {
    memory: *void;
    width:  s32;
    height: s32;
    pitch:  s32;
}


GameSoundOutputBuffer :: struct {
    samples_per_second: s32;
    sample_count:       s32;
    samples:            *s16;
}


GameButtonState :: struct {
    half_transition_count: s32;
    ended_down:            bool;
}


GameControllerInput :: struct {
    is_analog: bool;
    start_x:   float32;
    start_y:   float32;
    min_x:     float32;
    min_y:     float32;
    max_x:     float32;
    max_y:     float32;
    end_x:     float32;
    end_y:     float32;

    union {
        buttons: [6]GameButtonState;
        struct {
            up:             GameButtonState;
            down:           GameButtonState;
            left:           GameButtonState;
            right:          GameButtonState;
            left_shoudler:  GameButtonState;
            right_shoulder: GameButtonState;
        }
    }
}


GameInput :: struct {
    controllers: [4]GameControllerInput;
}

GameMemory :: struct {
    permanent_storage_size: u64;
    permanent_storage:      *void;
    transient_storage_size: u64;
    transient_storage:      *void;
    is_initialized:          bool;
}


GameState :: struct {
    tone_hz:  s32;
    x_offset: s32;
    y_offset: s32;
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


game_update_and_render :: (memory: *GameMemory,
                           input: *GameInput,
                           buffer: *GameOffscreenBuffer,
                           sound_buffer: *GameSoundOutputBuffer) {
    #if HANDMADE_INTERNAL == 1 {
        file_data := debug_platform_read_entire_file("src/handmade.jai");
        if file_data.contents {
            debug_platform_write_entire_file("test.out", file_data.contents_size, file_data.contents);
            debug_platform_free_file_memory(file_data.contents);
        }
    }

    assert(size_of(GameState) <= memory.permanent_storage_size);
    game_state: *GameState = cast(*GameState) memory.permanent_storage;

    if !memory.is_initialized {
        game_state.x_offset      = 0;
        game_state.y_offset      = 0;
        game_state.tone_hz       = 256;
        memory.is_initialized    = true;
    }

    input0: GameControllerInput = *input.controllers[0];
    if input0.is_analog {
        game_state.x_offset += cast(s32) (4.0 * (cast(float32) input0.end_x));
        game_state.tone_hz   = 256 + cast(s32) (128.0 * cast(float32) input0.end_y);
    } else {
        // NOTE(nahua): Use digital movement tuning
    }

    if input0.down.ended_down {
        game_state.y_offset += 1;
    }

    game_output_sound(sound_buffer, game_state.tone_hz);
    render_weird_gradient(buffer, game_state.x_offset, game_state.y_offset);
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
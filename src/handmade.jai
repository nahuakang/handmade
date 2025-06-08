#import "Basic";
#import "File";
#import "Math";

#load "handmade_common.jai";


game_output_sound :: (sound_buffer: *Game_Sound_Output_Buffer, tone_hz: s32) {
    sample_out: *s16 = sound_buffer.samples;
    tsine: float32;
    tone_volume: s16 = 3000;
    wave_period := sound_buffer.samples_per_second / tone_hz;

    sample_index: s32 = 0;
    while sample_index < sound_buffer.sample_count {
        defer sample_index += 1;

        // NOTE(nahua): Day 27 cleanup; disable the sine wave test sound
        // sine_value: float32 = sin(tsine);
        // sample_value := cast(s16) (sine_value * cast(float32) tone_volume);
        sample_value: s16 = 0;

        << sample_out = sample_value;
        sample_out += 1;
        << sample_out = sample_value;
        sample_out += 1;

        // NOTE(nahua): Day 27 cleanup
        // tsine += 2.0 * PI / (cast(float32) wave_period);
        // if tsine > 2.0 * PI {
        //     tsine -= 2.0 * PI;
        // }
    }
}


// NOTE(nahua): Casey defines it as DrawRectangle(game_offscreen_buffer *Buffer, f32 RealMinX, f32 RealMinY, f32 RealMaxX, f32 RealMaxY)
// NOTE(nahua): But we will use a simpler convention here.
draw_rectangle :: (buffer: *Game_Offscreen_Buffer, x: float32, y: float32, w: float32, h: float32, color: u32) {
    min_x := round_float32_to_s32(x);
    min_y := round_float32_to_s32(y);
    max_x := round_float32_to_s32(w);
    max_y := round_float32_to_s32(h);
    if min_x < 0 min_x = 0;
    if min_y < 0 min_y = 0;
    if max_x > buffer.width  max_x = buffer.width;
    if max_y > buffer.height max_y = buffer.height;

    // Cast to *u8 to do byte-level pointer arithmetics; remember buffer.pitch = buffer.width * bytes_per_pixel
    row: *u8 = cast(*u8) (buffer.memory + min_x * buffer.bytes_per_pixel + min_y * buffer.pitch);
    for y: min_y..max_y-1 {
        pixel: *u32 = cast(*u32) row;

        for x: min_x..max_x-1 {
            pixel.* = color;
            pixel += 1; // Advance another 4 bytes (or 1 pixel)
        }

        row += buffer.pitch;
    }
}


round_float32_to_s32 :: (number: float32) -> s32 {
    result := cast(s32) (number + 0.5);
    return result;
}


// NOTE(nahua): Unused function
render_weird_gradient :: (buffer: *Game_Offscreen_Buffer, x_offset: s32, y_offset: s32) {
    row := cast(*u8) buffer.memory;

    for y: 0..buffer.height-1 {
        pixel := cast(*u32) row;
        for x: 0..buffer.width-1 {
            // Memory:   	BB GG RR XX
            // Register: 0x XX RR GG BB
            red:   u8 = 120;
            green: u8 = cast,no_check(u8) ((y + y_offset) & 0xFF); // need cast,no_check(u8) instead of xx
            blue:  u8 = cast,no_check(u8) ((x + x_offset) & 0xFF);

            pixel.* = ((cast(u32)red   & 0xFF) << 16) |
                      ((cast(u32)green & 0xFF) << 8)  |
                      ((cast(u32)blue  & 0xFF));
            pixel += 1;
        }
        row += buffer.pitch;
    }
}


/* TODO(Nahua): Check if the function needs to end with #no_context */
#program_export
game_get_sound_samples :: (thread: *Thread_Context, memory: *Game_Memory, sound_buffer: *Game_Sound_Output_Buffer) {
    game_state: *Game_State = cast(*Game_State) memory.permanent_storage;
    game_output_sound(sound_buffer, 400);
}


/* TODO(Nahua): Check if the function needs to end with #no_context */
#program_export
game_update_and_render :: (thread: *Thread_Context, memory: *Game_Memory, input: *Game_Input, buffer: *Game_Offscreen_Buffer) {
    assert(*input.controllers[0].terminator - *input.controllers[0].buttons[0] == input.controllers[0].buttons.count);
    assert(size_of(Game_State) <= memory.permanent_storage_size);

    game_state: *Game_State = cast(*Game_State) memory.permanent_storage;

    if !memory.is_initialized {
        memory.is_initialized    = true;
    }

    for controller_index: 0..input.controllers.count-1 {
        controller: *Game_Controller_Input = get_controller(input, controller_index);
        if controller.is_analog {
            // NOTE(nahua): Use analog movement tuning
        } else {
            // NOTE(nahua): Use digital movement tuning
        }
    }

    draw_rectangle(buffer, 0, 0, xx buffer.width, xx buffer.height, 0x00FF00FF);
    draw_rectangle(buffer, 10, 10, 40, 40, 0x0000FFFF);
}

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

        sine_value: float32 = sin(tsine);
        sample_value := cast(s16) (sine_value * cast(float32) tone_volume);

        << sample_out = sample_value;
        sample_out += 1;
        << sample_out = sample_value;
        sample_out += 1;

        tsine += 2.0 * PI / (cast(float32) wave_period);
        if tsine > 2.0 * PI {
            tsine -= 2.0 * PI;
        }
    }
}


render_player :: (buffer: *Game_Offscreen_Buffer, player_x: s32, player_y: s32) {
    end_of_buffer := cast(*u8) buffer.memory + buffer.pitch * buffer.height;

    color: u32 = 0xFFFFFFFF;
    left   := player_x;
    right  := player_x + 10;
    top    := player_y;
    bottom := player_y + 10;

    for x: left..right-1 {
        pixel := cast(*u8) buffer.memory + x * buffer.bytes_per_pixel + top * buffer.pitch;

        for y: top..bottom-1 {
            if (pixel >= buffer.memory) && ((pixel + 4) <= end_of_buffer) {
                << (cast(*u32) pixel) = color;
            }
            pixel += buffer.pitch;
        }
    }
}


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
    game_output_sound(sound_buffer, game_state.tone_hz);
}


/* TODO(Nahua): Check if the function needs to end with #no_context */
#program_export
game_update_and_render :: (thread: *Thread_Context, memory: *Game_Memory, input: *Game_Input, buffer: *Game_Offscreen_Buffer) {
    assert(*input.controllers[0].terminator - *input.controllers[0].buttons[0] == input.controllers[0].buttons.count);
    assert(size_of(Game_State) <= memory.permanent_storage_size);

    game_state: *Game_State = cast(*Game_State) memory.permanent_storage;

    if !memory.is_initialized {
        #if HANDMADE_INTERNAL == 1 {
            file_data := debug_platform_read_entire_file(thread, "src/handmade.jai");
            if file_data.contents {
                debug_platform_write_entire_file(thread, "test.out", file_data.contents_size, file_data.contents);
                debug_platform_free_file_memory(thread, file_data.contents);
            }
        }

        game_state.tone_hz       = 256;
        game_state.player_x      = 100;
        game_state.player_y      = 100;

        memory.is_initialized    = true;
    }

    for controller_index: 0..input.controllers.count-1 {
        controller: *Game_Controller_Input = get_controller(input, controller_index);
        if controller.is_analog {
            game_state.x_offset += cast(s32) (4.0 * controller.stick_average_x);
            game_state.tone_hz   = 256 + cast(s32) (128.0 * controller.stick_average_y);
        } else {
            // NOTE(nahua): Use digital movement tuning
            if controller.move_left.ended_down {
                game_state.x_offset -= 1;
            }

            if controller.move_right.ended_down {
                game_state.x_offset += 1;
            }
        }

        game_state.player_x += cast(s32)(4.0 * controller.stick_average_x);
        game_state.player_y -= cast(s32)(4.0 * controller.stick_average_y);
        if game_state.jump >0 {
            game_state.player_y += cast(s32)(5.0 * sin(0.5 * PI * game_state.jump));
        }
        if controller.action_down.ended_down {
            game_state.jump = 4.0;
        }
        game_state.jump -= 0.033;
    }

    render_weird_gradient(buffer, game_state.x_offset, game_state.y_offset);
    render_player(buffer, game_state.player_x, game_state.player_y);

    for mouse_button: input.mouse_buttons {
        if mouse_button.ended_down {
            render_player(buffer, cast(s32) (10 + 20 * it_index), 10);
        }
    }

    render_player(buffer, input.mouse_x, input.mouse_y);
}

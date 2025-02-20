#import "Basic";
#import "File";


Kilobytes :: (value: $T) -> T { return value * cast(T) 1024; }
Megabytes :: (value: $T) -> T { return Kilobytes(value) * cast(T) 1024; }
Gigabytes :: (value: $T) -> T { return Megabytes(value) * cast(T) 1024; }
Terabytes :: (value: $T) -> T { return Gigabytes(value) * cast(T) 1024; }


/*
DEBUG

NOTE(nahua): Used only when HANDMADE_INTERNAL == 1
*/
Debug_Read_File_Result :: struct {
    contents_size: u32;
    contents:      *void;
}


/*
Game Structs
*/

Game_Offscreen_Buffer :: struct {
    memory: *void;
    width:  s32;
    height: s32;
    pitch:  s32;
}


Game_Sound_Output_Buffer :: struct {
    samples_per_second: s32;
    sample_count:       s32;
    samples:            *s16;
}


Game_Button_State :: struct {
    half_transition_count: s32;
    ended_down:            bool;
}


Game_Controller_Input :: struct {
    is_analog:    bool;
    is_connected: bool;

    stick_average_x: float32;
    stick_average_y: float32;

    union {
        buttons: [12]Game_Button_State;
        struct {
            move_up:        Game_Button_State;
            move_down:      Game_Button_State;
            move_left:      Game_Button_State;
            move_right:     Game_Button_State;

            action_up:      Game_Button_State;
            action_down:    Game_Button_State;
            action_left:    Game_Button_State;
            action_right:   Game_Button_State;

            left_shoulder:  Game_Button_State;
            right_shoulder: Game_Button_State;
            back:           Game_Button_State;
            start:          Game_Button_State;

            terminator:     Game_Button_State; // NOTE(nahua): for assert purpose only
        }
    }
}


Game_Input :: struct {
    // NOTE(nahua): 1 keyboard + 4 controllers
    // Keyboard:    Windows API - Controller 0
    // Gamepad 0-3: XInput API  - Controller 1, 2, 3, 4
    controllers: [5]Game_Controller_Input;
}

Game_Memory :: struct {
    permanent_storage_size: u64;
    permanent_storage:      *void;
    transient_storage_size: u64;
    transient_storage:      *void;
    is_initialized:          bool;
}


Game_State :: struct {
    tone_hz:  s32;
    x_offset: s32;
    y_offset: s32;
}


get_controller :: (input: *Game_Input, controller_index: s64) -> *Game_Controller_Input {
    assert(controller_index < input.controllers.count);
    result: *Game_Controller_Input = *input.controllers[controller_index];
    return result;
}


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
    }
}


game_update_and_render :: (memory: *Game_Memory, input: *Game_Input, buffer: *Game_Offscreen_Buffer, sound_buffer: *Game_Sound_Output_Buffer) {
    assert(*input.controllers[0].terminator - *input.controllers[0].buttons[0] == input.controllers[0].buttons.count);
    assert(size_of(Game_State) <= memory.permanent_storage_size);

    game_state: *Game_State = cast(*Game_State) memory.permanent_storage;

    if !memory.is_initialized {
        #if HANDMADE_INTERNAL == 1 {
            file_data := debug_platform_read_entire_file("src/handmade.jai");
            if file_data.contents {
                debug_platform_write_entire_file("test.out", file_data.contents_size, file_data.contents);
                debug_platform_free_file_memory(file_data.contents);
            }
        }

        game_state.tone_hz       = 256;
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

        if controller.action_down.ended_down {
            game_state.y_offset += 1;
        }
    }

    game_output_sound(sound_buffer, game_state.tone_hz);
    render_weird_gradient(buffer, game_state.x_offset, game_state.y_offset);
}


render_weird_gradient :: (buffer: *Game_Offscreen_Buffer, x_offset: s32, y_offset: s32) {
    row := cast(*u8) buffer.memory;

    for y: 0..buffer.height-1 {
        pixel := cast(*u32) row;
        for x: 0..buffer.width-1 {
            // Memory:   	BB GG RR XX
            // Register: 0x XX RR GG BB
            red:   u8 = 0;
            green: u8 = cast,no_check(u8) (y + y_offset); // need cast,no_check(u8) instead of xx
            blue:  u8 = cast,no_check(u8) (x + x_offset);

            pixel.* = (cast(u32)red) << 16 | (cast(u32)green) << 8 | cast(u32)blue;
            pixel += 1;
        }
        row += buffer.pitch;
    }
}
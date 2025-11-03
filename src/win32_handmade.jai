/*
  TODO(nahua): THIS IS NOT A FINAL PLATFORM LAYER

  - Saved game locations
  - Getting a handle to our own executable file
  - Asset loading path
  - Multithreading (launch a thread)
  - Raw Input (support for multiple keyboards)
  - Sleep/timeBeginPeriod
  - ClipCursor() (for multi-monitor support)
  - Fullscreen support
  - QueryCancelAutoplay
  - WM_SETCURSOR (control cursor visibility)
  - WM_ACTIVATEAPP (for when we are not the active application)
  - Blit speed improvements (BitBlt)
  - Hardware acceleration (OpenGL or Direct3D or both??)
  - GetKeyboardLayout (for French keyboards, international WASD support)
*/

#import "Basic";
#import "File";
#import "File_Utilities";
#import "Gamepad";
#if CPU == .X64 {
    #import "Machine_X64";  // For rdtsc, etc.
} else {
    // Poor-man’s replacements for rdtsc.
    // @TODO: We should probably call something like ARM64 CNTPCTSS_EL0 instead, but the compiler does not support that right now.
    //  -rluba, 2024-04-22
    rdtsc :: () -> u64 #expand {
        #if OS == .WINDOWS {
            Windows :: #import "Windows";
            pc: s64;
            Windows.QueryPerformanceCounter(*pc);
            return cast,no_check(u64) pc;
        } else {
            POSIX ::#import "POSIX";
            ts: POSIX.timespec;
            POSIX.clock_gettime(.MONOTONIC_RAW, *ts);
            return cast,no_check(u64) ts.tv_nsec;
        }
    }
}
#import "Math";
#import "Sound_Player";
#import "Windows";
#import "Windows_Utf8";

#load "windows.jai";            // Patching Windows module in Jai
#load "dsound.jai";             // Patching Sound_Player module in Jai
#load "handmade_platform.jai";  // Shared types between win32 platform and game code


/*
Handmade Hero Structs
*/
Win32_Debug_Time_Marker :: struct {
    output_play_cursor:        s32;
    output_write_cursor:       s32;
    output_location:           s32;
    output_byte_count:         s32;
    expected_flip_play_cursor: s32;

    flip_play_cursor:          s32;
    flip_write_cursor:         s32;
}


Win32_Game_Code :: struct {
    game_code_dll:        HMODULE;
    dll_last_write_time:  FILETIME;

    // IMPORTANT(nahua): Either of the callbacks can be null!
    // We must check before calling.
    update_and_render:    Game_Update_And_Render;
    get_sound_samples:    Game_Get_Sound_Samples;

    is_valid:             bool;
}


Win32_Offscreen_Buffer :: struct {
    // NOTE(nahua)   : Pixels are always 32 bits wide
    // Memory Order  : 0x BB GG RR xx
    // Little Endian : 0x xx RR GG BB
    info: BITMAPINFO;
    memory:          *void;
    width:           s32;
    height:          s32;
    pitch:           s32;
    bytes_per_pixel: s32;
}


Win32_Sound_Output :: struct {
    samples_per_second:    s32;
    bytes_per_sample:      s32;
    secondary_buffer_size: s32;
    running_sample_index:  s32;
    safety_bytes:          s32;
    // TODO(nahua): Math gets simpler if we add a "bytes per second" field?
}


Win32_State_Filename_Count :: MAX_PATH;


Win32_Replay_Buffer :: struct {
    file_handle:  HANDLE;
    memory_map:   HANDLE;
    filename:     string;
    memory_block: *void;
}


Win32_State :: struct {
    total_size:            u64;
    game_memory_block:     *void;
    replay_buffers:        [4]Win32_Replay_Buffer;

    recording_handle:      HANDLE;
    input_recording_index: s32;

    playback_handle:       HANDLE;
    input_playing_index:   s32;

    exe_filename:          string;
    module_path_prefix:    string; // NOTE(nahua): Casey uses OnePastLastEXEFileNameSlash
}


Win32_Window_Dimension :: struct {
    width:  s32;
    height: s32;
}


/*
Handmade Hero Variables
*/
global_back_buffer: Win32_Offscreen_Buffer;
global_pause: bool;
global_running: bool;
global_secondary_buffer: *IDirectSoundBuffer8;
global_perf_count_frequency: s64;


/*
Handmade Hero Constants
*/
WINDOW_CLASS_NAME       :: "HandmadeHeroWindowClass";
WINDOW_NAME             :: "Handmade Hero";


/*
Handmade Hero Win32 System-Related Procedures
*/
win32_build_exe_path_filename :: (state: *Win32_State, filename: string) -> string {
    result := tprint("%1%2", state.module_path_prefix, filename);
    return result;
}


win32_get_exe_filename :: (state: *Win32_State) {
    // NOTE(nahua): We use u8 with GetModuleFileNameA for ANSI (GetModuleFileNameW is for Unicode/Wide)
    // exe_filename will be: C:\Users\kangn\projects\personal\handmade\win32_handmade.exe
    buffer: [Win32_State_Filename_Count]u8;
    size := GetModuleFileNameA(null, buffer.data, Win32_State_Filename_Count);

    assert(size > 0);
    // NOTE(nahua): copy_string is needed from the one read in this stack frame
    state.exe_filename = copy_string(to_string(buffer.data, size));

    last_slash_index: s64;
    for 0..state.exe_filename.count-1 {
        if state.exe_filename[it] == #char "\\" {
            last_slash_index = it;
        }
    }

    state.module_path_prefix.count = last_slash_index + 1;
    state.module_path_prefix.data = state.exe_filename.data;
}


win32_clear_buffer :: (sound_output: *Win32_Sound_Output) {
    region1, region2: *void;
    region1_size, region2_size: s32;

    hr := global_secondary_buffer.Lock(global_secondary_buffer,
                                       0,
                                       sound_output.secondary_buffer_size,
                                       *region1, *region1_size,
                                       *region2, *region2_size,
                                       0);
    if SUCCEEDED(hr) {
        region1_sample_count := region1_size / sound_output.bytes_per_sample;
        dest_sample    := cast(*u8) region1;
        byte_index: s32 = 0;
        while byte_index < region1_sample_count {
            defer byte_index += 1;
            << dest_sample = 0;
            dest_sample += 1;
        }

        region2_sample_count := region2_size / sound_output.bytes_per_sample;
        dest_sample = cast(*u8) region2;
        byte_index  = 0;
        while byte_index < region2_sample_count {
            defer byte_index += 1;
            << dest_sample = 0;
            dest_sample += 1;
        }

        global_secondary_buffer.Unlock(global_secondary_buffer,
                                       region1, region1_size,
                                       region2, region2_size);
    }
}


win32_debug_draw_vertical :: (back_buffer: *Win32_Offscreen_Buffer, x: int, top: int, bottom: int, color: u32) {
    if top <= 0                    then top = 0;
    if bottom > back_buffer.height then bottom = back_buffer.height;

    if x >= 0 && x < back_buffer.width {
        pixel := cast(*u8) back_buffer.memory + top * back_buffer.pitch + x * back_buffer.bytes_per_pixel;

        for top..bottom-1 {
            (cast(*u32) pixel).* = color;
            pixel += back_buffer.pitch;
        }
    }
}


#if HANDMADE_INTERNAL == -1 {
win32_debug_sync_display :: (back_buffer: *Win32_Offscreen_Buffer,
                             marker_count: s64,
                             markers: []Win32_Debug_Time_Marker,
                             current_marker_index: s64,
                             sound_output: *Win32_Sound_Output,
                             target_seconds_per_frame: float32) {
    pad_x       := 16;
    pad_y       := 16;
    line_height := 64;

    c: float32 = (cast(float32) back_buffer.width - 2 * pad_x) / (cast(float32) sound_output.secondary_buffer_size);

    for marker_index: 0..marker_count-1 {
        this_marker: *Win32_Debug_Time_Marker = *markers[marker_index];

        assert(this_marker.output_play_cursor < sound_output.secondary_buffer_size);
        assert(this_marker.output_write_cursor < sound_output.secondary_buffer_size);
        assert(this_marker.output_location < sound_output.secondary_buffer_size);
        assert(this_marker.output_byte_count < sound_output.secondary_buffer_size);
        assert(this_marker.flip_play_cursor < sound_output.secondary_buffer_size);
        assert(this_marker.flip_write_cursor < sound_output.secondary_buffer_size);

        play_color          := 0xFFFFFFFF;
        write_color         := 0xFFFF0000;
        expected_flip_color := 0xFFFFFF00;
        play_window_color   := 0xFFFF00FF;

        top    := pad_y;
        bottom := pad_y + line_height;

        if marker_index == current_marker_index {
            top    += line_height + pad_y;
            bottom += line_height + pad_y;

            win32_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, top, bottom,
                                           this_marker.output_play_cursor, xx play_color);
            win32_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, top, bottom,
                                           this_marker.output_write_cursor, xx write_color);

            top    += line_height + pad_y;
            bottom += line_height + pad_y;

            win32_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, top, bottom,
                                           this_marker.output_location, xx play_color);
            win32_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, top, bottom,
                                           this_marker.output_location + this_marker.output_byte_count, xx write_color);

            top    += line_height + pad_y;
            bottom += line_height + pad_y;

            win32_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, top, bottom,
                                           this_marker.expected_flip_play_cursor, xx expected_flip_color);
        }

        win32_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, top, bottom,
                                       this_marker.flip_play_cursor, xx play_color);
        win32_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, top, bottom,
                                       this_marker.flip_play_cursor + (480 * sound_output.bytes_per_sample), xx play_window_color);
        win32_draw_sound_buffer_marker(back_buffer, sound_output, c, pad_x, top, bottom,
                                       this_marker.flip_write_cursor, xx write_color);
    }
}
}


win32_draw_sound_buffer_marker :: (back_buffer: *Win32_Offscreen_Buffer,
                                   sound_output: *Win32_Sound_Output,
                                   c: float32, pad_x: int, top: int, bottom: int,
                                   value: s32, color: u32) {
    x_f32: float32 = c * cast(float32) value;
    x := pad_x + cast(int) x_f32;
    win32_debug_draw_vertical(back_buffer, x, top, bottom, color);
}


win32_display_buffer_in_window :: (device_context: HDC, window_width: s32, window_height: s32, buffer: *Win32_Offscreen_Buffer) {
    offset_x: s32 = 10;
    offset_y: s32 = 10;
    PatBlt(device_context, 0, 0, window_width, offset_y, BLACKNESS);
    PatBlt(device_context, 0, offset_y + buffer.height, window_width, window_height, BLACKNESS);
    PatBlt(device_context, 0, 0, offset_x, window_height, BLACKNESS);
    PatBlt(device_context, offset_x + buffer.width, 0, window_width, window_height, BLACKNESS);

    // NOTE(nahua): For prototyping purposes, we're going to always blit
    // 1-to-1 pixels to make sure we don't introduce artifacts with
    // strecthing while we are learning to code the renderer.
    StretchDIBits(device_context,
                  offset_x, offset_y, buffer.width, buffer.height, // Destination (window)
                  0, 0, buffer.width, buffer.height,               // Source (bitmap buffer)
                  buffer.memory,
                  *buffer.info,
                  DIB_RGB_COLORS,
                  ROP.SRCCOPY);
}


win32_fill_sound_buffer :: (sound_output: *Win32_Sound_Output,
                            byte_to_lock: s32,
                            bytes_to_write: s32,
                            source_buffer: *Game_Sound_Output_Buffer) {
    region1, region2: *void;
    region1_size, region2_size: s32;

    hr := global_secondary_buffer.Lock(global_secondary_buffer,
                                       cast(s32) byte_to_lock,
                                       cast(s32) bytes_to_write,
                                       *region1, *region1_size,
                                       *region2, *region2_size,
                                       0);
    if SUCCEEDED(hr) {
        // TODO(nahua): Assert that Region1Size/Region2Size are valid
        region1_sample_count: s32  = region1_size / sound_output.bytes_per_sample;
        source_sample       : *s16 = source_buffer.samples;
        dest_sample         : *s16 = cast(*s16) region1;

        sample_index: s32 = 0;
        while sample_index < region1_sample_count {
            defer sample_index += 1;
            defer sound_output.running_sample_index += 1;

            << dest_sample = << source_sample;
            source_sample += 1;
            dest_sample   += 1;
            << dest_sample = << source_sample;
            source_sample += 1;
            dest_sample   += 1;
        }

        dest_sample = cast(*s16) region2;
        region2_sample_count: s32 = region2_size / sound_output.bytes_per_sample;

        sample_index = 0;
        while sample_index < region2_sample_count {
            defer sample_index += 1;
            defer sound_output.running_sample_index += 1;

            << dest_sample = << source_sample;
            source_sample += 1;
            dest_sample   += 1;
            << dest_sample = << source_sample;
            source_sample += 1;
            dest_sample   += 1;
        }

        global_secondary_buffer.Unlock(global_secondary_buffer,
                                       region1, region1_size,
                                       region2, region2_size);
    }
}


win32_get_seconds_elapsed :: inline (start: s64, end: s64) -> float32 {
    result: float32 = (cast(float32) (end - start)) / (cast(float32) global_perf_count_frequency);
    return result;
}


win32_get_wall_clock :: inline () -> s64 {
    result: s64;
    QueryPerformanceCounter(*result);
    return result;
}


win32_get_window_dimension :: (window: HWND) -> Win32_Window_Dimension {
    result: Win32_Window_Dimension;

    client_rect: RECT;
    GetClientRect(window, *client_rect);
    result.width = client_rect.right - client_rect.left;
    result.height = client_rect.bottom - client_rect.top;

    return result;
}


win32_init_dsound :: (window: HWND, samples_per_second: s32, secondary_buffer_size: s32) {
    // Get a IDirectSound8 object
    dsound: *IDirectSound8;
    hr := DirectSoundCreate8(null, *dsound, null);
    if !SUCCEEDED(hr) log_error("DirectSoundCreate8 failed!\n");

    hr = dsound.SetCooperativeLevel(dsound, window, DSSCL_PRIORITY);
    if !SUCCEEDED(hr) log_error("SetCooperativeLevel failed! HWND %.\n", window);

    // Get the primary buffer
    dsbd:              DSBUFFERDESC;
    dsbd.dwSize        = size_of(DSBUFFERDESC);
    dsbd.dwFlags       = DSBCAPS_PRIMARYBUFFER;
    dsbd.dwBufferBytes = PRIMARY_BUFFER_SIZE_IN_BYTES;
    primary_buffer     : *IDirectSoundBuffer8;

    if !SUCCEEDED(dsound.CreateSoundBuffer(dsound, *dsbd, *primary_buffer, null))
        log_error("CreateSoundBuffer for primary buffer failed!\n");

    // Set the wave format
    // See backend_init proc in jai/modules/Sound_Player/os/win32.jai for more details
    num_channels     := 2;
    channel_mask:    s64;
    if num_channels  == 2 {
        channel_mask = KSAUDIO_SPEAKER_STEREO;
    } else {
        channel_mask = KSAUDIO_SPEAKER_5POINT1_SURROUND;
    }

    KSDATAFORMAT_SUBTYPE_PCM   : GUID;
    init_KSDATAFORMAT_SUBTYPE_PCM(*KSDATAFORMAT_SUBTYPE_PCM);
    wfx:                       WAVEFORMATEXTENSIBLE;
    init_wave_format(*wfx.Format, cast(s16) num_channels);
    wfx.Format.wFormatTag      = WAVE_FORMAT_EXTENSIBLE;
    wfx.Format.nChannels       = 2;
    wfx.Format.nSamplesPerSec  = samples_per_second;
    wfx.Format.wBitsPerSample  = 16;
    wfx.Format.nBlockAlign     = (wfx.Format.wBitsPerSample / 8) * wfx.Format.nChannels;
    wfx.Format.nAvgBytesPerSec = wfx.Format.nSamplesPerSec * wfx.Format.nBlockAlign;
    wfx.Format.cbSize          = 22;
    wfx.wValidBitsPerSample    = 16;
    wfx.dwChannelMask          = cast(s32) channel_mask;
    wfx.SubFormat              = KSDATAFORMAT_SUBTYPE_PCM; // This is necessary!

    hr = primary_buffer.SetFormat(primary_buffer, *wfx.Format);
    if !SUCCEEDED(hr) log_error("SetFormat failed! wfx.Format is: %\n", wfx.Format);

    // NOTE(nahua): "Create" a secondary buffer
    sec_desc:              DSBUFFERDESC;
    sec_desc.dwSize        = size_of(DSBUFFERDESC);
    sec_desc.dwFlags       = DSBCAPS_GETCURRENTPOSITION2;
    sec_desc.dwBufferBytes = secondary_buffer_size;
    sec_desc.lpwfxFormat   = *wfx.Format;

    if !SUCCEEDED(dsound.CreateSoundBuffer(dsound, *sec_desc, *global_secondary_buffer, null))
        log_error("CreateSoundBuffer for secondary buffer failed!\n");
}


win32_get_last_write_time :: (filename: string) -> FILETIME {
    last_write_time: FILETIME;
    c_filename := temp_c_string(filename);

    data: WIN32_FILE_ATTRIBUTE_DATA;
    if GetFileAttributesExA(c_filename, GetFileExInfoStandard, *data) {
        last_write_time = data.ftLastWriteTime;
    }

    return last_write_time;
}


win32_load_game_code :: (source_dll_name: string, temp_dll_name: string) -> Win32_Game_Code {
    result: Win32_Game_Code;

    result.dll_last_write_time = win32_get_last_write_time(source_dll_name);

    success := copy_file(source_dll_name, temp_dll_name);
    if !success {
        print("Failed to copy file % to %\n", source_dll_name, temp_dll_name);
    }
    result.game_code_dll = LoadLibraryA(temp_dll_name.data);

    if result.game_code_dll {
        result.update_and_render = GetProcAddress(result.game_code_dll, "game_update_and_render");
        result.get_sound_samples = GetProcAddress(result.game_code_dll, "game_get_sound_samples");
        result.is_valid = result.update_and_render && result.get_sound_samples;
    }

    if !result.is_valid {
        result.update_and_render = null;
        result.get_sound_samples = null;
    }
    return result;
}


win32_unload_game_code :: (game_code: *Win32_Game_Code) {
    if game_code.game_code_dll {
        while FreeLibrary(game_code.game_code_dll) != 0 {};
        game_code.game_code_dll = null;
    }

    // success := file_delete("handmade_temp.dll");
    // if !success {
    //     print("Failed to delete file %\n", "handmade_temp.dll");
    // }

    game_code.is_valid = false;
    game_code.update_and_render = null;
    game_code.get_sound_samples = null;
}


win32_process_xinput_digital_button :: (xinput_button_state: s32, old_state: *Game_Button_State, button_bit: s32, new_state: *Game_Button_State) {
    new_state.ended_down = ((xinput_button_state & button_bit) == button_bit);
    new_state.half_transition_count = cast(s32) ifx (old_state.ended_down != new_state.ended_down) then 1 else 0;
}


win32_process_xinput_stick_value :: (value: s16, deadzone_threshold: s16) -> float32 {
    result: float32 = 0;
    value_f32 := cast(float32) value;
    deadzone_threshold_f32 := cast(float32) deadzone_threshold;

    if value < -deadzone_threshold {
        result = (value_f32 + deadzone_threshold_f32) / (32768.0 - deadzone_threshold_f32);
    } else if value > deadzone_threshold {
        result = (value_f32 - deadzone_threshold_f32) / (32767.0 - deadzone_threshold_f32);
    }

    return result;
}


win32_process_keyboard_message :: (new_state: *Game_Button_State, is_down: bool) {
    if new_state.ended_down != is_down {
        new_state.ended_down = is_down;
        new_state.half_transition_count += 1;
    }
}


win32_process_pending_messages :: (win32_state: *Win32_State, keyboard_controller: *Game_Controller_Input) {
    message: MSG;
    while PeekMessageA(*message, null, 0, 0, PM_REMOVE) {
        if message.message == {
            case WM_QUIT;
                global_running = false;
            case WM_SYSKEYDOWN; #through;
            case WM_SYSKEYUP;   #through;
            case WM_KEYDOWN;    #through;
            case WM_KEYUP;
                is_down   := ((message.lParam & (1 << 31)) == 0);
                was_down  := ((message.lParam & (1 << 30)) != 0);
                keycode   := message.wParam; // u64
                if is_down != was_down {
                    if      keycode == VK_W{
                        win32_process_keyboard_message(*keyboard_controller.move_up, is_down);
                    }
                    else if keycode == VK_A{
                        win32_process_keyboard_message(*keyboard_controller.move_left, is_down);
                    }
                    else if keycode == VK_S{
                        win32_process_keyboard_message(*keyboard_controller.move_down, is_down);
                    }
                    else if keycode == VK_D{
                        win32_process_keyboard_message(*keyboard_controller.move_right, is_down);
                    }
                    else if keycode == VK_Q {
                        win32_process_keyboard_message(*keyboard_controller.left_shoulder, is_down);
                    }
                    else if keycode == VK_E {
                        win32_process_keyboard_message(*keyboard_controller.right_shoulder, is_down);
                    }
                    else if keycode == VK_UP {
                        win32_process_keyboard_message(*keyboard_controller.action_up, is_down);
                    }
                    else if keycode == VK_DOWN {
                        win32_process_keyboard_message(*keyboard_controller.action_down, is_down);
                    }
                    else if keycode == VK_LEFT{
                        win32_process_keyboard_message(*keyboard_controller.action_left, is_down);
                    }
                    else if keycode == VK_RIGHT{
                        win32_process_keyboard_message(*keyboard_controller.action_right, is_down);
                    }
                    else if keycode == VK_ESCAPE {
                        win32_process_keyboard_message(*keyboard_controller.start, is_down);
                    }
                    else if keycode == VK_SPACE {
                        win32_process_keyboard_message(*keyboard_controller.back, is_down);
                    }
                    #if HANDMADE_INTERNAL == 1 {
                        if keycode == #char "P" {
                            if is_down then global_pause = !global_pause;
                        } else if keycode == #char "L" {
                            if is_down {
                                if win32_state.input_playing_index == 0 {
                                    if win32_state.input_recording_index == 0 {
                                        win32_begin_recording_input(win32_state, 1);
                                    }
                                    else {
                                        win32_end_recording_input(win32_state);
                                        win32_begin_input_playback(win32_state, 1);
                                    }
                                } else {
                                    win32_end_input_playback(win32_state);
                                }
                            }
                        }
                    }

                    alt_key_was_down := (message.lParam & (1 << 29));
                    if keycode == VK_F4 && alt_key_was_down {
                        global_running = false;
                    }
                }
            case;
                TranslateMessage(*message);
                DispatchMessageA(*message);
        }
    }
}


win32_get_input_file_location :: (state: *Win32_State, input_stream: bool, slot_index: s32) -> string {
    name := tprint("loop_edit_%1_%2.hmi", slot_index, ifx input_stream then "input" else "state");
    return win32_build_exe_path_filename(state, name);
}


win32_get_replay_buffer :: (state: *Win32_State, index: s32) -> *Win32_Replay_Buffer {
    assert(index < state.replay_buffers.count);
    result := *state.replay_buffers[index];
    return result;
}


win32_begin_recording_input :: (state: *Win32_State, input_recording_index: s32) {
    replay_buffer := win32_get_replay_buffer(state, input_recording_index);
    if replay_buffer.memory_block {
        state.input_recording_index = input_recording_index;
        filename := win32_get_input_file_location(state=state, input_stream=true, slot_index=input_recording_index);
        state.recording_handle = CreateFileA(filename=filename.data,
                                             desired_access=GENERIC_WRITE,
                                             share_mode=0x0,
                                             creation=CREATE_ALWAYS);

        #if HANDMADE_INTERNAL == -1 {
            file_position: LARGE_INTEGER;
            file_position.QuadPart = xx state.total_size;
            SetFilePointerEx(state.recording_handle, file_position.QuadPart, null, FILE_BEGIN);
        }

        memcpy(replay_buffer.memory_block, state.game_memory_block, xx state.total_size);
    }
}


win32_end_recording_input :: (state: *Win32_State) {
    CloseHandle(state.recording_handle);
    state.input_recording_index = 0;
}


win32_begin_input_playback :: (state: *Win32_State, input_playing_index: s32) {
    replay_buffer := win32_get_replay_buffer(state, input_playing_index);
    if replay_buffer.memory_block {
        state.input_playing_index = input_playing_index;
        filename := win32_get_input_file_location(state=state, input_stream=true, slot_index=input_playing_index);
        state.playback_handle = CreateFileA(filename=filename.data,
                                            desired_access=GENERIC_READ,
                                            share_mode=0x0,
                                            creation=OPEN_EXISTING);

        #if HANDMADE_INTERNAL == -1 {
            file_position: LARGE_INTEGER;
            file_position.QuadPart = xx state.total_size;
            SetFilePointerEx(state.playback_handle, file_position.QuadPart, null, FILE_BEGIN);
        }

        memcpy(state.game_memory_block, replay_buffer.memory_block, xx state.total_size);
    }
}


win32_end_input_playback :: (state: *Win32_State) {
    CloseHandle(state.playback_handle);
    state.input_playing_index = 0;
}


win32_record_input :: (state: *Win32_State, input: *Game_Input) {
    bytes_written: DWORD; // u32
    WriteFile(state.recording_handle, input, size_of(Game_Input), *bytes_written, null);
}


win32_playback_input :: (state: *Win32_State, input: *Game_Input) {
    bytes_read: DWORD; // u32
    if ReadFile(state.playback_handle, input, size_of(Game_Input), *bytes_read) {
        if bytes_read == 0 {
            // NOTE(nahua): We've hit the end of the stream, go back to the beginning
            playing_index: s32 = state.input_playing_index;
            win32_end_input_playback(state);
            win32_begin_input_playback(state, playing_index);
            ReadFile(state.playback_handle, input, size_of(Game_Input), *bytes_read);
        }
    }
}


win32_resize_dib_section :: (buffer: *Win32_Offscreen_Buffer, width: s32, height: s32) {
    if buffer.memory {
        VirtualFree(buffer.memory, 0, MEM_RELEASE);
    }

    bytes_per_pixel: s32 = 4;
    buffer.bytes_per_pixel = bytes_per_pixel;
    buffer.width = width;
    buffer.height = height;
    buffer.pitch = buffer.width * bytes_per_pixel;

    buffer.info.bmiHeader.biSize = size_of(BITMAPINFOHEADER);
    buffer.info.bmiHeader.biWidth = buffer.width;
    buffer.info.bmiHeader.biHeight = -buffer.height; // Negative value for top-down pitch
    buffer.info.bmiHeader.biPlanes = 1;
    buffer.info.bmiHeader.biBitCount = 32;
    buffer.info.bmiHeader.biCompression = BI_RGB;

    bitmap_memory_size := bytes_per_pixel * buffer.width * buffer.height;
    buffer.memory = VirtualAlloc(null, xx bitmap_memory_size, MEM_COMMIT, PAGE_READWRITE);
}


/*
win32_window_callback corresponds to Win32MainWindowCallback.
*/
win32_window_callback :: (window: HWND, message: u32, wParam: WPARAM, lParam: LPARAM) -> LRESULT #c_call {
    result: LRESULT = 0;

    if message == {
        case WM_ACTIVATEAPP;
        // NOTE(nahua): Day 24 - Disabling layering functionality
        #if HANDMADE_INTERNAL == -1 {
            push_context{
                print("WM_ACTIVATEAPP\n");
                if wParam == 1 {
                    SetLayeredWindowAttributes(window, 0x00000000, 255, LWA_ALPHA);
                } else {
                    SetLayeredWindowAttributes(window, 0x00000000, 64, LWA_ALPHA);
                }
            }
        }
        case WM_CLOSE;
            push_context{ print("WM_CLOSE\n"); }
            global_running = false;
        case WM_DESTROY;
            push_context{ print("WM_DESTROY\n"); }
            global_running = false;
        case WM_SYSKEYDOWN; #through;
        case WM_SYSKEYUP;   #through;
        case WM_KEYDOWN;    #through;
        case WM_KEYUP;
            push_context{ assert(!"Keyboard input came in through a non-dispatch message!!!"); }
        case WM_PAINT;
            paint: PAINTSTRUCT;
            device_context := BeginPaint(window, *paint);
            // Native procedure in #c_call requires push_context
            push_context{
                print("WM_PAINT!\n");
                dimension := win32_get_window_dimension(window);
                win32_display_buffer_in_window(device_context,
                                            dimension.width,
                                            dimension.height,
                                            *global_back_buffer);
            }
            EndPaint(window, *paint);
        case;
            result = DefWindowProcW(window, message, wParam, lParam);
    }

    return result;
}


/*
main corresponds to WinMain.
*/
main :: () {
    win32_state: Win32_State;
    win32_get_exe_filename(*win32_state);

    source_dll_name := win32_build_exe_path_filename(*win32_state, "handmade.dll");
    // source_dll_name: C:\Users\kangn\projects\personal\handmade\handmade.dll
    temp_dll_name := win32_build_exe_path_filename(*win32_state, "handmade_temp.dll");
    // temp_dll_name: C:\Users\kangn\projects\personal\handmade\handmade_temp.dll

    perf_count_frequency_result: s64;
    QueryPerformanceFrequency(*perf_count_frequency_result);
    global_perf_count_frequency = perf_count_frequency_result;
    // NOTE(nahua): Set the Windows scheduler granularity to 1ms
    // so that our Sleep() can be more granular
    desired_scheduler_ms: u32 = 1;
    sleep_is_granular: bool = timeBeginPeriod(desired_scheduler_ms) == TIMERR_NOERROR;

    init_gamepad();

    // win32_resize_dib_section(*global_back_buffer, 1920, 1080);
    win32_resize_dib_section(*global_back_buffer, 960, 540);

    window_class: WNDCLASSEXW;
    window_class.cbSize = size_of(WNDCLASSEXW);
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.lpfnWndProc = xx win32_window_callback;
    window_class.hInstance = GetModuleHandleW(null);
    window_class.lpszClassName = utf8_to_wide(WINDOW_CLASS_NAME);

    if RegisterClassExW(*window_class) {
        window := CreateWindowExW(0, //WS_EX_TOPMOST|WS_EX_LAYERED,
                                  window_class.lpszClassName,
                                  utf8_to_wide(WINDOW_NAME),
                                  WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                                  CW_USEDEFAULT,
                                  CW_USEDEFAULT,
                                  CW_USEDEFAULT,
                                  CW_USEDEFAULT,
                                  null,
                                  null,
                                  window_class.hInstance,
                                  null);

        if window {
            monitor_refresh_hz := 60;
            refresh_dc := GetDC(window);
            win32_refresh_rate := GetDeviceCaps(refresh_dc, VREFRESH);
            ReleaseDC(window, refresh_dc);
            if win32_refresh_rate > 1 {
                monitor_refresh_hz = win32_refresh_rate;
            }
            game_update_hz: float32 = (cast(float32)monitor_refresh_hz / 2.0);
            target_seconds_per_frame: float32 = 1.0 / game_update_hz;

            sound_output: Win32_Sound_Output;
            sound_output.samples_per_second    = 48000;
            sound_output.bytes_per_sample      = size_of(s16) * 2;
            sound_output.secondary_buffer_size = 2 * sound_output.samples_per_second * sound_output.bytes_per_sample;
            sound_output.running_sample_index  = 0;
            // TODO(nahua): Actually compute this variance and see
            // what the lowest reasonable value is.
            sound_output.safety_bytes = ((sound_output.samples_per_second * sound_output.bytes_per_sample) / cast(s32)game_update_hz) / 3;

            win32_init_dsound(window, sound_output.samples_per_second, sound_output.secondary_buffer_size);
            win32_clear_buffer(*sound_output);
            global_secondary_buffer.Play(global_secondary_buffer, 0, 0, DSBPLAY_LOOPING);
            samples := cast(*s16) VirtualAlloc(null, xx sound_output.secondary_buffer_size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);

            #if HANDMADE_INTERNAL == 1 {
                BASE_ADDRESS: *void = cast(*void) Terabytes(cast(u64) 2);
            } else {
                BASE_ADDRESS: *void = cast(*void) 0;
            }
            game_memory: Game_Memory;
            game_memory.permanent_storage_size = Megabytes(cast(u64) 64);
            game_memory.transient_storage_size = Gigabytes(cast(u64) 1);

            // TODO(nahua): Handle various memory footprints (USING SYSTEM METRICS)
            // TODO(nahua): TransientStorage needs to be broken up into game transient and cache transiet, and only the former need to be saved for state playback
            win32_state.total_size        = game_memory.permanent_storage_size + game_memory.transient_storage_size;
            win32_state.game_memory_block = VirtualAlloc(BASE_ADDRESS, xx win32_state.total_size, MEM_RESERVE|MEM_COMMIT, PAGE_READWRITE);
            game_memory.permanent_storage = win32_state.game_memory_block;
            game_memory.transient_storage = cast(*void) (cast(u64) game_memory.permanent_storage) + game_memory.permanent_storage_size;

            for *replay_buffer, replay_index: win32_state.replay_buffers {
                // TODO(nahua): Recording system still seems to take too long
                // on record start - find out what Windows is doing and if
                // we can speed up / defer some of that processing.
                replay_buffer.filename = win32_get_input_file_location(state=*win32_state, input_stream=false, slot_index=cast(s32)replay_index);
                replay_buffer.file_handle = CreateFileA(filename=replay_buffer.filename.data,
                                                        desired_access=GENERIC_READ|GENERIC_WRITE,
                                                        share_mode=0x0,
                                                        creation=CREATE_ALWAYS);

                max_size: LARGE_INTEGER;
                max_size.QuadPart = cast(s64) win32_state.total_size;
                replay_buffer.memory_map = CreateFileMappingA(replay_buffer.file_handle, null, PAGE_READWRITE, xx max_size.HighPart, xx max_size.LowPart, null);
                replay_buffer.memory_block = MapViewOfFile(replay_buffer.memory_map, FILE_MAP_ALL_ACCESS, 0, 0, cast(u64) win32_state.total_size);
                if replay_buffer.memory_block {
                    // All good
                } else {
                    // TODO(nahua): Diagnostic
                }
            }

            if samples && game_memory.permanent_storage && game_memory.transient_storage {
                input: [2]Game_Input;
                old_input: *Game_Input = *input[0];
                new_input: *Game_Input = *input[1];

                debug_time_marker_index := 0;
                debug_time_markers: [30]Win32_Debug_Time_Marker; // NOTE(nahua): 30 is game_update_hz / 2

                sound_is_valid: bool;

                last_counter: s64 = win32_get_wall_clock();
                flip_wall_clock: s64 = win32_get_wall_clock();

                global_running = true;

                game: Win32_Game_Code = win32_load_game_code(source_dll_name, temp_dll_name);

                last_cycle_count: u64 = rdtsc();
                while global_running {
                    new_input.dt_for_frame = target_seconds_per_frame;
                    new_dll_write_time: FILETIME = win32_get_last_write_time(source_dll_name);

                    if (CompareFileTime(*new_dll_write_time, *game.dll_last_write_time)) {
                        game.dll_last_write_time = new_dll_write_time;
                        win32_unload_game_code(*game);
                        game = win32_load_game_code(source_dll_name, temp_dll_name);
                    }

                    old_keyboard_controller: *Game_Controller_Input = get_controller(old_input, 0);
                    new_keyboard_controller: *Game_Controller_Input = get_controller(new_input, 0);
                    empty_keyboard_controller: Game_Controller_Input;
                    << new_keyboard_controller = empty_keyboard_controller;
                    new_keyboard_controller.is_connected = true;

                    for button_index: 0..new_keyboard_controller.buttons.count-1 {
                        new_keyboard_controller.buttons[button_index].ended_down = old_keyboard_controller.buttons[button_index].ended_down;
                    }

                    win32_process_pending_messages(*win32_state, new_keyboard_controller);

                    if !global_pause {
                        mouse_p: POINT;
                        GetCursorPos(*mouse_p);
                        ScreenToClient(window, *mouse_p);
                        new_input.mouse_x = mouse_p.x;
                        new_input.mouse_y = mouse_p.y;
                        new_input.mouse_z = 0; // TODO(nahua): Support mousewheel?
                        win32_process_keyboard_message(*new_input.mouse_buttons[0], (GetKeyState(VK_LBUTTON) & (1 << 15)) != 0);
                        win32_process_keyboard_message(*new_input.mouse_buttons[1], (GetKeyState(VK_MBUTTON) & (1 << 15)) != 0);
                        win32_process_keyboard_message(*new_input.mouse_buttons[2], (GetKeyState(VK_RBUTTON) & (1 << 15)) != 0);
                        win32_process_keyboard_message(*new_input.mouse_buttons[3], (GetKeyState(VK_XBUTTON1) & (1 << 15)) != 0);
                        win32_process_keyboard_message(*new_input.mouse_buttons[4], (GetKeyState(VK_XBUTTON2) & (1 << 15)) != 0);

                        // TODO(nahua): REMOVE THIS BLOCK LATER
                        // NOTE(nahua): For debugging with keyboard controls without controller
                        if new_keyboard_controller.move_up.ended_down {
                            new_keyboard_controller.stick_average_y = 1.0;
                        }
                        if new_keyboard_controller.move_down.ended_down {
                            new_keyboard_controller.stick_average_y = -1.0;
                        }
                        if new_keyboard_controller.move_left.ended_down {
                            new_keyboard_controller.stick_average_x = -1.0;
                        }
                        if new_keyboard_controller.move_right.ended_down {
                            new_keyboard_controller.stick_average_x = 1.0;
                        }
                        // TODO(nahua): REMOVE THIS BLOCK LATER

                        // TODO(nahua): Need to not poll disconnected controllers to avoid
                        // xinput frame rate hit on older libraries...
                        // TODO(nahua): Should we poll this more frequently
                        max_controller_count := XUSER_MAX_COUNT;
                        if max_controller_count > new_input.controllers.count - 1 {
                            max_controller_count = new_input.controllers.count - 1;
                        }

                        // NOTE(nahua): Iterate over the controllers (index 1 to 4)
                        for controller_index: 1..max_controller_count-1 {
                            old_controller: *Game_Controller_Input = get_controller(old_input, controller_index);
                            new_controller: *Game_Controller_Input = get_controller(new_input, controller_index);

                            state: XINPUT_STATE;
                            result := XInputGetState(0, *state);
                            if result == ERROR_SUCCESS {
                                // NOTE(nahua): This controller is plugged in
                                new_controller.is_connected = true;
                                new_controller.is_analog = old_controller.is_analog;

                                pad :=     state.Gamepad;
                                buttons := state.Gamepad.wButtons;

                                new_controller.stick_average_x = win32_process_xinput_stick_value(pad.sThumbLX, XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE);
                                new_controller.stick_average_y = win32_process_xinput_stick_value(pad.sThumbLY, XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE);

                                if new_controller.stick_average_x != 0.0 || new_controller.stick_average_y != 0.0 {
                                    new_controller.is_analog = true;
                                }
                                if buttons & XINPUT_GAMEPAD_DPAD_UP {
                                    new_controller.stick_average_y = 1.0;
                                    new_controller.is_analog       = false;
                                }
                                if buttons & XINPUT_GAMEPAD_DPAD_DOWN {
                                    new_controller.stick_average_y = -1.0;
                                    new_controller.is_analog       = false;
                                }
                                if buttons & XINPUT_GAMEPAD_DPAD_LEFT {
                                    new_controller.stick_average_y = -1.0;
                                    new_controller.is_analog       = false;
                                }
                                if buttons & XINPUT_GAMEPAD_DPAD_RIGHT {
                                    new_controller.stick_average_y = 1.0;
                                    new_controller.is_analog       = false;
                                }

                                threshold: float32 = 0.5;
                                win32_process_xinput_digital_button(cast(s32) ifx new_controller.stick_average_x > threshold 1 else 0,  *old_controller.move_right, 1, *new_controller.move_right);
                                win32_process_xinput_digital_button(cast(s32) ifx new_controller.stick_average_x < -threshold 1 else 0, *old_controller.move_left,  1, *new_controller.move_left);
                                win32_process_xinput_digital_button(cast(s32) ifx new_controller.stick_average_y > threshold 1 else 0,  *old_controller.move_up,    1, *new_controller.move_up);
                                win32_process_xinput_digital_button(cast(s32) ifx new_controller.stick_average_y < -threshold 1 else 0, *old_controller.move_down,  1, *new_controller.move_down);

                                win32_process_xinput_digital_button(buttons, *old_controller.action_down,    XINPUT_GAMEPAD_A,              *new_controller.action_down);
                                win32_process_xinput_digital_button(buttons, *old_controller.action_right,   XINPUT_GAMEPAD_B,              *new_controller.action_right);
                                win32_process_xinput_digital_button(buttons, *old_controller.action_left,    XINPUT_GAMEPAD_X,              *new_controller.action_left);
                                win32_process_xinput_digital_button(buttons, *old_controller.action_up,      XINPUT_GAMEPAD_Y,              *new_controller.action_up);
                                win32_process_xinput_digital_button(buttons, *old_controller.left_shoulder,  XINPUT_GAMEPAD_LEFT_SHOULDER,  *new_controller.left_shoulder);
                                win32_process_xinput_digital_button(buttons, *old_controller.right_shoulder, XINPUT_GAMEPAD_RIGHT_SHOULDER, *new_controller.right_shoulder);
                                win32_process_xinput_digital_button(buttons, *old_controller.start,          XINPUT_GAMEPAD_START,          *new_controller.start);
                                win32_process_xinput_digital_button(buttons, *old_controller.back,           XINPUT_GAMEPAD_BACK,           *new_controller.back);
                            } else {
        						// NOTE(nahua): This controller is not available
        						new_controller.is_connected = false;
                            }
                        }

                        vibration: XINPUT_VIBRATION;
                        vibration.wLeftMotorSpeed  = 60000; // u16
                        vibration.wRightMotorSpeed = 60000; // u16
                        XInputSetState(0, *vibration);

                        thread: Thread_Context;

                        // Buffer
                        buffer: Game_Offscreen_Buffer;
                        buffer.memory = global_back_buffer.memory;
                        buffer.width  = global_back_buffer.width;
                        buffer.height = global_back_buffer.height;
                        buffer.pitch  = global_back_buffer.pitch;
                        buffer.bytes_per_pixel = global_back_buffer.bytes_per_pixel;
                        if win32_state.input_recording_index {
                            win32_record_input(*win32_state, new_input);
                        }
                        if win32_state.input_playing_index {
                            win32_playback_input(*win32_state, new_input);
                        }

                        if game.update_and_render then game.update_and_render(*thread, memory=*game_memory, input=new_input, buffer=*buffer);

                        audio_wall_clock: s64 = win32_get_wall_clock();
                        from_begin_to_audio_seconds: float32 = win32_get_seconds_elapsed(flip_wall_clock, audio_wall_clock);

                        // Just before the main audio block
                        play_cursor:  s32;
                        write_cursor: s32;
                        if SUCCEEDED(global_secondary_buffer.GetCurrentPosition(global_secondary_buffer, *play_cursor, *write_cursor)) {
                            /* NOTE(nahua):
                               Here is how sound output computation works.

                               We define a safety value that is the number
                               of samples we think our game update loop
                               may vary by (let's say up to 2ms).

                               When we wake up to write audio, we will look
                               and see what the play cursor position is and we
                               will forecast ahead where we think the
                               play cursor will be on the next frame boundary.

                               We will then look to see if the write cursor is
                               before that by at least our safety value. If it is, the
                               target fill position is that frame boundary
                               plus one frame. This gives us perfect audio
                               sync in the case of a card that has low enough
                               latency.

                               If the write cursor is _after_ that safety
                               margin, then we assume we can never sync the
                               audio perfectly, so we will write one frame's
                               worth of audio plus the safety margin's worth
                               of guard samples.
                            */
                            if !sound_is_valid {
                                sound_output.running_sample_index = write_cursor / sound_output.bytes_per_sample;
                                sound_is_valid = true;
                            }

                            byte_to_lock:  s32 = (sound_output.running_sample_index * sound_output.bytes_per_sample) % sound_output.secondary_buffer_size;

                            safe_write_cursor: s32 = write_cursor;
                            if safe_write_cursor < play_cursor {
                                safe_write_cursor += sound_output.secondary_buffer_size;
                            }
                            assert(safe_write_cursor >= play_cursor);
                            expected_sound_bytes_per_frame: s32 = cast(s32) (cast(float32) (sound_output.samples_per_second * sound_output.bytes_per_sample) / game_update_hz);
                            seconds_left_until_flip: float32 = cast(float32)target_seconds_per_frame - from_begin_to_audio_seconds;
                            expected_bytes_until_flip: s32 = cast(s32) ((seconds_left_until_flip / cast(float32)target_seconds_per_frame) * (cast(float32) expected_sound_bytes_per_frame));
                            expected_frame_boundary_byte: s32 = play_cursor + cast(s32)expected_bytes_until_flip;
                            safe_write_cursor += sound_output.safety_bytes;
                            audio_card_is_low_latency: bool = safe_write_cursor < expected_frame_boundary_byte;

                            target_cursor: s32;
                            if audio_card_is_low_latency {
                                target_cursor = expected_frame_boundary_byte + expected_sound_bytes_per_frame;
                            } else {
                                target_cursor = write_cursor + expected_sound_bytes_per_frame + sound_output.safety_bytes;
                            }
                            target_cursor = target_cursor % sound_output.secondary_buffer_size;

                            bytes_to_write: s32;
                            if byte_to_lock > target_cursor {
                                bytes_to_write = sound_output.secondary_buffer_size - byte_to_lock;
                                bytes_to_write += target_cursor;
                            } else {
                                bytes_to_write = target_cursor - byte_to_lock;
                            }

                            // Sound Buffer
                            sound_buffer: Game_Sound_Output_Buffer;
                            sound_buffer.samples_per_second = sound_output.samples_per_second;
                            sound_buffer.sample_count = bytes_to_write / sound_output.bytes_per_sample;
                            sound_buffer.samples = samples;
                            if game.get_sound_samples then game.get_sound_samples(*thread, memory=*game_memory, sound_buffer=*sound_buffer);
                            win32_fill_sound_buffer(*sound_output, byte_to_lock, bytes_to_write, *sound_buffer);

                            #if HANDMADE_INTERNAL == 1 {
                                marker: *Win32_Debug_Time_Marker = *debug_time_markers[debug_time_marker_index];
                                marker.output_play_cursor        = play_cursor;
                                marker.output_write_cursor       = write_cursor;
                                marker.output_location           = byte_to_lock;
                                marker.output_byte_count         = bytes_to_write;
                                marker.expected_flip_play_cursor = expected_frame_boundary_byte;

                                // play_cursor:  s32;
                                // write_cursor: s32;
                                global_secondary_buffer.GetCurrentPosition(global_secondary_buffer, *play_cursor, *write_cursor);
                                unwrapped_write_cursor := write_cursor;
                                if unwrapped_write_cursor < play_cursor {
                                    unwrapped_write_cursor += sound_output.secondary_buffer_size;
                                }
                                audio_latency_bytes: s32 = unwrapped_write_cursor - play_cursor;
                                audio_latency_seconds: float32 = ((cast(float32) audio_latency_bytes / cast(float32) sound_output.bytes_per_sample)
                                                                  / cast(float32) sound_output.samples_per_second);
                                // print("BTL:% TC:% BTW:% - PC:% WC:% DELTA:%\n",
                                //       byte_to_lock, target_cursor, bytes_to_write,
                                //       play_cursor, write_cursor, audio_latency_bytes);
                            }
                        } else {
                            // GetCurrentPosition didn't succeed
                            sound_is_valid = false;
                        }

                        work_counter: s64 = win32_get_wall_clock();
                        work_seconds_elapsed: float32 = win32_get_seconds_elapsed(last_counter, work_counter);
                        seconds_elapsed_for_frame: float32 = work_seconds_elapsed;
                        if seconds_elapsed_for_frame < target_seconds_per_frame {
                            if sleep_is_granular {
                                sleep_ms: s32 = cast(s32) (1000.0 * (target_seconds_per_frame - seconds_elapsed_for_frame));
                                if sleep_ms > 0 {
                                    Sleep(sleep_ms);
                                }
                            }

                            test_seconds_elapsed_for_frame := win32_get_seconds_elapsed(last_counter, win32_get_wall_clock());
                            if test_seconds_elapsed_for_frame < target_seconds_per_frame {
                                // TODO(nahua): LOG MISSED SLEEP HERE
                            }

                            while seconds_elapsed_for_frame < target_seconds_per_frame {
                                seconds_elapsed_for_frame = win32_get_seconds_elapsed(last_counter, win32_get_wall_clock());
                            }
                        } else {
                            // TODO(nahua): MISSED FRAME RATE!
                            // TODO(nahua): Logging
                        }

                        end_counter: s64 = win32_get_wall_clock();
                        ms_per_frame: float32 = 1000.0 * win32_get_seconds_elapsed(last_counter, end_counter);
                        last_counter = end_counter;

                        // NOTE(nahua): Moved here from before getting work_counter to align with source code
                        dimension := win32_get_window_dimension(window);
                        device_context := GetDC(window);
                        win32_display_buffer_in_window(device_context,
                                                    dimension.width,
                                                    dimension.height,
                                                    *global_back_buffer);
                        ReleaseDC(window, device_context);
                        flip_wall_clock = win32_get_wall_clock();

                        #if HANDMADE_INTERNAL == 1 {
                            // NOTE(nahua): This is debug code
                            flip_play_cursor:  s32;
                            flip_write_cursor: s32;
                            if SUCCEEDED(global_secondary_buffer.GetCurrentPosition(global_secondary_buffer, *flip_play_cursor, *flip_write_cursor)) {
                                assert(debug_time_marker_index < debug_time_markers.count);
                                marker: *Win32_Debug_Time_Marker = *debug_time_markers[debug_time_marker_index];

                                marker.flip_play_cursor =  flip_play_cursor;
                                marker.flip_write_cursor = flip_write_cursor;

                            }
                        }

                        temp_input: *Game_Input = new_input;
                        new_input = old_input;
                        old_input = temp_input;

                        end_cycle_count: u64 = rdtsc();
                        cycles_elapsed: u64 = end_cycle_count - last_cycle_count;
                        last_cycle_count = end_cycle_count;

                        #if HANDMADE_INTERNAL == -1 {
                            fps := 0.0;
                            mega_cycles_per_frame := cast(float32) cycles_elapsed / (1000 * 1000);
                            print("ms/frame: %ms\t%FPS\t%Mc/f\n",
                                  formatFloat(ms_per_frame, trailing_width = 2),
                                  formatFloat(fps, trailing_width = 2),
                                  formatFloat(mega_cycles_per_frame, trailing_width = 2));
                        }

                        #if HANDMADE_INTERNAL == 1 {
                            debug_time_marker_index += 1;
                            if debug_time_marker_index == debug_time_markers.count {
                                debug_time_marker_index = 0;
                            }
                        }
                    }
                }
            } else {
                // Memory allocation failed
                // TODO(nahua): Logging
            }
        } else {
            // Window Creation failed
            // TODO(nahua): Logging
        }
    } else {
        // Window Class Registration failed
        // TODO(nahua): Logging
    }
}

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

#load "windows.jai"; // Patching Windows module in Jai
#load "dsound.jai";  // Patching Sound_Player module in Jai
#load "handmade.jai";


/*
Handmade Hero Structs
*/
Win32OffscreenBuffer :: struct {
    // NOTE(nahua)   : Pixels are always 32 bits wide
    // Memory Order  : 0x BB GG RR xx
    // Little Endian : 0x xx RR GG BB
    info: BITMAPINFO;
    memory:          *void;
    width:           s32;
    height:          s32;
    pitch:           s32;
}


Win32WindowDimension :: struct {
    width:  s32;
    height: s32;
}


Win32SoundOutput :: struct {
    samples_per_second:    s32;
    bytes_per_sample:      s32;
    secondary_buffer_size: s32;
    running_sample_index:  u32;
    latency_sample_count:  s32;
}


/*
Handmade Hero Variables
*/
global_back_buffer: Win32OffscreenBuffer;
global_running: bool;
global_secondary_buffer: *IDirectSoundBuffer8;
global_perf_count_frequency: s64;


/*
Handmade Hero Constants
*/
WINDOW_CLASS_NAME :: "HandmadeHeroWindowClass";
WINDOW_NAME :: "Handmade Hero";


/*
File I/O DEBUG for Win32
*/
#if HANDMADE_INTERNAL == 1 {
    debug_platform_free_file_memory :: (memory: *void) {
        if memory {
            VirtualFree(memory, 0, MEM_RELEASE);
        }
    }


    debug_platform_read_entire_file :: (filename: string) -> DebugReadFileResult {
        result: DebugReadFileResult;
        handle := CreateFileA(filename.data, GENERIC_READ);

        if handle != INVALID_HANDLE_VALUE {
            file_size: LARGE_INTEGER;
            if GetFileSizeEx(handle, *file_size) {
                result.contents = VirtualAlloc(null, xx file_size.QuadPart, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
                if result.contents {
                    bytes_read: DWORD; // u32
                    read_success := ReadFile(handle, result.contents, xx file_size.QuadPart, *bytes_read);
                    if read_success && file_size.QuadPart == cast(s64) bytes_read {
                        // NOTE(nahua): File read successfully
                        result.contents_size = bytes_read;
                    } else {
                        // ERROR: Read failed
                        debug_platform_free_file_memory(result.contents);
                        result.contents = null;
                        // TODO(nahua): Logging
                    }
                } else {
                    // ERROR: Memory allocation failed
                    // TODO(nahua): Logging
                }
            } else {
                // ERROR: File size evaluation failed
                // TODO(nahua): Logging
            }
            CloseHandle(handle);
        } else {
            // ERROR: Handle creation failed
            // TODO(nahua): Logging
        }

        return result;
    }


    debug_platform_write_entire_file :: (filename: string, memory_size: u32, memory: *void) -> bool {
        result: bool;
        handle := CreateFileA(filename=filename.data,
                              desired_access=GENERIC_WRITE,
                              share_mode=0x0,
                              creation=CREATE_ALWAYS);

        if handle != INVALID_HANDLE_VALUE {
            bytes_written: DWORD; // u32
            read_success := WriteFile(handle, memory, memory_size, *bytes_written, null);
            if read_success {
                // NOTE(nahua): File written successfully
                result = (bytes_written == memory_size);
            } else {
                // ERROR: Write failed
                // TODO(nahua): Logging
            }
            CloseHandle(handle);
        } else {
            // ERROR: Handle creation failed
            // TODO(nahua): Logging
        }

        return result;
    }
}


/*
Handmade Hero Win32 System-Related Procedures
*/
win32_get_seconds_elapsed :: inline (start: s64, end: s64) -> float32 {
    result: float32 = (cast(float32) (end - start)) / (cast(float32) global_perf_count_frequency);
    return result;
}


win32_get_wall_clock :: inline () -> s64 {
    result: s64;
    QueryPerformanceCounter(*result);
    return result;
}


win32_get_window_dimension :: (window: HWND) -> Win32WindowDimension {
    result: Win32WindowDimension;

    client_rect: RECT;
    GetClientRect(window, *client_rect);
    result.width = client_rect.right - client_rect.left;
    result.height = client_rect.bottom - client_rect.top;

    return result;
}


win32_resize_dib_section :: (buffer: *Win32OffscreenBuffer, width: s32, height: s32) {
    if buffer.memory {
        VirtualFree(buffer.memory, 0, MEM_RELEASE);
    }

    bytes_per_pixel: WORD = 4; // u32
    buffer.width = width;
    buffer.height = height;
    buffer.pitch = buffer.width * cast(s32) bytes_per_pixel;

    buffer.info.bmiHeader.biSize = size_of(BITMAPINFOHEADER);
    buffer.info.bmiHeader.biWidth = buffer.width;
    buffer.info.bmiHeader.biHeight = -buffer.height; // Negative value for top-down pitch
    buffer.info.bmiHeader.biPlanes = 1;
    buffer.info.bmiHeader.biBitCount = 32;
    buffer.info.bmiHeader.biCompression = BI_RGB;

    bitmap_memory_size := (cast(s32) bytes_per_pixel) * (buffer.width * buffer.height);
    buffer.memory = VirtualAlloc(null, xx bitmap_memory_size, MEM_COMMIT, PAGE_READWRITE);
}


win32_display_buffer_window :: (device_context: HDC, window_width: s32, window_height: s32, buffer: *Win32OffscreenBuffer) {
    StretchDIBits(device_context,
                  0, 0, window_width, window_height, // Destination (window)
                  0, 0, buffer.width, buffer.height, // Source (bitmap buffer)
                  buffer.memory,
                  *buffer.info,
                  DIB_RGB_COLORS,
                  ROP.SRCCOPY);
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
    sec_desc.dwFlags       = 0;
    sec_desc.dwBufferBytes = secondary_buffer_size;
    sec_desc.lpwfxFormat   = *wfx.Format;

    if !SUCCEEDED(dsound.CreateSoundBuffer(dsound, *sec_desc, *global_secondary_buffer, null))
        log_error("CreateSoundBuffer for secondary buffer failed!\n");
}


win32_clear_buffer :: (sound_output: *Win32SoundOutput) {
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


win32_fill_sound_buffer :: (sound_output: *Win32SoundOutput,
                            byte_to_lock: s32,
                            bytes_to_write: s32,
                            source_buffer: *GameSoundOutputBuffer) {
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


win32_process_xinput_digital_button :: (xinput_button_state: s32, old_state: *GameButtonState, button_bit: s32, new_state: *GameButtonState) {
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


win32_process_keyboard_message :: (new_state: *GameButtonState, is_down: bool) {
    assert(new_state.ended_down != is_down);
    new_state.ended_down = is_down;
    new_state.half_transition_count += 1;
}


win32_process_pending_messages :: (keyboard_controller: *GameControllerInput) {
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


/*
win32_window_callback corresponds to Win32MainWindowCallback.
*/
win32_window_callback :: (window: HWND, message: u32, wParam: WPARAM, lParam: LPARAM) -> LRESULT #c_call {
    result: LRESULT = 0;

    if message == {
        case WM_ACTIVATEAPP;
            push_context{ print("WM_ACTIVATEAPP\n"); }
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
                win32_display_buffer_window(device_context,
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
    perf_count_frequency_result: s64;
    QueryPerformanceFrequency(*perf_count_frequency_result);
    global_perf_count_frequency = perf_count_frequency_result;
    // NOTE(nahua): Set the Windows scheduler granularity to 1ms
    // so that our Sleep() can be more granular
    desired_scheduler_ms: u32 = 1;
    sleep_is_granular: bool = timeBeginPeriod(desired_scheduler_ms) == TIMERR_NOERROR;

    init_gamepad();

    win32_resize_dib_section(*global_back_buffer, 1280, 720);

    window_class: WNDCLASSEXW;
    window_class.cbSize = size_of(WNDCLASSEXW);
    window_class.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.lpfnWndProc = xx win32_window_callback;
    window_class.hInstance = GetModuleHandleW(null);
    window_class.lpszClassName = utf8_to_wide(WINDOW_CLASS_NAME);

    // TODO(nahua): How do we reliably query on this on Windows?
    monitor_refresh_hz := 60;
    game_update_hz := monitor_refresh_hz / 2;
    target_seconds_per_frame: float32 = 1.0 / cast(float32) game_update_hz;

    if RegisterClassExW(*window_class) {
        window := CreateWindowExW(0,
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
            // NOTE(nahua): Since we specified CS_OWNDC, we can just get one
            // device context and use it forever because we're not sharing it.
            device_context := GetDC(window);

            sound_output: Win32SoundOutput;
            sound_output.samples_per_second    = 48000;
            sound_output.bytes_per_sample      = size_of(s16) * 2;
            sound_output.secondary_buffer_size = 2 * sound_output.samples_per_second * sound_output.bytes_per_sample;
            sound_output.running_sample_index  = 0;
            sound_output.latency_sample_count  = sound_output.samples_per_second / 15;

            win32_init_dsound(window, sound_output.samples_per_second, sound_output.secondary_buffer_size);
            win32_clear_buffer(*sound_output);
            global_secondary_buffer.Play(global_secondary_buffer, 0, 0, DSBPLAY_LOOPING);
            samples := cast(*s16) VirtualAlloc(null, xx sound_output.secondary_buffer_size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);

            #if HANDMADE_INTERNAL == 1 {
                BASE_ADDRESS: *void = cast(*void) Terabytes(cast(u64) 2);
            } else {
                BASE_ADDRESS: *void = cast(*void) 0;
            }
            game_memory: GameMemory;
            game_memory.permanent_storage_size = Megabytes(cast(u64) 64);
            game_memory.transient_storage_size = Gigabytes(cast(u64) 1);
            total_storage_size: u64            = game_memory.permanent_storage_size + game_memory.transient_storage_size;
            game_memory.permanent_storage      = VirtualAlloc(BASE_ADDRESS, xx total_storage_size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
            game_memory.transient_storage      = cast(*void) (cast(u64) game_memory.permanent_storage) + game_memory.permanent_storage_size;

            if samples && game_memory.permanent_storage && game_memory.transient_storage {
                input: [2]GameInput;
                old_input: *GameInput = *input[0];
                new_input: *GameInput = *input[1];
                global_running = true;
                last_counter: s64 = win32_get_wall_clock();
                last_cycle_count: u64 = rdtsc();

                while global_running {
                    old_keyboard_controller: *GameControllerInput = get_controller(old_input, 0);
                    new_keyboard_controller: *GameControllerInput = get_controller(new_input, 0);
                    empty_keyboard_controller: GameControllerInput;
                    << new_keyboard_controller = empty_keyboard_controller;
                    new_keyboard_controller.is_connected = true;

                    for button_index: 0..new_keyboard_controller.buttons.count-1 {
                        new_keyboard_controller.buttons[button_index].ended_down = old_keyboard_controller.buttons[button_index].ended_down;
                    }

                    win32_process_pending_messages(new_keyboard_controller);

                    // TODO(nahua): Need to not poll disconnected controllers to avoid
                    // xinput frame rate hit on older libraries...
                    // TODO(nahua): Should we poll this more frequently
                    max_controller_count := XUSER_MAX_COUNT;
                    if max_controller_count > new_input.controllers.count - 1 {
                        max_controller_count = new_input.controllers.count - 1;
                    }

                    // NOTE(nahua): Iterate over the controllers (index 1 to 4)
                    for controller_index: 1..max_controller_count-1 {
                        old_controller: *GameControllerInput = get_controller(old_input, controller_index);
                        new_controller: *GameControllerInput = get_controller(new_input, controller_index);

                        state: XINPUT_STATE;
                        result := XInputGetState(0, *state);
                        if result == ERROR_SUCCESS {
                            // NOTE(nahua): This controller is plugged in
                            new_controller.is_connected = true;
                            new_controller.is_analog = true;

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

                    // Buffer
                    buffer: GameOffscreenBuffer;
                    buffer.memory = global_back_buffer.memory;
                    buffer.width  = global_back_buffer.width;
                    buffer.height = global_back_buffer.height;
                    buffer.pitch  = global_back_buffer.pitch;

                    // Sound Buffer
                    byte_to_lock   : s32;
                    bytes_to_write : s32;
                    play_cursor    : s32;
                    target_cursor  : s32;
                    write_cursor   : s32;
                    sound_is_valid : bool;
                    hr := global_secondary_buffer.GetCurrentPosition(global_secondary_buffer, *play_cursor, *write_cursor);
                    if SUCCEEDED(hr) {
                        byte_to_lock  = ((cast(s32) sound_output.running_sample_index) * sound_output.bytes_per_sample) % sound_output.secondary_buffer_size;
                        target_cursor = (play_cursor + (sound_output.latency_sample_count * sound_output.bytes_per_sample)) % sound_output.secondary_buffer_size;

                        if byte_to_lock > target_cursor {
                            // Play cursor is behind
                            bytes_to_write = sound_output.secondary_buffer_size - byte_to_lock; // region 1
                            bytes_to_write += target_cursor;                                    // region 2
                        } else {
                            // Play cursor is in front
                            bytes_to_write = target_cursor - byte_to_lock;                      // region 1
                        }

                        sound_is_valid = true;
                    }

                    sound_buffer: GameSoundOutputBuffer;
                    sound_buffer.samples_per_second = sound_output.samples_per_second;
                    sound_buffer.sample_count = bytes_to_write / sound_output.bytes_per_sample;
                    sound_buffer.samples = samples;

                    game_update_and_render(memory=*game_memory, input=new_input, buffer=*buffer, sound_buffer=*sound_buffer);

                    if sound_is_valid {
                        win32_fill_sound_buffer(*sound_output, byte_to_lock, bytes_to_write, *sound_buffer);
                    }

                    dimension := win32_get_window_dimension(window);
                    win32_display_buffer_window(device_context,
                                                dimension.width,
                                                dimension.height,
                                                *global_back_buffer);

                    work_counter: s64 = win32_get_wall_clock();
                    work_seconds_elapsed: float32 = win32_get_seconds_elapsed(last_counter, work_counter);
                    seconds_elapsed_for_frame: float32 = work_seconds_elapsed;

                    if seconds_elapsed_for_frame < target_seconds_per_frame {
                        while seconds_elapsed_for_frame < target_seconds_per_frame {
                            if sleep_is_granular {
                                sleep_ms: s32 = cast(s32) (1000.0 * (target_seconds_per_frame - seconds_elapsed_for_frame));
                                if sleep_ms > 0 {
                                    Sleep(sleep_ms);
                                }
                            }
                            seconds_elapsed_for_frame = win32_get_seconds_elapsed(last_counter, win32_get_wall_clock());
                        }
                    } else {
                        // TODO(nahua): MISSED FRAME RATE!
                        // TODO(nahua): Logging
                    }

                    temp_input: *GameInput = new_input;
                    new_input = old_input;
                    old_input = temp_input;

                    end_counter: s64 = win32_get_wall_clock();
                    ms_per_frame: float32 = 1000.0 * win32_get_seconds_elapsed(last_counter, end_counter);
                    last_counter = end_counter;

                    end_cycle_count: u64 = rdtsc();
                    cycles_elapsed: u64 = end_cycle_count - last_cycle_count;
                    last_cycle_count = end_cycle_count;

                    // ms_per_frame := cast(float32) ((1000 * cast(float32) counter_elapsed) / cast(float32) global_perf_count_frequency);
                    // fps := (cast(float32) global_perf_count_frequency / cast(float32) counter_elapsed);
                    // mega_cycles_per_frame := cast(float32) cycles_elapsed / (1000 * 1000);
                    // print("ms/frame: %ms\t%FPS\t%Mc/f\n",
                    //       formatFloat(ms_per_frame, trailing_width = 2),
                    //       formatFloat(fps, trailing_width = 2),
                    //       formatFloat(mega_cycles_per_frame, trailing_width = 2));
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

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


win32_process_xinput_digital_button :: (xinput_button_state: s32,
                                        old_state: *GameButtonState,
                                        button_bit: s32,
                                        new_state: *GameButtonState) {
    new_state.ended_down = ((xinput_button_state & button_bit) == button_bit);
    new_state.half_transition_count = cast(s32) ifx (old_state.ended_down != new_state.ended_down) then 1 else 0;
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
            push_context{ print("WM_SYSKEYDOWN|WM_KEYUP|WM_KEYDOWN|WM_KEYUP\n"); }
            is_down   := ((lParam & (1 << 31)) == 0);
            was_down  := ((lParam & (1 << 30)) != 0);
            keycode   := wParam; // u64
            if is_down != was_down {
                keystroke: string;
                if      keycode == VK_W     keystroke = "W";
                else if keycode == VK_A     keystroke = "A";
                else if keycode == VK_S     keystroke = "S";
                else if keycode == VK_D     keystroke = "D";
                else if keycode == VK_Q     keystroke = "Q";
                else if keycode == VK_E     keystroke = "E";
                else if keycode == VK_UP    keystroke = "UP";
                else if keycode == VK_DOWN  keystroke = "DOWN";
                else if keycode == VK_LEFT  keystroke = "LEFT";
                else if keycode == VK_RIGHT keystroke = "RIGHT";
                else if keycode == VK_ESCAPE {
                    keystroke = "ESCAPE";
                    current := "";
                    previous := "";
                    if is_down  current = "IsDown";
                    if was_down previous = "WasDown";
                    push_context{ keystroke = sprint("%: % %", keystroke, current, previous); }
                }
                else if keycode == VK_SPACE keystroke = "SPACE";

                push_context{ print("%\n", keystroke); }

                alt_key_was_down := (lParam & (1 << 29));
                if keycode == VK_F4 && alt_key_was_down {
                    global_running = false;
                }
            }
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
    perf_count_frequency: s64;
    QueryPerformanceFrequency(*perf_count_frequency);

    init_gamepad();

    window_class: WNDCLASSEXW;
    window_class.cbSize = size_of(WNDCLASSEXW);
    window_class.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.lpfnWndProc = xx win32_window_callback;
    window_class.hInstance = GetModuleHandleW(null);
    window_class.lpszClassName = utf8_to_wide(WINDOW_CLASS_NAME);

    win32_resize_dib_section(*global_back_buffer, 1280, 720);

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

            input: [2]GameInput;
            old_input: *GameInput = *input[0];
            new_input: *GameInput = *input[1];
            global_running = true;
            last_counter: s64;
            QueryPerformanceCounter(*last_counter);
            last_cycle_count: u64 = rdtsc();

            if samples && game_memory.permanent_storage && game_memory.transient_storage {
                while global_running {
                    input: GameInput;
                    message: MSG;

                    if PeekMessageA(*message, null, 0, 0, PM_REMOVE) != 0 {
                        if message.message == WM_QUIT global_running = false;
                            TranslateMessage(*message);
                            DispatchMessageA(*message);
                    }

                    max_controller_count := XUSER_MAX_COUNT;
                    if max_controller_count > new_input.controllers.count {
                        max_controller_count = new_input.controllers.count;
                    }

                    for controller_index: 0..max_controller_count-1 {
                        old_controller: *GameControllerInput = *old_input.controllers[controller_index];
                        new_controller: *GameControllerInput = *new_input.controllers[controller_index];

                        state: XINPUT_STATE;
                        result := XInputGetState(0, *state);
                        if result == ERROR_SUCCESS {
                            // NOTE(nahua): This controller is plugged in and available
                            buttons        := state.Gamepad.wButtons;
                            up             := (buttons & XINPUT_GAMEPAD_DPAD_UP)             != 0;
                            down           := (buttons & XINPUT_GAMEPAD_DPAD_DOWN)           != 0;
                            left           := (buttons & XINPUT_GAMEPAD_DPAD_LEFT)           != 0;
                            right          := (buttons & XINPUT_GAMEPAD_DPAD_RIGHT)          != 0;
                            // start          := (buttons & XINPUT_GAMEPAD_START)               != 0;
                            // back           := (buttons & XINPUT_GAMEPAD_BACK)                != 0;
                            // left_shoulder  := (buttons & XINPUT_GAMEPAD_LEFT_SHOULDER)       != 0;
                            // right_shoulder := (buttons & XINPUT_GAMEPAD_RIGHT_SHOULDER)      != 0;
                            // a              := (buttons & XINPUT_GAMEPAD_A)                   != 0;
                            // b              := (buttons & XINPUT_GAMEPAD_B)                   != 0;
                            // x              := (buttons & XINPUT_GAMEPAD_X)                   != 0;
                            // y              := (buttons & XINPUT_GAMEPAD_Y)                   != 0;
                            win32_process_xinput_digital_button(buttons, *old_controller.down, XINPUT_GAMEPAD_A, *new_controller.down);
                            win32_process_xinput_digital_button(buttons, *old_controller.down, XINPUT_GAMEPAD_B, *new_controller.down);
                            win32_process_xinput_digital_button(buttons, *old_controller.down, XINPUT_GAMEPAD_X, *new_controller.down);
                            win32_process_xinput_digital_button(buttons, *old_controller.down, XINPUT_GAMEPAD_Y, *new_controller.down);
                            win32_process_xinput_digital_button(buttons, *old_controller.down, XINPUT_GAMEPAD_LEFT_SHOULDER, *new_controller.down);
                            win32_process_xinput_digital_button(buttons, *old_controller.down, XINPUT_GAMEPAD_RIGHT_SHOULDER, *new_controller.down);

                            pad            := state.Gamepad;
                            x: float32;
                            if pad.sThumbLX < 0 {
                                x = (cast(float32) pad.sThumbLX) / 32768.0;
                            } else {
                                x = (cast(float32) pad.sThumbLX) / 32767.0;
                            }

                            y: float32;
                            if pad.sThumbLY < 0 {
                                y = (cast(float32) pad.sThumbLY / 32768.0);
                            } else {
                                y = (cast(float32) pad.sThumbLY / 32767.0);
                            }

                            new_controller.start_x = old_controller.end_x;
                            new_controller.start_y = old_controller.end_y;

                            // TODO(nahua): Min/Max macros
                            new_controller.min_x = x;
                            new_controller.max_x = x;
                            new_controller.end_x = x;
                            new_controller.min_y = y;
                            new_controller.max_y = y;
                            new_controller.end_y = y;
                            new_controller.is_analog = true;
                        } else {
    						// NOTE(nahua): This controller is not available
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

                    game_update_and_render(memory=*game_memory, input=*input, buffer=*buffer, sound_buffer=*sound_buffer);

                    if sound_is_valid {
                        win32_fill_sound_buffer(*sound_output, byte_to_lock, bytes_to_write, *sound_buffer);
                    }

                    dimension := win32_get_window_dimension(window);
                    win32_display_buffer_window(device_context,
                                                dimension.width,
                                                dimension.height,
                                                *global_back_buffer);

                    end_counter: s64;
                    QueryPerformanceCounter(*end_counter);
                    end_cycle_count: u64 = rdtsc();
                    counter_elapsed := end_counter - last_counter;
                    cycles_elapsed: u64 = end_cycle_count - last_cycle_count;

                    ms_per_frame := cast(float32) ((1000 * cast(float32) counter_elapsed) / cast(float32) perf_count_frequency);
                    fps := (cast(float32) perf_count_frequency / cast(float32) counter_elapsed);
                    mega_cycles_per_frame := cast(float32) cycles_elapsed / (1000 * 1000);

                    // print("ms/frame: %ms\t%FPS\t%Mc/f\n",
                    //       formatFloat(ms_per_frame, trailing_width = 2),
                    //       formatFloat(fps, trailing_width = 2),
                    //       formatFloat(mega_cycles_per_frame, trailing_width = 2));

                    last_counter = end_counter;
                    last_cycle_count = end_cycle_count;

                    temp_input: *GameInput = new_input;
                    new_input = old_input;
                    old_input = temp_input;
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

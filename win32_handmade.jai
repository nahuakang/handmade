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

/*
Handmade Hero Structs
*/
Win32OffscreenBuffer :: struct {
    // NOTE(nahua)   : Pixels are always 32 bits wide
    // Memory Order  : 0x BB GG RR xx
    // Little Endian : 0x xx RR GG BB
    info             : BITMAPINFO;
    memory           : *void;
    width            : s32;
    height           : s32;
    pitch            : s32;
    bytes_per_pixel  : s32;
}


Win32WindowDimension   :: struct {
    width              : s32;
    height             : s32;
}


Win32SoundOutput         :: struct {
    samples_per_second   : s32;
    bytes_per_sample     : s32;
    secondary_buffer_size: s32;
    running_sample_index : u32;
    tone_hz              : s32;
    tone_volume          : s32;
    wave_period          : s32;
    tsine                : float32;
    latency_sample_count : s32;
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
Handmade Hero System-Related Procedures
*/
render_weird_gradient :: (buffer: *Win32OffscreenBuffer, x_offset: s32, y_offset: s32) {
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

    buffer.width = width;
    buffer.height = height;
    buffer.bytes_per_pixel = 4;
    buffer.pitch = buffer.width * buffer.bytes_per_pixel;

    buffer.info.bmiHeader.biSize = size_of(BITMAPINFOHEADER);
    buffer.info.bmiHeader.biWidth = buffer.width;
    buffer.info.bmiHeader.biHeight = -buffer.height; // Negative value for top-down pitch
    buffer.info.bmiHeader.biPlanes = 1;
    buffer.info.bmiHeader.biBitCount = 32;
    buffer.info.bmiHeader.biCompression = BI_RGB;

    bitmap_memory_size := buffer.bytes_per_pixel * (buffer.width * buffer.height);
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


win32_fill_sound_buffer :: (sound_output: *Win32SoundOutput, byte_to_lock: s32, bytes_to_write: s32) {
    region1, region2:           *void;
    region1_size, region2_size: s32;

    hr := global_secondary_buffer.Lock(global_secondary_buffer,
                                       cast(s32) byte_to_lock,
                                       cast(s32) bytes_to_write,
                                       *region1, *region1_size,
                                       *region2, *region2_size,
                                       0);
    if SUCCEEDED(hr) {
        // TODO(nahua): Assert that Region1Size/Region2Size are valid
        sample_out: *s16 = cast(*s16) region1;
        region1_sample_count: s32 = region1_size / sound_output.bytes_per_sample;

        sample_index: s32 = 0;
        while sample_index < region1_sample_count {
            defer sample_index += 1;
            defer sound_output.running_sample_index += 1;

            sine_value: float32 = sin(sound_output.tsine);
            sample_value: s16 = cast(s16) (sine_value * cast(float32) sound_output.tone_volume);

            << sample_out = sample_value;
            sample_out += 1;
            << sample_out = sample_value;
            sample_out += 1;

            sound_output.tsine += 2.0 * PI / (cast(float32) sound_output.wave_period);
        }

        sample_out = cast(*s16) region2;
        region2_sample_count: s32 = region2_size / sound_output.bytes_per_sample;

        sample_index = 0;
        while sample_index < region2_sample_count {
            defer sample_index += 1;
            defer sound_output.running_sample_index += 1;

            sine_value: float32 = sin(sound_output.tsine);
            sample_value: s16 = cast(s16) (sine_value * cast(float32) sound_output.tone_volume);

            << sample_out = sample_value;
            sample_out += 1;
            << sample_out = sample_value;
            sample_out += 1;

            sound_output.tsine += 2.0 * PI / (cast(float32) sound_output.wave_period);
        }

        global_secondary_buffer.Unlock(global_secondary_buffer, region1, region1_size, region2, region2_size);
    }
    // else {
    //     print("global_secondary_buffer.Lock failed: %, %, %. hr: %\n", global_secondary_buffer, byte_to_lock, bytes_to_write, hr);
    //     print("performing exit(1)\n");
    //     exit(1);
    // }
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
            x_offset: s32 = 0;
            y_offset: s32 = 0;

            // NOTE(nahua): Sound test
            sound_output: Win32SoundOutput;
            sound_output.samples_per_second    = 48000;
            sound_output.bytes_per_sample      = size_of(s16) * 2;
            sound_output.secondary_buffer_size = 2 * sound_output.samples_per_second * sound_output.bytes_per_sample;
            sound_output.running_sample_index  = 0;
            sound_output.tone_hz               = 256;
            sound_output.wave_period           = sound_output.samples_per_second / sound_output.tone_hz;
            sound_output.tone_volume           = 3000;
            sound_output.latency_sample_count  = sound_output.samples_per_second / 15;
            win32_init_dsound(window, sound_output.samples_per_second, sound_output.secondary_buffer_size);
            win32_fill_sound_buffer(*sound_output, 0, sound_output.latency_sample_count * sound_output.bytes_per_sample);
            global_secondary_buffer.Play(global_secondary_buffer, 0, 0, DSBPLAY_LOOPING);

            global_running = true;
            last_counter: s64;
            QueryPerformanceCounter(*last_counter);
            last_cycle_count: u64 = rdtsc();
            while global_running {
                message: MSG;

                if PeekMessageA(*message, null, 0, 0, PM_REMOVE) != 0 {
                    if message.message == WM_QUIT global_running = false;
                        TranslateMessage(*message);
                        DispatchMessageA(*message);
                }

                for controller_index: 0..XUSER_MAX_COUNT {
                    state: XINPUT_STATE;
                    result := XInputGetState(0, *state);
                    if result == ERROR_SUCCESS {
                        // NOTE(nahua): This controller is plugged in and available
                        buttons        := state.Gamepad.wButtons;
                        up             := (buttons & XINPUT_GAMEPAD_DPAD_UP)             != 0;
                        down           := (buttons & XINPUT_GAMEPAD_DPAD_DOWN)           != 0;
                        left           := (buttons & XINPUT_GAMEPAD_DPAD_LEFT)           != 0;
                        right          := (buttons & XINPUT_GAMEPAD_DPAD_RIGHT)          != 0;
                        start          := (buttons & XINPUT_GAMEPAD_START)               != 0;
                        back           := (buttons & XINPUT_GAMEPAD_BACK)                != 0;
                        left_shoulder  := (buttons & XINPUT_GAMEPAD_LEFT_SHOULDER)       != 0;
                        right_shoulder := (buttons & XINPUT_GAMEPAD_RIGHT_SHOULDER)      != 0;
                        a              := (buttons & XINPUT_GAMEPAD_A)                   != 0;
                        b              := (buttons & XINPUT_GAMEPAD_B)                   != 0;
                        x              := (buttons & XINPUT_GAMEPAD_X)                   != 0;
                        y              := (buttons & XINPUT_GAMEPAD_Y)                   != 0;

                        pad            := state.Gamepad;
                        stick_x        := pad.sThumbLX; // s16
                        stick_y        := pad.sThumbLY; // s16
                        x_offset += stick_x >> 12;
                        y_offset += stick_y >> 12;

                        sound_output.tone_hz = 512 + (cast(s32) ((cast(float32) 256) * ((cast(float32) stick_x) / 30000.0)));
                        sound_output.wave_period = sound_output.samples_per_second / sound_output.tone_hz;
                    } else {
						// NOTE(nahua): This controller is not available
                    }
                }

                vibration: XINPUT_VIBRATION;
                vibration.wLeftMotorSpeed  = 60000; // u16
                vibration.wRightMotorSpeed = 60000; // u16
                XInputSetState(0, *vibration);

                render_weird_gradient(*global_back_buffer, x_offset, y_offset);
                defer x_offset += 1;

                // NOTE(nahua): DirectSound output test
                play_cursor  :s32;
                write_cursor :s32;
                hr := global_secondary_buffer.GetCurrentPosition(global_secondary_buffer, *play_cursor, *write_cursor);
                if SUCCEEDED(hr) {
                    byte_to_lock: s32 = ((cast(s32) sound_output.running_sample_index) * sound_output.bytes_per_sample) % sound_output.secondary_buffer_size;
                    target_cursor: s32 = (play_cursor + (sound_output.latency_sample_count * sound_output.bytes_per_sample)) % sound_output.secondary_buffer_size;
                    bytes_to_write: s32;

                    if byte_to_lock > target_cursor {
                        // Play cursor is behind
                        bytes_to_write = sound_output.secondary_buffer_size - byte_to_lock; // region 1
                        bytes_to_write += target_cursor;                                      // region 2
                    } else {
                        // Play cursor is in front
                        bytes_to_write = target_cursor - byte_to_lock;                        // region 1
                    }
                    win32_fill_sound_buffer(*sound_output, byte_to_lock, bytes_to_write);
                } else {
                    print("global_secondary_buffer.GetCurrentPosition call failed!\n");
                    // print("performing exit(1)\n");
                    // exit(1);
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

                print("ms/frame: %ms\t%FPS\t%Mc/f\n",
                      formatFloat(ms_per_frame, trailing_width = 2),
                      formatFloat(fps, trailing_width = 2),
                      formatFloat(mega_cycles_per_frame, trailing_width = 2));

                last_counter = end_counter;
                last_cycle_count = end_cycle_count;
            }
        } else {
            // TODO(nahua): Logging
        }
    } else {
        // TODO(nahua): Logging
    }
}

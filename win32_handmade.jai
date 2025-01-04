#import "Basic";
#import "Gamepad";
// #import "Gamepad/Xinput";
#import "Windows";
#import "Windows_Utf8";

#load "windows.jai"; // Patching Windows module in Jai

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

Win32WindowDimension :: struct {
    width            : s32;
    height           : s32;
}


/*
Handmade Hero Variables
*/
global_back_buffer: Win32OffscreenBuffer;
global_running: bool;


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

            global_running = true;
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
                        stick_x        := pad.sThumbLX;
                        stick_y        := pad.sThumbLY;
                        x_offset += stick_x >> 12;
                        y_offset += stick_y >> 12;
                        print("x_offset is %\n", x_offset);
                        print("y_offset is %\n", y_offset);
                    } else {
						// NOTE(nahua): This controller is not available
                    }
                }

                vibration: XINPUT_VIBRATION;
                vibration.wLeftMotorSpeed  = 60000; // u16
                vibration.wRightMotorSpeed = 60000; // u16
                XInputSetState(0, *vibration);

                render_weird_gradient(*global_back_buffer, x_offset, y_offset);
                x_offset += 1;

                dimension := win32_get_window_dimension(window);
                win32_display_buffer_window(device_context,
                                            dimension.width,
                                            dimension.height,
                                            *global_back_buffer);
            }
        } else {
            // TODO(nahua): Logging
        }
    } else {
        // TODO(nahua): Logging
    }
}

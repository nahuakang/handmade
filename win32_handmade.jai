#import "Basic";
#import "Windows";
#import "Windows_Utf8";

user32 :: #system_library "user32";
gdi    :: #system_library "Gdi32";

/*
Win32: Missing structs
*/
PAINTSTRUCT :: struct {
	hdc:         HDC;
	fErase:      BOOL;
	rcPaint:     RECT;
	fRestore:    BOOL;
	fIncUpdate:  BOOL;
	rgbReserved: [32]u8;
}

/*
Win32 & GDI: Missing procedures.
Read jai/modules/Windows.jai for undertanding.
*/
BeginPaint :: (hWnd: HWND, lpPaint: *PAINTSTRUCT) -> HDC #foreign user32;
CreateDIBSection :: (hdc: HDC, pbmi: *BITMAPINFO, usage: u32, ppvBits: **void, hSection: HANDLE, offset: DWORD) -> HBITMAP #foreign gdi;
EndPaint :: (hWnd: HWND, lpPaint: *PAINTSTRUCT) -> HDC #foreign user32;
GetMessageA :: (msg: *MSG, hWnd: HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) -> BOOL #foreign user32;
PatBlt :: (hdc: HDC, x: s32, y: s32, w: s32, h: s32, rop: DWORD) -> BOOL #foreign gdi;
StretchDIBits :: (hdc: HDC, xDest: s32, yDest: s32, DestWidth: s32, DestHeight: s32, xSrc: s32, ySrc: s32, SrcWidth: s32, SrcHeight: s32, lpBits: *void, lpbmi: *BITMAPINFO, iUsage: u32, rop: ROP) -> s32 #foreign gdi;

/*
Handmade Hero variables
*/
bitmap_info:           BITMAPINFO;
bitmap_memory:         *void;
bitmap_handle:         HBITMAP;
bitmap_device_context: HDC;
bitmap_width:          s32;
bitmap_height:         s32;
bytes_per_pixel: s32 = 4;
operation := cast(DWORD) 0;
running: bool = true;

/*
Handmade Hero constants
*/
WINDOW_CLASS_NAME :: "HandmadeHeroWindowClass";
WINDOW_NAME :: "Handmade Hero";

render_weird_gradient :: (x_offset: s32, y_offset: s32) {
	width := bitmap_width;
	height := bitmap_height;

	pitch := width * bytes_per_pixel;
	row := cast(*u8) bitmap_memory;

	for y: 0..bitmap_height-1 {
		pixel := cast(*u32) row;
		for x: 0..bitmap_width-1 {
			// Memory:   	BB GG RR XX
			// Register: 0x XX RR GG BB
			red   :   u8 = 0;
			green :   u8 = cast,no_check(u8) (y + y_offset); // need cast,no_check(u8) instead of xx
			blue  :   u8 = cast,no_check(u8) (x + x_offset);

			pixel.* = (cast(u32)red) << 16 | (cast(u32)green) << 8 | cast(u32)blue;
			pixel += 1;
		}
		row += pitch;
	}
}

win32_resize_dib_section :: (width: s32, height: s32) {
	if bitmap_memory {
		VirtualFree(bitmap_memory, 0, MEM_RELEASE);
	}

	bitmap_width = width;
	bitmap_height = height;

	bitmap_info.bmiHeader.biSize = size_of(BITMAPINFOHEADER);
	bitmap_info.bmiHeader.biWidth = bitmap_width;
	bitmap_info.bmiHeader.biHeight = -bitmap_height; // Negative value for top-down pitch
	bitmap_info.bmiHeader.biPlanes = 1;
	bitmap_info.bmiHeader.biBitCount = 32;
	bitmap_info.bmiHeader.biCompression = BI_RGB;

	bitmap_memory_size := bytes_per_pixel * (bitmap_width * bitmap_height);
	bitmap_memory = VirtualAlloc(null, xx bitmap_memory_size, MEM_COMMIT, PAGE_READWRITE);
}

win32_update_window :: (device_context: HDC, client_rect: *RECT) {
	window_width := client_rect.right - client_rect.left;
	window_height := client_rect.bottom - client_rect.top;

	StretchDIBits(
		device_context,
		0, 0, window_width, window_height, // Destination (window)
		0, 0, bitmap_width, bitmap_height, // Source (bitmap buffer)
		bitmap_memory,
		*bitmap_info,
		DIB_RGB_COLORS,
		ROP.SRCCOPY,
	);
}

/*
win32_window_callback corresponds to Win32MainWindowCallback.
*/
win32_window_callback :: (window: HWND, message: u32, wParam: WPARAM, lParam: LPARAM) -> LRESULT #c_call {
	result: LRESULT = 0;

	if message == {
		case WM_SIZE;
			client_rect: RECT;
			GetClientRect(window, *client_rect);
			width := client_rect.right - client_rect.left;
			height := client_rect.bottom - client_rect.top;

			// Native procedure in #c_call requires push_context
			push_context {
				win32_resize_dib_section(width, height);
			}
		case WM_DESTROY;
			running = false;
		case WM_CLOSE;
			running = false;
		case WM_ACTIVATEAPP;
			OutputDebugStringA("WM_ACTIVATEAPP\n");
		case WM_PAINT;
			paint: PAINTSTRUCT;
			device_context := BeginPaint(window, *paint);

			client_rect: RECT;
			GetClientRect(window, *client_rect);
			// Native procedure in #c_call requires push_context
			push_context{
				win32_update_window(device_context, *client_rect);
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
	window_class: WNDCLASSEXW;
	window_class.cbSize = size_of(WNDCLASSEXW);
	window_class.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
	window_class.cbClsExtra = 0;
	window_class.cbWndExtra = 0;
	window_class.lpfnWndProc = xx win32_window_callback;
	window_class.hInstance = GetModuleHandleW(null);
	window_class.lpszClassName = utf8_to_wide(WINDOW_CLASS_NAME);

	if RegisterClassExW(*window_class) {
		window := CreateWindowExW(
			0,
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
			null
		);

		if window {
			x_offset: s32 = 0;
			y_offset: s32 = 0;
			message: MSG;
			while running {
				if PeekMessageA(*message, null, 0, 0, PM_REMOVE) != 0 {
					if message.message == WM_QUIT running = false;

					TranslateMessage(*message);
					DispatchMessageA(*message);
				}

				render_weird_gradient(x_offset, y_offset);

				device_context := GetDC(window);
				client_rect: RECT;
				GetClientRect(window, *client_rect);
				win32_update_window(device_context, *client_rect);
				ReleaseDC(window, device_context);

				x_offset += 1;
			}
		} else {
    		// TODO(nahua): Logging
		}
	} else {
		// TODO(nahua): Logging
	}
}

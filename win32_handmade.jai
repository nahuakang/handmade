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
operation := cast(DWORD) 0;
running: bool = true;

/*
Handmade Hero constants
*/
WINDOW_CLASS_NAME :: "HandmadeHeroWindowClass";
WINDOW_NAME :: "Handmade Hero";

win32_resize_dib_section :: (width: s32, height: s32) {
	if bitmap_handle {
		DeleteObject(bitmap_handle);
	}

	if !bitmap_device_context {
		bitmap_device_context = CreateCompatibleDC(null);
	}

	bitmap_info.bmiHeader.biSize = size_of(BITMAPINFOHEADER);
	bitmap_info.bmiHeader.biWidth = width;
	bitmap_info.bmiHeader.biHeight = height;
	bitmap_info.bmiHeader.biPlanes = 1;
	bitmap_info.bmiHeader.biBitCount = 32;
	bitmap_info.bmiHeader.biCompression = BI_RGB;

	bitmap_handle = CreateDIBSection(bitmap_device_context, *bitmap_info, DIB_RGB_COLORS, *bitmap_memory, null, 0);
}

win32_update_window :: (device_context: HDC, x: s32, y: s32, width: s32, height: s32) {
	StretchDIBits(
		device_context,
		x, y, width, height,
		x, y, width, height,
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
			x := paint.rcPaint.left;
			y := paint.rcPaint.top;
			width := paint.rcPaint.right - paint.rcPaint.left;
			height := paint.rcPaint.bottom - paint.rcPaint.top;

			// Native procedure in #c_call requires push_context
			push_context{
				win32_update_window(device_context, x, y, width, height);
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
    		message: MSG;
    		while running {
    			message_result := GetMessageA(*message, null, 0, 0);
    			if message_result <= 0 break;
    			TranslateMessage(*message);
    			DispatchMessageA(*message);
    		}
    	} else {
    		// TODO(nahua): Logging
    	}
    } else {
    	// TODO(nahua): Logging
    }
}

#import "Basic";
#import "Windows";
#import "Windows_Utf8";

user32   :: #system_library "user32";
gdi      :: #system_library "Gdi32";

WINDOW_CLASS_NAME :: "HandmadeHeroWindowClass";
WINDOW_NAME :: "Handmade Hero";

/*
PAINTSTRUCT is manually defined here as it is missing from Windows.jai.
*/
PAINTSTRUCT :: struct {
	hdc: HDC;
	fErase: BOOL;
	rcPaint: RECT;
	fRestore: BOOL;
	fIncUpdate: BOOL;
	rgbReserved: [32]u8;
}

/*
Missing procedures for win32
*/
BeginPaint :: (hWnd: HWND, lpPaint: *PAINTSTRUCT) -> HDC #foreign user32;
EndPaint :: (hWnd: HWND, lpPaint: *PAINTSTRUCT) -> HDC #foreign user32;
GetMessageA :: (msg: *MSG, hWnd: HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) -> BOOL #foreign user32;
PatBlt :: (hdc: HDC, x: s32, y: s32, w: s32, h: s32, rop: DWORD) -> BOOL #foreign gdi;

operation := cast(DWORD) 0;

/*
window_callback corresponds to MainWindowCallback.
*/
window_callback :: (window: HWND, message: u32, wParam: WPARAM, lParam: LPARAM) -> LRESULT #c_call {
	result: LRESULT = 0;

	if message == {
		case WM_SIZE;
			OutputDebugStringA("WM_SIZE\n");
		case WM_DESTROY;
			OutputDebugStringA("WM_DESTROY\n");
		case WM_CLOSE;
			OutputDebugStringA("WM_CLOSE\n");
		case WM_ACTIVATEAPP;
			OutputDebugStringA("WM_ACTIVATEAPP\n");
		case WM_PAINT;
			paint: PAINTSTRUCT;
			device_context := BeginPaint(window, *paint);
			x := paint.rcPaint.left;
			y := paint.rcPaint.top;
			width := paint.rcPaint.right - paint.rcPaint.left;
			height := paint.rcPaint.bottom - paint.rcPaint.top;

			// TODO(nahua): ROP is an enum and doesn't include all codes
			if operation == cast(DWORD) 0 {
				operation = cast(DWORD) 1;
			} else {
				operation = cast(DWORD) 0;
			}
			push_context {
				print("operation = %\n", operation);
			}
			PatBlt(device_context, x, y, width, height, operation);

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
    window_class.lpfnWndProc = xx window_callback;
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
    		while true {
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

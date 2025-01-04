// We cannot see Windows in the application scope, so we must import it here.
#import "Windows";

user32 :: #system_library "user32";
gdi    :: #system_library "Gdi32";

/*
Win32: Missing structs
*/
PAINTSTRUCT     :: struct {
	hdc         :  HDC;
	fErase      :  BOOL;
	rcPaint     :  RECT;
	fRestore    :  BOOL;
	fIncUpdate  :  BOOL;
	rgbReserved :  [32]u8;
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
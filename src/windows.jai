// We cannot see Windows in the application scope, so we must import it here.
#import "Windows";


gdi      :: #system_library "Gdi32";
kernel32 :: #system_library "kernel32";
user32   :: #system_library "user32";


/*
Win32: Missing Virtual-Key Codes
https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
*/
VK_A :: 0x41;
VK_D :: 0x44;
VK_E :: 0x45;
VK_Q :: 0x51;
VK_S :: 0x53;
VK_W :: 0x57;


/*
Win32: Missing winerror
https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--0-499-
*/
ERROR_SUCCESS :: 0x0;


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


WIN32_FIND_DATAA :: struct {
    dwFileAttributes: DWORD;
    ftCreationTime: FILETIME;
    ftLastAccessTime: FILETIME;
    ftLastWriteTime: FILETIME;
    nFileSizeHigh: DWORD;
    nFileSizeLow: DWORD;
    dwReserved0: DWORD;
    dwReserved1: DWORD;
    cFileName: [MAX_PATH]u8;
    cAlternateFileName: [14]u8;
}


/*
Win32 & GDI: Missing procedures.
Read jai/modules/Windows.jai for undertanding.
*/
BeginPaint :: (hWnd: HWND, lpPaint: *PAINTSTRUCT) -> HDC #foreign user32;
CompareFileTime :: (lpFileTime1: *FILETIME, lpFileTime2: *FILETIME) -> s32 #foreign kernel32;
CreateDIBSection :: (hdc: HDC, pbmi: *BITMAPINFO, usage: u32, ppvBits: **void, hSection: HANDLE, offset: DWORD) -> HBITMAP #foreign gdi;
EndPaint :: (hWnd: HWND, lpPaint: *PAINTSTRUCT) -> HDC #foreign user32;
GetMessageA :: (msg: *MSG, hWnd: HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) -> BOOL #foreign user32;
PatBlt :: (hdc: HDC, x: s32, y: s32, w: s32, h: s32, rop: DWORD) -> BOOL #foreign gdi;
StretchDIBits :: (hdc: HDC, xDest: s32, yDest: s32, DestWidth: s32, DestHeight: s32, xSrc: s32, ySrc: s32, SrcWidth: s32, SrcHeight: s32, lpBits: *void, lpbmi: *BITMAPINFO, iUsage: u32, rop: ROP) -> s32 #foreign gdi;
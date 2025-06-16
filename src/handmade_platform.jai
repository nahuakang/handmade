/* handemade_common.jai

Shared entities between platform and game code.

*/

Kilobytes :: (value: $T) -> T { return value * cast(T) 1024; }
Megabytes :: (value: $T) -> T { return Kilobytes(value) * cast(T) 1024; }
Gigabytes :: (value: $T) -> T { return Megabytes(value) * cast(T) 1024; }
Terabytes :: (value: $T) -> T { return Gigabytes(value) * cast(T) 1024; }


/*
Win32 Platform Debug Code
*/
#if HANDMADE_INTERNAL == 1 {
    /*
    DEBUG

    NOTE(nahua): Used only when HANDMADE_INTERNAL == 1
    */
    Debug_Read_File_Result :: struct {
        contents_size: u32;
        contents:      *void;
    }


    /*
    File I/O DEBUG for Win32
    */
    debug_platform_free_file_memory :: (thread: *Thread_Context, memory: *void) {
        if memory {
            VirtualFree(memory, 0, MEM_RELEASE);
        }
    }


    debug_platform_read_entire_file :: (thread: *Thread_Context, filename: string) -> Debug_Read_File_Result {
        result: Debug_Read_File_Result;
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
                        debug_platform_free_file_memory(thread, result.contents);
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


    debug_platform_write_entire_file :: (thread: *Thread_Context, filename: string, memory_size: u32, memory: *void) -> bool {
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


Thread_Context :: struct {
    placeholder: s32;
}


/*
Game Structs
*/

Game_Offscreen_Buffer :: struct {
    memory:          *void;
    width:           s32;
    height:          s32;
    pitch:           s32;
    bytes_per_pixel: s32;
}


Game_Sound_Output_Buffer :: struct {
    samples_per_second: s32;
    sample_count:       s32;
    samples:            *s16;
}


Game_Button_State :: struct {
    half_transition_count: s32;
    ended_down:            bool;
}


Game_Controller_Input :: struct {
    is_analog:    bool;
    is_connected: bool;

    stick_average_x: float32;
    stick_average_y: float32;

    union {
        buttons: [12]Game_Button_State;
        struct {
            move_up:        Game_Button_State;
            move_down:      Game_Button_State;
            move_left:      Game_Button_State;
            move_right:     Game_Button_State;

            action_up:      Game_Button_State;
            action_down:    Game_Button_State;
            action_left:    Game_Button_State;
            action_right:   Game_Button_State;

            left_shoulder:  Game_Button_State;
            right_shoulder: Game_Button_State;
            back:           Game_Button_State;
            start:          Game_Button_State;

            terminator:     Game_Button_State; // NOTE(nahua): for assert purpose only
        }
    }
}


Game_Input :: struct {
    mouse_buttons:  [5]Game_Button_State;
    mouse_x:        s32;
    mouse_y:        s32;
    mouse_z:        s32;
    // NOTE(nahua): 1 keyboard + 4 controllers
    // Keyboard:    Windows API - Controller 0
    // Gamepad 0-3: XInput API  - Controller 1, 2, 3, 4
    controllers:    [5]Game_Controller_Input;

    dt_for_frame: float32;
}


Game_Memory :: struct {
    permanent_storage_size: u64;
    permanent_storage:      *void;
    transient_storage_size: u64;
    transient_storage:      *void;
    is_initialized:          bool;

    debug_platform_free_file_memory:  DEBUG_Platform_Free_File_Memory;
    debug_platform_read_entire_file:  DEBUG_Platform_Read_Entire_File;
    debug_platform_write_entire_file: DEBUG_Platform_Write_Entire_File;
}


Game_State :: struct {
    player_tile_map_x: s32;
    player_tile_map_y: s32;

    player_x: float32;
    player_y: float32;
}


/*
Function Types and Stubs
*/
DEBUG_Platform_Free_File_Memory ::  #type (thread: *Thread_Context, memory: *void) -> ();
DEBUG_Platform_Read_Entire_File ::  #type (thread: *Thread_Context, filename: string) -> Debug_Read_File_Result;
DEBUG_Platform_Write_Entire_File :: #type (thread: *Thread_Context, filename: string, memory_size: u32, memory: *void) -> bool;


Game_Update_And_Render :: #type (thread: *Thread_Context, memory: *Game_Memory, input: *Game_Input, buffer: *Game_Offscreen_Buffer) -> ();
Game_Get_Sound_Samples :: #type (thread: *Thread_Context, memory: *Game_Memory, sound_buffer: *Game_Sound_Output_Buffer) -> ();


/* Functions */

get_controller :: (input: *Game_Input, controller_index: s64) -> *Game_Controller_Input {
    assert(controller_index < input.controllers.count);
    result: *Game_Controller_Input = *input.controllers[controller_index];
    return result;
}


#scope_file
#import "Windows";
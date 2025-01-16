GameOffscreenBuffer :: struct {
    memory           : *void;
    width            : s32;
    height           : s32;
    pitch            : s32;
}

game_update_and_render :: (buffer: *GameOffscreenBuffer) {
    x_offset: s32 = 0;
    y_offset: s32 = 0;
    render_weird_gradient(buffer, x_offset, y_offset);
}

render_weird_gradient :: (buffer: *GameOffscreenBuffer, x_offset: s32, y_offset: s32) {
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
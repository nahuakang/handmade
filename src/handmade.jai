#import "Basic";
#import "File";
#import "Math";

#load "handmade_intrinsics.jai";
#load "handmade_platform.jai";


Tile_Map :: struct {
    tiles: []u32; // NOTE(nahua): Day 29 - Differ from Casey because there's only 1D array view in Jai
}


World :: struct {
    tile_side_in_meters: float32;
    tile_side_in_pixels: s32;
    meters_to_pixels: float32;

    count_x: s32;
    count_y: s32;

    upper_left_x: float32;
    upper_left_y: float32;

    // TODO(nahua): Beginner's sparseness
    tile_map_count_x: s32;
    tile_map_count_y: s32;

    tile_maps: []Tile_Map; // NOTE(nahua): Day 29 - Differ from Casey because there's only 1D array view in Jai
}


game_output_sound :: (sound_buffer: *Game_Sound_Output_Buffer, tone_hz: s32) {
    sample_out: *s16 = sound_buffer.samples;
    tsine: float32;
    tone_volume: s16 = 3000;
    wave_period := sound_buffer.samples_per_second / tone_hz;

    sample_index: s32 = 0;
    while sample_index < sound_buffer.sample_count {
        defer sample_index += 1;

        // NOTE(nahua): Day 27 cleanup; disable the sine wave test sound
        // sine_value: float32 = sin(tsine);
        // sample_value := cast(s16) (sine_value * cast(float32) tone_volume);
        sample_value: s16 = 0;

        << sample_out = sample_value;
        sample_out += 1;
        << sample_out = sample_value;
        sample_out += 1;

        // NOTE(nahua): Day 27 cleanup
        // tsine += 2.0 * PI / (cast(float32) wave_period);
        // if tsine > 2.0 * PI {
        //     tsine -= 2.0 * PI;
        // }
    }
}


// NOTE(nahua): Casey defines it as DrawRectangle(game_offscreen_buffer *Buffer, f32 RealMinX, f32 RealMinY, f32 RealMaxX, f32 RealMaxY)
// NOTE(nahua): But we will use a simpler convention here.
draw_rectangle :: (buffer: *Game_Offscreen_Buffer, x: float32, y: float32, w: float32, h: float32, r: float32, g: float32, b: float32) {
    min_x := round_float32_to_s32(x);
    min_y := round_float32_to_s32(y);
    max_x := round_float32_to_s32(w);
    max_y := round_float32_to_s32(h);
    if min_x < 0 min_x = 0;
    if min_y < 0 min_y = 0;
    if max_x > buffer.width  max_x = buffer.width;
    if max_y > buffer.height max_y = buffer.height;

    // Pack a 32-bit floating-point color value into an 8-bit unsigned int
    red   := cast(u32) round_float32_to_s32(r * 255.0);
    green := cast(u32) round_float32_to_s32(g * 255.0);
    blue  := cast(u32) round_float32_to_s32(b * 255.0);
    alpha := cast(u32) 255;
    color: u32 = (alpha << 24) | (red << 16) | (green << 8) | blue;

    // Cast to *u8 to do byte-level pointer arithmetics; remember buffer.pitch = buffer.width * bytes_per_pixel
    row: *u8 = cast(*u8) (buffer.memory + min_x * buffer.bytes_per_pixel + min_y * buffer.pitch);
    for y: min_y..max_y-1 {
        pixel: *u32 = cast(*u32) row;

        for x: min_x..max_x-1 {
            pixel.* = color;
            pixel += 1; // Advance another 4 bytes (or 1 pixel)
        }

        row += buffer.pitch;
    }
}


// NOTE(nahua): Unused function
render_weird_gradient :: (buffer: *Game_Offscreen_Buffer, x_offset: s32, y_offset: s32) {
    row := cast(*u8) buffer.memory;

    for y: 0..buffer.height-1 {
        pixel := cast(*u32) row;
        for x: 0..buffer.width-1 {
            // Memory:   	BB GG RR XX
            // Register: 0x XX RR GG BB
            red:   u8 = 120;
            green: u8 = cast,no_check(u8) ((y + y_offset) & 0xFF); // need cast,no_check(u8) instead of xx
            blue:  u8 = cast,no_check(u8) ((x + x_offset) & 0xFF);

            pixel.* = ((cast(u32)red   & 0xFF) << 16) |
                      ((cast(u32)green & 0xFF) << 8)  |
                      ((cast(u32)blue  & 0xFF));
            pixel += 1;
        }
        row += buffer.pitch;
    }
}


/* TODO(Nahua): Check if the function needs to end with #no_context */
#program_export
game_get_sound_samples :: (thread: *Thread_Context, memory: *Game_Memory, sound_buffer: *Game_Sound_Output_Buffer) {
    game_state: *Game_State = cast(*Game_State) memory.permanent_storage;
    game_output_sound(sound_buffer, 400);
}


/* TODO(Nahua): Check if the function needs to end with #no_context */
#program_export
game_update_and_render :: (thread: *Thread_Context, memory: *Game_Memory, input: *Game_Input, buffer: *Game_Offscreen_Buffer) {
    assert(*input.controllers[0].terminator - *input.controllers[0].buttons[0] == input.controllers[0].buttons.count);
    assert(size_of(Game_State) <= memory.permanent_storage_size);

    TILE_MAP_COUNT_X :: 17;
    TILE_MAP_COUNT_Y :: 9;

    tiles00: [TILE_MAP_COUNT_Y][TILE_MAP_COUNT_X]u32 = .[
        .[1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1],
        .[1, 1, 0, 0,  0, 1, 0, 0,  0, 0, 0, 0,  0, 1, 0, 0,  1],
        .[1, 1, 0, 0,  0, 0, 0, 0,  1, 0, 0, 0,  0, 0, 1, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  1, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 1, 0, 0,  1, 0, 0, 0,  0, 0, 0, 0,  0],
        .[1, 1, 0, 0,  0, 1, 0, 0,  1, 0, 0, 0,  0, 1, 0, 0,  1],
        .[1, 0, 0, 0,  0, 1, 0, 0,  1, 0, 0, 0,  1, 0, 0, 0,  1],
        .[1, 1, 1, 1,  1, 0, 0, 0,  0, 0, 0, 0,  0, 1, 0, 0,  1],
        .[1, 1, 1, 1,  1, 1, 1, 1,  0, 1, 1, 1,  1, 1, 1, 1,  1],
    ];
    tiles01: [TILE_MAP_COUNT_Y][TILE_MAP_COUNT_X]u32 = .[
        .[1, 1, 1, 1,  1, 1, 1, 1,  0, 1, 1, 1,  1, 1, 1, 1,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1],
    ];
    tiles10: [TILE_MAP_COUNT_Y][TILE_MAP_COUNT_X]u32 = .[
        .[1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 1, 1, 1,  1, 1, 1, 1,  0, 1, 1, 1,  1, 1, 1, 1,  1],
    ];
    tiles11: [TILE_MAP_COUNT_Y][TILE_MAP_COUNT_X]u32 = .[
        .[1, 1, 1, 1,  1, 1, 1, 1,  0, 1, 1, 1,  1, 1, 1, 1,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  0, 0, 0, 0,  1],
        .[1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1],
    ];

    tile_maps: [2][2]Tile_Map;

    // NOTE(nahua): Day 29 - Differ from Casey as we cast the Array of Arrays into 1D array
    tile_maps[0][0].tiles.data = cast(*u32) *tiles00[0][0];
    tile_maps[0][0].tiles.count = TILE_MAP_COUNT_X * TILE_MAP_COUNT_Y;

    tile_maps[0][1].tiles.data = cast(*u32) *tiles10[0][0];
    tile_maps[0][1].tiles.count = TILE_MAP_COUNT_X * TILE_MAP_COUNT_Y;

    tile_maps[1][0].tiles.data = cast(*u32) *tiles01[0][0];
    tile_maps[1][0].tiles.count = TILE_MAP_COUNT_X * TILE_MAP_COUNT_Y;

    tile_maps[1][1].tiles.data = cast(*u32) *tiles11[0][0];
    tile_maps[1][1].tiles.count = TILE_MAP_COUNT_X * TILE_MAP_COUNT_Y;

    world: World;
    world.tile_map_count_x = 2;
    world.tile_map_count_y = 2;
    world.count_x = TILE_MAP_COUNT_X;
    world.count_y = TILE_MAP_COUNT_Y;

    world.tile_maps.data = cast(*Tile_Map) *tile_maps[0][0];
    world.tile_maps.count = world.tile_map_count_x * world.tile_map_count_y;

    // TODO(nahua): Begin using tile side in meters
    world.tile_side_in_meters = 1.4;
    world.tile_side_in_pixels = 60;
    world.meters_to_pixels = cast(float32) world.tile_side_in_pixels / cast(float32) world.tile_side_in_meters;

    world.upper_left_x = -cast(float32)(world.tile_side_in_pixels / 2);
    world.upper_left_y = 0;

    player_height: float32 = 1.4;
    player_width: float32 = 0.75 * player_height;

    game_state: *Game_State = cast(*Game_State) memory.permanent_storage;

    tile_map: *Tile_Map = get_tile_map(*world, game_state.player_p.tile_map_x, game_state.player_p.tile_map_y);
    assert(tile_map != null);

    if !memory.is_initialized {
        memory.is_initialized = true;
        // NOTE(nahua): Initialize player position to be visible
        game_state.player_p.tile_map_x = 0;
        game_state.player_p.tile_map_y = 0;
        game_state.player_p.tile_x = 3;
        game_state.player_p.tile_y = 3;
        game_state.player_p.tile_rel_x = 5.0;
        game_state.player_p.tile_rel_y = 5.0;
    }

    for controller_index: 0..input.controllers.count-1 {
        controller: *Game_Controller_Input = get_controller(input, controller_index);
        if controller.is_analog {
            // NOTE(nahua): Use analog movement tuning
        } else {
            // NOTE(nahua): Use digital movement tuning
            d_player_x: float32 = 0;
            d_player_y: float32 = 0;

            if controller.move_right.ended_down d_player_x = 1;
            if controller.move_left.ended_down  d_player_x = -1;
            if controller.move_down.ended_down  d_player_y = 1;
            if controller.move_up.ended_down    d_player_y = -1;
            d_player_x *= 2.0;
            d_player_y *= 2.0;

            // TODO(nahua): Diagonal will be faster! Fix once we have vectors :)
            new_player_p := game_state.player_p;
            new_player_p.tile_rel_x += input.dt_for_frame * d_player_x;
            new_player_p.tile_rel_y += input.dt_for_frame * d_player_y;
            new_player_p = recanonicalize_position(*world, new_player_p);
            // TODO(nahua): Delta function that auto-recanonicalizes

            player_left := new_player_p;
            player_left.tile_rel_x -= 0.5 * player_width;
            player_left = recanonicalize_position(*world, player_left);

            player_right := new_player_p;
            player_right.tile_rel_x += 0.5 * player_width;
            player_right = recanonicalize_position(*world, player_right);

            if is_world_point_empty(*world, new_player_p) &&
               is_world_point_empty(*world, player_right) &&
               is_world_point_empty(*world, player_left)
            {
                game_state.player_p = new_player_p;
            }
        }
    }

    draw_rectangle(buffer, 0, 0, xx buffer.width, xx buffer.height, r = 1.0, g = 0.0, b = 1.0);

    for row: 0..TILE_MAP_COUNT_Y-1 {
        for col: 0..TILE_MAP_COUNT_X-1 {
            tile_id: u32 = get_tile_value_unchecked(*world, tile_map, cast(s32)col, cast(s32)row);
            gray: float32 = 0.5;
            if tile_id == 1 {
                gray = 1.0;
            }

            if (col == game_state.player_p.tile_x) && (row == game_state.player_p.tile_y) {
                gray = 0.0;
            }

            x: float32 = world.upper_left_x + (cast(float32)col) * world.tile_side_in_pixels;
            y: float32 = world.upper_left_y + (cast(float32)row) * world.tile_side_in_pixels;
            w: float32 = x + world.tile_side_in_pixels;
            h: float32 = y + world.tile_side_in_pixels;

            draw_rectangle(buffer, x, y, w, h, gray, gray, gray);
        }
    }

    player_r := 1.0;
    player_g := 1.0;
    player_b := 0.0;

    player_left: float32 = world.upper_left_x + world.tile_side_in_pixels * game_state.player_p.tile_x +
                           world.meters_to_pixels * game_state.player_p.tile_rel_x - 0.5 * world.meters_to_pixels * player_width;
    player_top: float32 = world.upper_left_y + world.tile_side_in_pixels * game_state.player_p.tile_y +
                          world.meters_to_pixels * game_state.player_p.tile_rel_y - world.meters_to_pixels * player_height;
    draw_rectangle(buffer,
                   player_left, player_top,
                   player_left + world.meters_to_pixels * player_width,
                   player_top + world.meters_to_pixels * player_height,
                   player_r, player_g, player_b);
}


get_tile_map :: (world: *World, tile_map_x: s32, tile_map_y: s32) -> *Tile_Map {
    tile_map: *Tile_Map = ---;
    if (tile_map_x >= 0 && tile_map_x < world.tile_map_count_x) &&
       (tile_map_y >= 0 && tile_map_y < world.tile_map_count_y)
    {
        tile_map = *world.tile_maps[tile_map_y * world.tile_map_count_x + tile_map_x];
    }

    return tile_map;
}


get_tile_value_unchecked :: (world: *World, tile_map: *Tile_Map, tile_x: s32, tile_y: s32) -> u32 {
    assert(tile_map != null);
    assert((tile_x >= 0 && tile_x < world.count_x) &&
           (tile_y >= 0 && tile_y < world.count_y));
    tile_map_value: u32 = tile_map.tiles[tile_y * world.count_x + tile_x];
    return tile_map_value;
}


is_tile_map_point_empty :: (world: *World, tile_map: *Tile_Map, test_tile_x: float32, test_tile_y: float32) -> bool {
    empty: bool;

    if tile_map {
        if test_tile_x >= 0 && test_tile_x < xx world.count_x &&
           test_tile_y >= 0 && test_tile_y < xx world.count_y
        {
            tile_map_value: u32 = get_tile_value_unchecked(world, tile_map, xx test_tile_x, xx test_tile_y);
            empty = (tile_map_value == 0);
        }
    }

    return empty;
}


recanonicalize_coord :: (world: *World, tile_count: s32, tile_map: *s32, tile: *s32, tile_rel: *float32) {
    // TODO(nahua): Need method that doesn't use divide/multiply to avoid rounding back onto previous tile
    // TODO(nahua): Add bounds checking to prevent wrapping

    offset := cast(s32) floor(tile_rel.* / world.tile_side_in_meters);
    tile.* += offset;
    tile_rel.* -= offset * world.tile_side_in_meters;

    assert(tile_rel.* >= 0);
    assert(tile_rel.* <= world.tile_side_in_meters);

    if tile.* < 0 {
        tile.* = tile_count + tile.*;
        tile_map.* -= 1;
    }

    if tile.* >= tile_count {
        tile.* = tile.* - tile_count;
        tile_map.* += 1;
    }
}


recanonicalize_position :: (world: *World, pos: Canonical_Position) -> Canonical_Position {
    result := pos;
    recanonicalize_coord(world, world.count_x, *result.tile_map_x, *result.tile_x, *result.tile_rel_x);
    recanonicalize_coord(world, world.count_y, *result.tile_map_y, *result.tile_y, *result.tile_rel_y);
    return result;
}


is_world_point_empty :: (world: *World, can_pos: Canonical_Position) -> bool {
    empty: bool;
    tile_map := get_tile_map(world, can_pos.tile_map_x, can_pos.tile_map_y);
    empty = is_tile_map_point_empty(world, tile_map, xx can_pos.tile_x, xx can_pos.tile_y);

    return empty;
}

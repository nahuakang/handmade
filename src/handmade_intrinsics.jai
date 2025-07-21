round_float32_to_s32 :: inline (number: float32) -> s32 {
    result := cast(s32) (number + 0.5);
    return result;
}
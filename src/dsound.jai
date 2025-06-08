DSSCL_PRIORITY :: 0x2;
LPDIRECTSOUND8 :: *void;
LPUNKNOWN :: *void;


// Using DirectSoundCreate8 since Jai provides IDirectSound8 utilities
DirectSoundCreate8 :: (device: *void, ppds8: **IDirectSound8, outer: *void) -> s32 #foreign dsound_lib;

#scope_file
dsound_lib :: #system_library "dsound";

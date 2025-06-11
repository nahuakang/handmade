/*
  NOTE(nahua): This is the build file for Handmade Hero in Jai.
  Compile the program using:
  jai build - -<flag>

  Build flags include the following:

  HANDMADE_WIN32: TODO(nahua): Only exists in the original build.bat.

  HANDMADE_INTERNAL:
    0 - Build for public release
    1 - Build for developer only

  HANDMADE_SLOW:
    0 - No slow code allowed!
    1 - Slow code welcome.
*/

#import "Basic";
#import "Compiler";

build :: () {
    args := get_build_options().compile_time_command_line;
    build_exe := !array_find(args, "-dll-only");  // Default to building exe unless -dll-only is specified

    // Build Win32 Handmade Platform Layer
    if build_exe {
        {
            w := compiler_create_workspace("Handmade Platform");
            if !w {
                print("Workspace creation failed.\n");
                return;
            }

            options := get_build_options(w);
            options.output_executable_name = "win32_handmade";
            options.output_path = "build";
            set_optimization(*options, .DEBUG);

            args := options.compile_time_command_line;
            internal_build := array_find(args, "-internal"); // jai build.jai - -internal
            slow_code      := array_find(args, "-slow");     // jai build.jai - -slow

            set_build_options(options, w);

            add_build_file("src/win32_handmade.jai", w);

            if internal_build {
                add_build_string("HANDMADE_INTERNAL :: 1;", w);
            } else {
                add_build_string("HANDMADE_INTERNAL :: 0;", w);
            }
        }
    }

    // Build Handemade DLL for Game-Specific Code
    {
        w := compiler_create_workspace("Handmade DLL");

        options := get_build_options();
        options.output_executable_name = "handmade";
        options.output_path = "build";
        options.output_type            = .DYNAMIC_LIBRARY;
        set_optimization(*options, .DEBUG);

        args := options.compile_time_command_line;
        internal_build := array_find(args, "-internal"); // jai build.jai - -internal
        slow_code      := array_find(args, "-slow");     // jai build.jai - -slow

        set_build_options(options, w);

        add_build_file("src/handmade.jai", w);

        if internal_build {
            add_build_string("HANDMADE_INTERNAL :: 1;", w);
        } else {
            add_build_string("HANDMADE_INTERNAL :: 0;", w);
        }
    }

    {
        set_build_options_dc(.{do_output=false});
    }
}

#run build();
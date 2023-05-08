// --- Libraries
#load "stb/stb_image.p";

// --- Modules
#load "basic.p";
#load "window.p";
#load "font.p";
#load "text_input.p";
#load "gl_context.p";
#load "gl_layer.p";
#load "math/v2f.p";
#load "math/v3f.p";
#load "math/v4f.p";
#load "math/m4f.p";
#load "math/quatf.p";
#load "math/linear.p";

// --- Local files
#load "draw.p";
#load "commands.p";
#load "command_handlers.p";
#load "win32.p";

// --- Fonts
CASCADIO_MONO   :: "C:/windows/fonts/cascadiamono.ttf";
TIMES_NEW_ROMAN :: "C:/windows/fonts/times.ttf";
COURIER_NEW     :: "C:/windows/fonts/cour.ttf";

// --- Timing
EXPECTED_FPS: f32 : 60;
EXPECTED_FRAME_TIME_MILLISECONDS: f32 : 1000 / EXPECTED_FPS;

// --- Styling
Theme :: struct {
    name: string;
    font_color: Color;
    background_color: Color;
    font: Font;
}

CmdX :: struct {
    global_memory_arena: Memory_Arena;
    global_memory_pool: Memory_Pool;
    global_allocator: Allocator;

    frame_memory_arena: Memory_Arena;
    frame_allocator: Allocator;
    
    window: Window;
    renderer: Renderer;

    text_input: Text_Input;
    backlog: [..]string;

    commands: [..]Command;
    current_directory: string;
    current_child_process_name: string;
    
    active_theme: *Theme;
    themes: [..]Theme;

    win32_pipes: Win32_Pipes;
}

add_string_to_backlog :: (cmdx: *CmdX, message: string) {
    array_add(*cmdx.backlog, copy_string(message, *cmdx.global_allocator));
}

cmdx_print :: (cmdx: *CmdX, format: string, args: ..any) {
    required_characters := query_required_print_buffer_size(format, ..args);

    message: string = ---;
    message.count = required_characters;
    message.data  = xx allocate(*cmdx.global_allocator, required_characters);

    mprint(string_view(message.data, message.count), format, ..args);
    array_add(*cmdx.backlog, message);
}

create_theme :: (cmdx: *CmdX, name: string, font_path: string, font_color: Color, background_color: Color) -> *Theme {
    theme := array_push(*cmdx.themes);
    theme.name = name;
    theme.font_color = font_color;
    theme.background_color = background_color;
    load_font(*theme.font, font_path, 15, xx create_gl_texture_2d, null);
    return theme;
}

update_window_name :: (cmdx: *CmdX) {
    window_name := concatenate_strings("cmdX | ", cmdx.current_directory, *cmdx.frame_allocator);

    if cmdx.current_child_process_name.count {
        // This is pretty bad... Should probably just use some kind of string builder for this, but that
        // does not exist yet.
        window_name = concatenate_strings(window_name, " (", *cmdx.frame_allocator);
        window_name = concatenate_strings(window_name, cmdx.current_child_process_name, *cmdx.frame_allocator);
        window_name = concatenate_strings(window_name, ")", *cmdx.frame_allocator);
    }

    set_window_name(*cmdx.window, window_name);
}

single_cmdx_frame :: (cmdx: *CmdX) {
    frame_start := get_hardware_time();

    // Prepare the next frame
    update_window(*cmdx.window);
    prepare_renderer(*cmdx.renderer, cmdx.active_theme, *cmdx.window);        
    
    // Update the terminal input
    for i := 0; i < cmdx.window.text_input_event_count; ++i   handle_text_input_event(*cmdx.text_input, cmdx.window.text_input_events[i]);
    
    // Draw all the text in the terminal
    draw_text(*cmdx.renderer, cmdx.active_theme, ">", 5, cmdx.window.height - 10);
    draw_text_input(*cmdx.renderer, cmdx.active_theme, *cmdx.text_input, 20, cmdx.window.height - 10);
    draw_backlog(*cmdx.renderer, cmdx.active_theme, *cmdx.backlog, 5, cmdx.window.height - 10 - cmdx.active_theme.font.line_height);

    // Reset the frame arena
    reset_memory_arena(*cmdx.frame_memory_arena);
    
    // Finish the frame, sleep until the next one
    swap_gl_buffers(*cmdx.window);

    frame_end := get_hardware_time();
    active_frame_time := convert_hardware_time(frame_end - frame_start, .Milliseconds);
    if active_frame_time < EXPECTED_FRAME_TIME_MILLISECONDS - 1 {
        time_to_sleep: f32 = EXPECTED_FRAME_TIME_MILLISECONDS - active_frame_time;
        Sleep(xx floorf(time_to_sleep) - 1);
    }
}

main :: () -> s32 {
    // Set up CmdX
    cmdx: CmdX;
    create_memory_arena(*cmdx.global_memory_arena, 4 * GIGABYTES);
    create_memory_pool(*cmdx.global_memory_pool, *cmdx.global_memory_arena);
    cmdx.global_allocator  = memory_pool_allocator(*cmdx.global_memory_pool);
    cmdx.backlog.allocator = *cmdx.global_allocator;
    
    create_memory_arena(*cmdx.frame_memory_arena, 512 * MEGABYTES);
    cmdx.frame_allocator = memory_arena_allocator(*cmdx.frame_memory_arena);

    cmdx.current_directory = copy_string(get_working_directory(), *cmdx.global_allocator);
    cmdx.text_input.active = true;
    register_all_commands(*cmdx);

    // Set the working directory of this program to where to executable file is, so that the data folder
    // can always be accessed.
    run_tree := get_module_path();
    defer free_string(run_tree, *Default_Allocator);
    set_working_directory(run_tree);
    enable_high_resolution_time(); // Enable high resolution sleeping to keep a steady frame rate
        
    // Create the window and the renderer
    create_window(*cmdx.window, concatenate_strings("cmdX | ", cmdx.current_directory, *cmdx.frame_allocator), 1280, 720, WINDOW_DONT_CARE, WINDOW_DONT_CARE, false);
    create_gl_context(*cmdx.window, 3, 3);
    create_renderer(*cmdx.renderer);
    cmdx.active_theme = create_theme(*cmdx, "light", COURIER_NEW, .{ 10, 10, 10, 255 }, .{ 255, 255, 255, 255 });
    create_theme(*cmdx, "dark", COURIER_NEW, .{ 255, 255, 255, 255 }, .{ 0, 0, 0, 255 });
    
    while !cmdx.window.should_close {
        single_cmdx_frame(*cmdx);

        if cmdx.text_input.entered {
            // The user has entered a string, add that to the backlog, clear the input and actually run
            // the command.
            input_string := get_string_view_from_text_input(*cmdx.text_input);
            clear_text_input(*cmdx.text_input);
            activate_text_input(*cmdx.text_input);

            if input_string.count {
                feedback_string := concatenate_strings("> ", input_string, *cmdx.global_allocator);
                add_string_to_backlog(*cmdx, feedback_string);
                handle_input_string(*cmdx, input_string);
            }
        }
    }

    // Cleanup
    destroy_renderer(*cmdx.renderer);
    destroy_gl_context(*cmdx.window);
    destroy_window(*cmdx.window);
    return 0;
}

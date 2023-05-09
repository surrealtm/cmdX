// --- Libraries
#load "stb/stb_image.p";

// --- Modules
#load "basic.p";
#load "window.p";
#load "font.p";
#load "text_input.p";
#load "gl_context.p";
#load "gl_layer.p";
#load "string_builder.p";
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
    font_path: string; // Needed for reloading the font when the size changes
    font_color: Color;       // The default color for text in the input and backlog
    cursor_color: Color;     // The color for the text input cursor
    accent_color: Color;     // The color for highlighted text, e.g. the current directory
    background_color: Color; // The background color of the window
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

    font_size: u32 = 15;
    active_theme: *Theme;
    themes: [..]Theme;

    win32_pipes: Win32_Pipes;
}

add_string_to_backlog :: (cmdx: *CmdX, message: string) {
    array_add(*cmdx.backlog, copy_string(message, *cmdx.global_allocator));
}

remove_string_from_backlog :: (cmdx: *CmdX, index: s64) {
    string := array_get_value(*cmdx.backlog, index);
    free_string(string, *cmdx.global_allocator);
    array_remove(*cmdx.backlog, index);
}

append_string_to_backlog :: (cmdx: *CmdX, message: string) {
    assert(cmdx.backlog.count > 0, "Cannot append string to backlog; backlog is empty");
    last_string := array_get(*cmdx.backlog, cmdx.backlog.count - 1);
    new_message := concatenate_strings(~last_string, message, *cmdx.global_allocator);
    remove_string_from_backlog(cmdx, cmdx.backlog.count - 1);
    add_string_to_backlog(cmdx, new_message);
}

cmdx_print :: (cmdx: *CmdX, format: string, args: ..any) {
    required_characters := query_required_print_buffer_size(format, ..args);

    message: string = ---;
    message.count = required_characters;
    message.data  = xx allocate(*cmdx.global_allocator, required_characters);

    mprint(string_view(message.data, message.count), format, ..args);
    array_add(*cmdx.backlog, message);
}

create_theme :: (cmdx: *CmdX, name: string, font_path: string, font: Color, cursor: Color, accent: Color, background: Color) -> *Theme {
    theme := array_push(*cmdx.themes);
    theme.name = name;
    theme.font_path = font_path;
    theme.font_color = font;
    theme.cursor_color = cursor;
    theme.accent_color = accent;
    theme.background_color = background;
    load_font(*theme.font, theme.font_path, cmdx.font_size, xx create_gl_texture_2d, null);
    return theme;
}

update_font_size :: (cmdx: *CmdX, new_font_size: u32) {
    cmdx.font_size = new_font_size;
    
    for i := 0; i < cmdx.themes.count; ++i {
        theme := array_get(*cmdx.themes, i);
        destroy_font(*theme.font, xx destroy_gl_texture_2d, null);
        load_font(*theme.font, theme.font_path, cmdx.font_size, xx create_gl_texture_2d, null);
    }
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
    y := cmdx.window.height - cmdx.active_theme.font.line_height / 2;
    draw_text_input(*cmdx.renderer, cmdx.active_theme, *cmdx.text_input, 5, y);
    y -= cmdx.active_theme.font.line_height;
    draw_backlog(*cmdx.renderer, cmdx.active_theme, *cmdx.backlog, 5, y);

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
    cmdx.active_theme =
        create_theme(*cmdx, "light", COURIER_NEW, .{ 10, 10, 10, 255 },  .{  30,  30,  30, 255 }, .{  51,  94, 168, 255 }, .{ 255, 255, 255, 255 });
    create_theme(*cmdx, "dark",    COURIER_NEW, .{ 255, 255, 255, 255 }, .{ 255, 255, 255, 255 }, .{ 248, 173,  52, 255 }, .{   0,   0,   0, 255 });
    create_theme(*cmdx, "blue",    COURIER_NEW, .{ 186, 196, 214, 255 }, .{ 248, 173,  52, 255 }, .{ 248, 173,  52, 255 }, .{  21,  33,  42, 255 });
    create_theme(*cmdx, "monokai", COURIER_NEW, .{ 202, 202, 202, 255},  .{ 231, 231, 231, 255 }, .{ 141, 208,   6, 255 }, .{  39,  40,  34, 255 });;
    
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

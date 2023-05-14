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
#load "config.p";
#load "draw.p";
#load "commands.p";
#load "command_handlers.p";
#load "win32.p";

// --- Fonts
CASCADIO_MONO   :: "C:/windows/fonts/cascadiamono.ttf";
TIMES_NEW_ROMAN :: "C:/windows/fonts/times.ttf";
COURIER_NEW     :: "C:/windows/fonts/cour.ttf";

// --- Timing
REQUESTED_FPS: f32 : 60;
REQUESTED_FRAME_TIME_MILLISECONDS: f32 : 1000 / REQUESTED_FPS;

// --- Other global data
CONFIG_FILE_PATH :: ".cmdx-config";

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
    // Memory management
    global_memory_arena: Memory_Arena;
    global_memory_pool: Memory_Pool;
    global_allocator: Allocator;
    
    frame_memory_arena: Memory_Arena;
    frame_allocator: Allocator;
    
    // Output
    window: Window;
    renderer: Renderer;
    
    // Text
    text_input: Text_Input;
    backlog: [..]string;
    backlog_scroll_offset: s32; // In indices to the backlog array
    
    // Command handling
    commands: [..]Command;
    current_directory: string;
    child_process_name: string;
    child_process_running: bool;
    number_of_current_child_process_messages: u32;
    
    // Styling
    font_size: s64;
    active_theme_name: string;
    active_theme: *Theme;
    themes: [..]Theme;
    config: Config;
    
    // Platform data
    win32: Win32;
}

cmdx_clear_backlog :: (cmdx: *CmdX) {
    for i := 0; i < cmdx.backlog.count; ++i {
        string := array_get_value(*cmdx.backlog, i);
        if string.count free_string(string, *cmdx.global_allocator);
    }
    
    array_clear(*cmdx.backlog);
}

cmdx_remove_string :: (cmdx: *CmdX, index: s64) {
    string := array_get_value(*cmdx.backlog, index);
    free_string(string, *cmdx.global_allocator);
    array_remove(*cmdx.backlog, index);
    
    if cmdx.child_process_running --cmdx.number_of_current_child_process_messages;
}

cmdx_append_string :: (cmdx: *CmdX, message: string) {
    assert(cmdx.backlog.count > 0, "Cannot append string to backlog; backlog is empty");
    last_string := array_get(*cmdx.backlog, cmdx.backlog.count - 1);
    new_message := concatenate_strings(~last_string, message, *cmdx.global_allocator);
    cmdx_remove_string(cmdx, cmdx.backlog.count - 1);
    cmdx_add_string(cmdx, new_message);
}

cmdx_add_string :: (cmdx: *CmdX, message: string) {
    array_add(*cmdx.backlog, copy_string(message, *cmdx.global_allocator));
    if cmdx.child_process_running ++cmdx.number_of_current_child_process_messages;
}

cmdx_print_string :: (cmdx: *CmdX, format: string, args: ..any) {
    required_characters := query_required_print_buffer_size(format, ..args);
    
    message: string = ---;
    message.count = required_characters;
    message.data  = xx allocate(*cmdx.global_allocator, required_characters);
    
    mprint(string_view(message.data, message.count), format, ..args);
    array_add(*cmdx.backlog, message);
    
    if cmdx.child_process_running ++cmdx.number_of_current_child_process_messages;
}

cmdx_new_line :: (cmdx: *CmdX) {
    message: string = "";
    array_add(*cmdx.backlog, message);
    if cmdx.child_process_running ++cmdx.number_of_current_child_process_messages;
}

cmdx_finish_child_process :: (cmdx: *CmdX) {
    // After a command has successfully been executed, check to see how many messages have been 
    // pumped into the backlog. If there have been any, append a new line for better readability.
    if cmdx.number_of_current_child_process_messages cmdx_new_line(cmdx);
}

get_prefix_string :: (cmdx: *CmdX, arena: *Memory_Arena) -> string {
    string_builder: String_Builder = ---;
    create_string_builder(*string_builder, arena);
    if !cmdx.child_process_running    append_string(*string_builder, cmdx.current_directory);
    append_string(*string_builder, "> ");
    return finish_string_builder(*string_builder);
}

get_complete_input_string :: (cmdx: *CmdX, arena: *Memory_Arena, input_string: string) -> string {
    string_builder: String_Builder = ---;
    create_string_builder(*string_builder, arena);
    append_string(*string_builder, cmdx.current_directory);
    append_string(*string_builder, "> ");
    append_string(*string_builder, input_string);
    return finish_string_builder(*string_builder);
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

update_active_theme_pointer :: (cmdx: *CmdX) {
    // Try to find a theme in the list with the specified name
    for i := 0; i < cmdx.themes.count; ++i {
        t := array_get(*cmdx.themes, i);
        if compare_strings(t.name, cmdx.active_theme_name) {
            cmdx.active_theme = t;
            return;
        }
    }
    
    // No theme with that name could be found, revert back to the default one
    cmdx_print_string(cmdx, "No loaded theme named '%' could be found.", cmdx.active_theme_name);
    cmdx.active_theme = *cmdx.themes.data[0];
    cmdx.active_theme_name = cmdx.active_theme.name;
    
}

update_font_size :: (cmdx: *CmdX) {
    for i := 0; i < cmdx.themes.count; ++i {
        theme := array_get(*cmdx.themes, i);
        destroy_font(*theme.font, xx destroy_gl_texture_2d, null);
        load_font(*theme.font, theme.font_path, cmdx.font_size, xx create_gl_texture_2d, null);
    }
}

update_active_process_name :: (cmdx: *CmdX, name: string) {
    if cmdx.child_process_name.count   free_string(cmdx.child_process_name, *cmdx.global_allocator);
    cmdx.child_process_name = name;
    update_window_name(cmdx);
}

update_window_name :: (cmdx: *CmdX) {
    window_name := concatenate_strings("cmdX | ", cmdx.current_directory, *cmdx.frame_allocator);
    
    if cmdx.child_process_name.count {
        // This is pretty bad... Should probably just use some kind of string builder for this, but that
        // does not exist yet.
        window_name = concatenate_strings(window_name, " (", *cmdx.frame_allocator);
        window_name = concatenate_strings(window_name, cmdx.child_process_name, *cmdx.frame_allocator);
        window_name = concatenate_strings(window_name, ")", *cmdx.frame_allocator);
    }
    
    set_window_name(*cmdx.window, window_name);
}

single_cmdx_frame :: (cmdx: *CmdX) {
    frame_start := get_hardware_time();
    
    // Prepare the next frame
    update_window(*cmdx.window);
    prepare_renderer(*cmdx.renderer, cmdx.active_theme, *cmdx.window);
    
    cmdx.text_input.active = cmdx.window.focused;
    
    // Update the terminal input
    for i := 0; i < cmdx.window.text_input_event_count; ++i   handle_text_input_event(*cmdx.text_input, cmdx.window.text_input_events[i]);
    
    // Check for potential control keys
    if cmdx.child_process_running && cmdx.window.key_pressed[Key_Code.C] && cmdx.window.key_held[Key_Code.Control] {
        // Terminate the current running process
        win32_terminate_child_process(cmdx);
    }
    
    // Handle input for this frame
    if cmdx.text_input.entered {
        // The user has entered a string, add that to the backlog, clear the input and actually run
        // the command.
        input_string := get_string_view_from_text_input(*cmdx.text_input);
        clear_text_input(*cmdx.text_input);
        activate_text_input(*cmdx.text_input);
        
        if cmdx.child_process_running {
            win32_write_to_child_process(cmdx, input_string);
            cmdx.backlog_scroll_offset = 0;
        } else if input_string.count {
            cmdx_add_string(cmdx, get_complete_input_string(cmdx, *cmdx.global_memory_arena, input_string));
            handle_input_string(cmdx, input_string);
            cmdx.backlog_scroll_offset = 0;
        }
    }
    
    // Handle mouse input for scrolling
    if cmdx.window.mouse_wheel_turns != 0 {
        cmdx.backlog_scroll_offset = clamp(cmdx.backlog_scroll_offset + cmdx.window.mouse_wheel_turns, 0, cmdx.backlog.count - 1);
    }
    
    // Draw all messages in the backlog
    x := 5;
    input_y   := cmdx.window.height - cmdx.active_theme.font.line_height / 2;
    backlog_y := input_y - cmdx.active_theme.font.line_height;
    
    backlog_index: s64 = cmdx.backlog.count - 1 - cmdx.backlog_scroll_offset;
    while backlog_y > 0 && backlog_index >= 0 {
        log := array_get_value(*cmdx.backlog, backlog_index);
        draw_text(*cmdx.renderer, cmdx.active_theme, log, x, backlog_y, cmdx.active_theme.font_color);
        backlog_y -= cmdx.active_theme.font.line_height;
        --backlog_index;
    }
    
    // Draw the text input
    prefix_string := get_prefix_string(cmdx, *cmdx.frame_memory_arena);
    draw_text_input(*cmdx.renderer, cmdx.active_theme, *cmdx.text_input, prefix_string, x, input_y);
    
    // Reset the frame arena
    reset_memory_arena(*cmdx.frame_memory_arena);
    
    // Finish the frame, sleep until the next one
    swap_gl_buffers(*cmdx.window);
    
    frame_end := get_hardware_time();
    active_frame_time := convert_hardware_time(frame_end - frame_start, .Milliseconds);
    if active_frame_time < REQUESTED_FRAME_TIME_MILLISECONDS - 1 {
        time_to_sleep: f32 = REQUESTED_FRAME_TIME_MILLISECONDS - active_frame_time;
        Sleep(xx floorf(time_to_sleep) - 1);
    }
}

welcome_screen :: (cmdx: *CmdX, run_tree: string) {
    config_location := concatenate_strings(run_tree, CONFIG_FILE_PATH, *cmdx.frame_allocator);
    
    cmdx_print_string(cmdx, "Welcome to cmdX.");
    cmdx_print_string(cmdx, "Use the :help command as a starting point.");
    cmdx_print_string(cmdx, "The config file can be found under %.", config_location);
    cmdx_new_line(cmdx);
}

main :: () -> s32 {
    // Set up memory management
    cmdx: CmdX;
    create_memory_arena(*cmdx.global_memory_arena, 4 * GIGABYTES);
    create_memory_pool(*cmdx.global_memory_pool, *cmdx.global_memory_arena);
    cmdx.global_allocator  = memory_pool_allocator(*cmdx.global_memory_pool);
    cmdx.backlog.allocator = *cmdx.global_allocator;
    
    create_memory_arena(*cmdx.frame_memory_arena, 512 * MEGABYTES);
    cmdx.frame_allocator = memory_arena_allocator(*cmdx.frame_memory_arena);
    
    // Set up the command handling
    cmdx.current_directory = copy_string(get_working_directory(), *cmdx.global_allocator);
    cmdx.text_input.active = true;
    register_all_commands(*cmdx);
    
    // Set the working directory of this program to where to executable file is, so that the data 
    // folder can always be accessed.
    run_tree := get_module_path();
    defer free_string(run_tree, *Default_Allocator);
    set_working_directory(run_tree);
    enable_high_resolution_time(); // Enable high resolution sleeping to keep a steady frame rate
    
    // Set up all the required config properties, and read the config file if it exists
    create_integer_property(*cmdx.config, "font-size", xx *cmdx.font_size, 15);
    create_string_property(*cmdx.config, "theme", *cmdx.active_theme_name, "light");
    read_config_file(*cmdx, *cmdx.config, CONFIG_FILE_PATH);
    
    // Create the window and the renderer
    create_window(*cmdx.window, concatenate_strings("cmdX | ", cmdx.current_directory, *cmdx.frame_allocator), 1280, 720, WINDOW_DONT_CARE, WINDOW_DONT_CARE, false);
    create_gl_context(*cmdx.window, 3, 3);
    create_renderer(*cmdx.renderer);
    
    // Create the builtin themes
    create_theme(*cmdx, "light",   COURIER_NEW, .{  10,  10,  10, 255 }, .{  30,  30,  30, 255 }, .{  51,  94, 168, 255 }, .{ 255, 255, 255, 255 });
    create_theme(*cmdx, "dark",    COURIER_NEW, .{ 255, 255, 255, 255 }, .{ 255, 255, 255, 255 }, .{ 248, 173,  52, 255 }, .{   0,   0,   0, 255 });
    create_theme(*cmdx, "blue",    COURIER_NEW, .{ 186, 196, 214, 255 }, .{ 248, 173,  52, 255 }, .{ 248, 173,  52, 255 }, .{  21,  33,  42, 255 });
    create_theme(*cmdx, "monokai", COURIER_NEW, .{ 202, 202, 202, 255 }, .{ 231, 231, 231, 255 }, .{ 141, 208,   6, 255 }, .{  39,  40,  34, 255 });
    update_active_theme_pointer(*cmdx);
    
    // After everything has been loaded, actually show the window. This will prevent a small time 
    // frame in which the window is just blank white, which does not seem very clean. Instead, the 
    // window takes a little longer to show up, but it immediatly gets filled with the first frame.
    show_window(*cmdx.window);
    
    // Display the welcome message
    welcome_screen(*cmdx, run_tree);
    
    // Main loop until the window gets closed
    while !cmdx.window.should_close {
        single_cmdx_frame(*cmdx);
    }
    
    // Cleanup
    write_config_file(*cmdx.config, CONFIG_FILE_PATH);
    destroy_renderer(*cmdx.renderer);
    destroy_gl_context(*cmdx.window);
    destroy_window(*cmdx.window);
    return 0;
}

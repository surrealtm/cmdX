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

CASCADIO_MONO   :: "C:/windows/fonts/cascadiamono.ttf";
TIMES_NEW_ROMAN :: "C:/windows/fonts/times.ttf";
COURIER_NEW     :: "C:/windows/fonts/cour.ttf";

REQUESTED_FPS: f32 : 60;
REQUESTED_FRAME_TIME_MILLISECONDS: f32 : 1000 / REQUESTED_FPS;

CONFIG_FILE_NAME :: ".cmdx-config";

BACKLOG_SIZE :: 8129;

Theme :: struct {
    name: string;
    font_path: string; // Needed for reloading the font when the size changes
    font_color: Color;       // The default color for text in the input and backlog
    cursor_color: Color;     // The color for the text input cursor
    accent_color: Color;     // The color for highlighted text, e.g. the current directory
    background_color: Color; // The background color of the window
    font: Font;
}

Color_Range :: struct {
    end: s64;
    color: Color;
}

Backlog_Line :: struct {
    start: s64;
    end: s64;
}

CmdX :: struct {
    // Memory management
    global_memory_arena: Memory_Arena;
    global_memory_pool: Memory_Pool;
    global_allocator: Allocator;
    
    frame_memory_arena: Memory_Arena;
    frame_allocator: Allocator;
    
    // Output
    window: Window = ---;
    renderer: Renderer; // The renderer must be initialized for now or else the vertex buffers will have invalid values...  @Cleanup initialize these values in create_vertex_buffer...
    
    // Text
    text_input: Text_Input;
    backlog: [BACKLOG_SIZE]s8 = ---;
    colors: [..]Color_Range;
    lines: [..]Backlog_Line;
    scroll_offset: s64; // The index for the first line to be rendered at the top of the screen
    viewport_height: s64; // The amount of lines put into the backlog since the last command has been entered. Used for cursor positioning
    
    // Command handling
    commands: [..]Command;
    current_directory: string;
    child_process_name: string;
    child_process_running: bool;
    
    // Styling
    font_size: s64;
    active_theme_name: string;
    active_theme: *Theme;
    themes: [..]Theme;
    config: Config;
    
    // Platform data
    win32: Win32 = ---;
}

clear_backlog :: (cmdx: *CmdX) {
    array_clear(*cmdx.lines);
    array_clear(*cmdx.colors);
    new_line(cmdx);
    set_color(cmdx, cmdx.active_theme.font_color);
}

prepare_viewport :: (cmdx: *CmdX) {
    cmdx.viewport_height = 0;
}

close_viewport :: (cmdx: *CmdX) {
    // When the last command finishes, append another new line for more clarity
    new_line(cmdx);
}

get_cursor_position_in_line :: (cmdx: *CmdX) -> s64 {
    line_head := array_get(*cmdx.lines, cmdx.lines.count - 1);
    return line_head.end - line_head.start; // The current cursor position is considered to be at the end of the current line
}

set_cursor_position_in_line :: (cmdx: *CmdX, x: s64) {
    // Remove part of the backlog line
    line_head := array_get(*cmdx.lines, cmdx.lines.count - 1);
    line_head.end = line_head.start + x;
    
    // If part of the backlog just got erased, the end of the color range must be updated too.
    color_head := array_get(*cmdx.colors, cmdx.colors.count - 1);
    color_head.end = line_head.start + x;
}

set_cursor_position_to_beginning_of_line :: (cmdx: *CmdX) {
    set_cursor_position_in_line(cmdx, 0);
}

new_line :: (cmdx: *CmdX) {
    // Add a new line to the backlog
    new_line_head := array_push(*cmdx.lines);
    
    if cmdx.lines.count > 1 {
        // If there was a previous line, set the start of the new line in the backlog buffer to point 
        // just after the previous line
        old_line_head := array_get(*cmdx.lines, cmdx.lines.count - 2);
        new_line_head.start = old_line_head.end;
        new_line_head.end   = new_line_head.start;
    }
    
    ++cmdx.viewport_height;
    cmdx.scroll_offset = cmdx.lines.count;
}

add_text :: (cmdx: *CmdX, text: string) {
    line_head  := array_get(*cmdx.lines, cmdx.lines.count - 1);
    color_head := array_get(*cmdx.colors, cmdx.colors.count - 1);
    assert(line_head.end + text.count <= BACKLOG_SIZE, "Backlog buffer ran out of space");
    copy_memory(xx *cmdx.backlog[line_head.end], xx text.data, text.count);
    line_head.end  += text.count;
    color_head.end += text.count;
}

add_character :: (cmdx: *CmdX, character: s8) {
    character_copy := character; // Since character is a register parameter, we probably cannot take the pointer to that directly...
    string: string = ---;
    string.data = *character_copy;
    string.count = 1;
    add_text(cmdx, string);
}

add_formatted_text :: (cmdx: *CmdX, format: string, args: ..any) {
    required_characters := query_required_print_buffer_size(format, ..args);
    string := allocate_string(required_characters, *cmdx.frame_allocator);
    mprint(string, format, ..args);
    add_text(cmdx, string);
}

add_line :: (cmdx: *CmdX, text: string) {
    add_text(cmdx, text);
    new_line(cmdx);
}

add_formatted_line :: (cmdx: *CmdX, format: string, args: ..any) {
    add_formatted_text(cmdx, format, ..args);
    new_line(cmdx);
}


set_color :: (cmdx: *CmdX, color: Color) {
    if cmdx.colors.count == 0 {
        array_add(*cmdx.colors, .{ 0, color });
        return;
    }
    
    color_head := array_get(*cmdx.colors, cmdx.colors.count - 1);
    if !compare_colors(color_head.color, color) {
        line_head := array_get(*cmdx.lines, cmdx.lines.count - 1);
        color_head.end = line_head.end;
        array_add(*cmdx.colors, .{ 0, color });
    }
}

get_prefix_string :: (cmdx: *CmdX, arena: *Memory_Arena) -> string {
    string_builder: String_Builder = ---;
    create_string_builder(*string_builder, arena);
    if !cmdx.child_process_running    append_string(*string_builder, cmdx.current_directory);
    append_string(*string_builder, "> ");
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
    add_formatted_line(cmdx, "No loaded theme named '%' could be found.", cmdx.active_theme_name);
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
        // does not exist yet.   @Cleanup it now does idiot, so fix this shit
        window_name = concatenate_strings(window_name, " (", *cmdx.frame_allocator);
        window_name = concatenate_strings(window_name, cmdx.child_process_name, *cmdx.frame_allocator);
        window_name = concatenate_strings(window_name, ")", *cmdx.frame_allocator);
    }
    
    set_window_name(*cmdx.window, window_name);
}

one_cmdx_frame :: (cmdx: *CmdX) {
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
            // Send the input to the child process
            win32_write_to_child_process(cmdx, input_string);
        } else if input_string.count {
            // Print the complete input line into the backlog
            set_color(cmdx, cmdx.active_theme.accent_color);
            add_text(cmdx, cmdx.current_directory);
            add_text(cmdx, "> ");    
            set_color(cmdx, cmdx.active_theme.font_color);
            add_line(cmdx, input_string);
            // Actually launch the command
            handle_input_string(cmdx, input_string);
        }
    }
    
    // The amount of visible lines on screen this frame
    visible_line_count: s32 = cast(s32) ceilf(cast(f32) cmdx.window.height / cast(f32) cmdx.active_theme.font.line_height);
    if cmdx.scroll_offset <= visible_line_count - 1   visible_line_count = cmdx.window.height / cmdx.active_theme.font.line_height;
    
    // The amount of lines that fully fit into the screen space, without having to cut off the upper part of the line
    drawn_line_count: s32 = min(cast(s32) cmdx.lines.count, visible_line_count);
    
    // Handle scrolling with the mouse wheel
    cmdx.scroll_offset = clamp(cmdx.scroll_offset - cmdx.window.mouse_wheel_turns, drawn_line_count - 1, cmdx.lines.count);
    
    // Set up coordinates for rendering
    cursor_x: s32 = 5;
    cursor_y: s32 = cmdx.window.height - (drawn_line_count - 1) * cmdx.active_theme.font.line_height - 5;
    
    // Draw all messages in the backlog
    line_index: s64 = clamp(cmdx.scroll_offset - drawn_line_count, 0, cmdx.lines.count - 1);
    
    color_range_index: s64 = -1;
    color_range: Color_Range; // This will be overwritten by the first character written from the backlog, since the cursor will always be >= than the end of this range, which is 0
    
    while line_index < cmdx.lines.count { // @Cleanup only actually render drawn_line_count lines, this should currently build up wayyy to many lines to render...
        line := array_get(*cmdx.lines, line_index);
        for cursor := line.start; cursor < line.end; ++cursor {
            character := cmdx.backlog[cursor];
            
            while cursor >= color_range.end && color_range_index + 1 < cmdx.colors.count {
                flush_font_buffer(*cmdx.renderer);
                ++color_range_index;
                color_range = array_get_value(*cmdx.colors, color_range_index);
                cmdx.renderer.foreground_color = color_range.color;
            }
            
            cursor_x, cursor_y = render_single_character_with_font(*cmdx.active_theme.font, character, cursor_x, cursor_y, xx draw_single_glyph, xx *cmdx.renderer);
            if cursor + 1 < line.end     cursor_x = apply_font_kerning_to_cursor(*cmdx.active_theme.font, character, cmdx.backlog[cursor + 1], cursor_x);
        }
        
        if line_index + 1 < cmdx.lines.count   cursor_y += cmdx.active_theme.font.line_height;
        cursor_x = 5;
        
        ++line_index;        
    }        
    
    // Draw the text input
    prefix_string := get_prefix_string(cmdx, *cmdx.frame_memory_arena);
    draw_text_input(*cmdx.renderer, cmdx.active_theme, *cmdx.text_input, prefix_string, cursor_x, cursor_y);
    
    // Reset the frame arena
    reset_allocator(*cmdx.frame_allocator);
    
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
    set_color(cmdx, cmdx.active_theme.accent_color);
    add_line(cmdx, "    Welcome to cmdX.");
    set_color(cmdx, cmdx.active_theme.font_color);
    
    add_line(cmdx, "Use the :help command as a starting point.");
    
    config_location := concatenate_strings(run_tree, CONFIG_FILE_NAME, *cmdx.frame_allocator);
    add_formatted_line(cmdx, "The config file can be found under %.", config_location);
    new_line(cmdx);
}

main :: () -> s32 {
    // Set up memory management
    cmdx: CmdX;
    create_memory_arena(*cmdx.global_memory_arena, 1 * GIGABYTES);
    create_memory_pool(*cmdx.global_memory_pool, *cmdx.global_memory_arena);
    cmdx.global_allocator  = memory_pool_allocator(*cmdx.global_memory_pool);
    
    create_memory_arena(*cmdx.frame_memory_arena, 16 * MEGABYTES);
    cmdx.frame_allocator = memory_arena_allocator(*cmdx.frame_memory_arena);

    // Link the allocators to all important data structures
    cmdx.colors.allocator   = *cmdx.global_allocator;
    cmdx.lines.allocator    = *cmdx.global_allocator;
    cmdx.commands.allocator = *cmdx.global_allocator;
    cmdx.themes.allocator   = *cmdx.global_allocator;
    
    // Set up the command handling
    cmdx.current_directory = copy_string(get_working_directory(), *cmdx.global_allocator);
    cmdx.text_input.active = true;
    register_all_commands(*cmdx);
    
    // Set the working directory of this program to where to executable file is, so that the data 
    // folder can always be accessed.
    run_tree := get_module_path();
    defer free_string(run_tree, Default_Allocator);
    set_working_directory(run_tree);
    enable_high_resolution_time(); // Enable high resolution sleeping to keep a steady frame rate
    
    // Set up all the required config properties, and read the config file if it exists
    create_integer_property(*cmdx.config, "font-size", xx *cmdx.font_size, 15);
    create_string_property(*cmdx.config, "theme", *cmdx.active_theme_name, "light");
    read_config_file(*cmdx, *cmdx.config, CONFIG_FILE_NAME);
    
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
    clear_backlog(*cmdx); // Prepare the backlog by clearing it. This will create the initial line and color range
    welcome_screen(*cmdx, run_tree);
    
    // Main loop until the window gets closed
    while !cmdx.window.should_close {
        one_cmdx_frame(*cmdx);
    }
        
    // Cleanup
    write_config_file(*cmdx.config, CONFIG_FILE_NAME);
    destroy_renderer(*cmdx.renderer);
    destroy_gl_context(*cmdx.window);
    destroy_window(*cmdx.window);

    free_memory_pool(*cmdx.global_memory_pool);
    free_memory_arena(*cmdx.global_memory_arena);
    free_memory_arena(*cmdx.frame_memory_arena);
    
    return 0;
}

// --- Libraries
#load "stb/stb_image.p";

// --- Modules
#load "basic.p";
#load "window.p";
#load "font.p";
#load "text_input.p";
#load "ui.p";
#load "gl_context.p";
#load "gl_layer.p";
#load "string_builder.p";
#load "hash_table.p";
#load "math/v2f.p";
#load "math/v3f.p";
#load "math/v4f.p";
#load "math/m4f.p";
#load "math/quatf.p";
#load "math/linear.p";
#load "random.p";

// --- Project files
#load "screen.p";
#load "config.p";
#load "actions.p";
#load "draw.p";
#load "commands.p";
#load "command_handlers.p";
#load "win32.p";
#load "create_big_file.p";

/* =========================== Default font paths to remember =========================== */

CASCADIO_MONO    :: "C:\\windows\\fonts\\cascadiamono.ttf";
TIMES_NEW_ROMAN  :: "C:\\windows\\fonts\\times.ttf";
COURIER_NEW      :: "C:\\windows\\fonts\\cour.ttf";
ARIAL            :: "C:\\windows\\fonts\\arial.ttf";
FIRACODE_REGULAR :: "C:\\source\\cmdX\\run_tree\\data\\FiraCode-Regular.ttf";

/* =========================== Visual Constants =========================== */

SCROLL_BAR_WIDTH :: 10;
OFFSET_FROM_SCREEN_BORDER :: 5; // How many pixels to leave empty between the text and the screen border
OFFSET_FOR_WRAPPED_LINES :: 15; // Additional indentation of wrapped lines

/* =========================== Data Structures =========================== */

Color_Index :: enum {
    Default;    // The default font color
    Cursor;     // The color of the cursor
    Accent;     // The color of highlit text, e.g. the working directory
    Background; // The background of the terminal backlog
    Scrollbar;  // The background of the scrollbar
    Selection;  // The selection color for both the backlog and the text input
}

Draw_Overlay :: enum {
    None             :: 0;
    Line_Backgrounds :: 1;
    Whitespaces      :: 2;
    Line_Wrapping    :: 4;
}

Theme :: struct {
    name: string;
    colors: [Color_Index.count]Color;
}

CmdX :: struct {
    setup: bool = false; // This flag gets set to true once the welcome screen was displayed. It indicates that everything has been loaded and initialized, and the terminal will behave as expected. Before this happens, the config may not be loaded yet, the backlog may not exist yet...
    startup_directory: string; // Remember the startup directory, since newly created screens should start in this directory. CmdX sets the working directory to its run_tree folder to have the asset files ready

    // Memory management
    global_memory_arena: Memory_Arena;
    global_memory_pool: Memory_Pool;
    global_allocator: Allocator;

    frame_memory_arena: Memory_Arena;
    frame_allocator: Allocator;

    // Output
    window: Window;
    renderer: Renderer = ---;
    draw_frame: bool; // When nothing has changed on screen, then there is no need to re-render everything. Save GPU power by not rendering this frame, and instead just reuse the current backbuffer.
    draw_ui: bool; // Currently no UI is actually implemented, therefore this will always be false. Keep this for now, in case we want some UI back in the future.
    ui: UI;
    disabled_title_bar: bool = false; // The user can toggle the window's title bar, since not having it may look cleaner, but disables window movement.
    draw_overlays: Draw_Overlay = .Line_Wrapping;

    // Font
    font_size: s64 = 15;
    font_path: string = COURIER_NEW;
    font: Font;

    // Themes
    active_theme_name: string = "blue";
    active_theme: *Theme;
    themes: [..]Theme;

    // Global data
    commands: [..]Command;
    config: Config;

    // Global config variables. The history and backlog size are copied into each screen for easier access
    // and also to have a definitive number which is correct, when the sizes get changed by the config.
    history_size:         s64 = 64;    // The number of history lines to keep
    backlog_size:         s64 = 65535; // The size of the backlog for each screen in bytes
    scroll_speed:         s64 = 3;     // In lines per mouse wheel turn
    scroll_interpolation: f32 = 30;    // How fast the scrolling should interpolate towards the target. 0 Means snapping
    requested_fps:        f32 = 60;
    enable_line_wrapping: bool = true;

    // Screens
    screens: Linked_List(Screen);
    hovered_screen: *Screen; // The screen over which the mouse currently hovers. Scrolling occurs in this screen. When the left button is pressed, this screen gets activated.
    active_screen: *Screen; // Screen with active text input and highlighted rendering.
}


/* =========================== Debug Procedures =========================== */

debug_print_lines :: (printer: *Print_Buffer, screen: *Screen) {
    bprint(printer, "=== LINES ===\n");

    for i := 0; i < screen.backlog_lines.count; ++i {
        line := array_get(*screen.backlog_lines, i);
        bprint(printer, "I %: % -> % ", i, line.first, line.one_plus_last);

        if line.wrapped
            bprint(printer, "     '%*%' (wrapped)", string_view(*screen.backlog[line.first], screen.backlog_size - line.first), string_view(*screen.backlog[0], line.one_plus_last));
        else
            bprint(printer, "     '%'", string_view(*screen.backlog[line.first], line.one_plus_last - line.first));

        bprint(printer, "\n");
    }

    bprint(printer, "=== LINES ===\n");
}

debug_print_colors :: (printer: *Print_Buffer, screen: *Screen) {
    bprint(printer, "=== COLORS ===\n");

    for i := 0; i < screen.backlog_colors.count; ++i {
        color := array_get(*screen.backlog_colors, i);
        bprint(printer, "C %: % -> % (% | %, %, %)", i, color.range.first, color.range.one_plus_last, cast(s32) color.color_index, color.true_color.r, color.true_color.g, color.true_color.b);
        if color.range.wrapped bprint(printer, " (wrapped)");
        bprint(printer, "\n");
    }

    bprint(printer, "=== COLORS ===\n");
}

debug_print_history :: (printer: *Print_Buffer, screen: *Screen) {
    bprint(printer, "=== HISTORY ===\n");

    for i := 0; i < screen.history.count; ++i {
        string := array_get_value(*screen.history, i);
        bprint(printer, "H %: '%'\n", i, string);
    }

    bprint(printer, "=== HISTORY ===\n");
}

debug_print_to_file :: (file_path: string, screen: *Screen) {
    printer: Print_Buffer;
    create_file_printer(*printer, file_path);

    debug_print_lines(*printer, screen);
    debug_print_colors(*printer, screen);
    debug_print_history(*printer, screen);

    close_file_printer(*printer);
}

debug_print :: (screen: *Screen) {
    printer: Print_Buffer;
    printer.output_handle = GetStdHandle(STD_OUTPUT_HANDLE);

    debug_print_lines(*printer, screen);
    debug_print_colors(*printer, screen);
    debug_print_history(*printer, screen);

    print_buffer_flush(*printer);
}

random_line :: (cmdx: *CmdX) {
    color: Color = ---;
    color.r = get_random_integer() % 255;
    color.g = get_random_integer() % 255;
    color.b = get_random_integer() % 255;
    color.a = 255;

    set_true_color(cmdx.active_screen, color);
    add_line(cmdx, cmdx.active_screen, "Hello World, these are 40 Characters.!!!");
}

cmdx_assert :: (active_screen: *Screen, condition: bool, text: string) {
    if condition return;

    debug_print_to_file("cmdx_log.txt", active_screen);
    assert(condition, text);
}


/* =========================== Helper Procedures =========================== */

mouse_over_rectangle :: (cmdx: *CmdX, rectangle: []s32) -> bool {
    return cmdx.window.mouse_active &&
        cmdx.window.mouse_x >= rectangle[0] && cmdx.window.mouse_x < rectangle[2] &&
        cmdx.window.mouse_y >= rectangle[1] && cmdx.window.mouse_y < rectangle[3];
}

get_window_style_and_range_check_window_position_and_size :: (cmdx: *CmdX) -> Window_Style_Flags {
    // Calculate the window style flags
    window_style: Window_Style_Flags;
    if cmdx.window.maximized window_style |= .Maximized;
    if cmdx.disabled_title_bar    window_style |= .Hide_Title_Bar;
    else window_style |= .Default;
    return window_style;
}


/* =========================== CmdX Properties =========================== */

create_theme :: (cmdx: *CmdX, name: string, default: Color, cursor: Color, accent: Color, background: Color, scrollbar: Color, selection: Color) -> *Theme {
    theme := array_push(*cmdx.themes);
    theme.name = name;
    theme.colors[Color_Index.Default]    = default;
    theme.colors[Color_Index.Cursor]     = cursor;
    theme.colors[Color_Index.Accent]     = accent;
    theme.colors[Color_Index.Background] = background;
    theme.colors[Color_Index.Scrollbar]  = scrollbar;
    theme.colors[Color_Index.Selection]  = selection;
    return theme;
}

update_active_theme_pointer :: (cmdx: *CmdX, theme_name: string) {
    // Try to find a theme in the list with the specified name
    for i := 0; i < cmdx.themes.count; ++i {
        t := array_get(*cmdx.themes, i);
        if compare_strings(t.name, theme_name) {
            // Always keep the active_theme_name on the config allocator, as it may also come from a command
            // or something similar. This way, we can always free it properly and don't leak anything. In case
            // the theme_name parameter is the active_theme_name (e.g. when reloading the config), copy the
            // string before freeing it.
            previous_string := cmdx.active_theme_name;
            cmdx.active_theme_name = copy_string(cmdx.config.allocator, theme_name);
            deallocate_string(cmdx.config.allocator, *previous_string);
            cmdx.active_theme = t;
            return;
        }
    }

    // No theme with that name could be found. Report it back to the user.
    config_error(cmdx, "No loaded theme named '%' could be found.", theme_name);

    if !cmdx.active_theme {
        // If there is no valid active theme pointer, revert back to the default since a theme pointer
        // is required. If there is already a theme loaded and the user tried to switch to a different
        // one, then just ignore this and leave everything as was.
        cmdx.active_theme = *cmdx.themes.data[0];
    }

    // The config system expects to be able to deallocate this eventually
    deallocate_string(cmdx.config.allocator, *cmdx.active_theme_name);
    cmdx.active_theme_name = copy_string(cmdx.config.allocator, cmdx.active_theme.name);
}

update_font :: (cmdx: *CmdX) {
    destroy_font(*cmdx.font, xx destroy_gl_texture_2d, null);

    success := create_font_from_file(*cmdx.font, cmdx.font_path, cmdx.font_size, true, create_gl_texture_2d, null);
    
    if !success {
        config_error(cmdx, "The font '%' could not be found, reverting back to default '%'.", cmdx.font_path, COURIER_NEW);
        cmdx.font_path = copy_string(cmdx.config.allocator, COURIER_NEW);
        create_font_from_file(*cmdx.font, cmdx.font_path, cmdx.font_size, true, create_gl_texture_2d, null);
    }
}

update_active_process_name :: (cmdx: *CmdX, screen: *Screen, process_name: string) {
    if compare_strings(screen.child_process_name, process_name) return;

    if screen.child_process_name.count   deallocate_string(*cmdx.global_allocator, *screen.child_process_name);
    screen.child_process_name = copy_string(*cmdx.global_allocator, process_name);

    update_window_name(cmdx);
}

update_window_name :: (cmdx: *CmdX) {
    builder: String_Builder = ---;
    create_string_builder(*builder, *cmdx.frame_allocator);
    append_string(*builder, "cmdX | ");
    append_string(*builder, cmdx.active_screen.current_directory);

    if cmdx.active_screen.child_process_name.count append_format(*builder, " (%)", cmdx.active_screen.child_process_name);

    set_window_name(*cmdx.window, finish_string_builder(*builder));
}

update_backlog_size :: (cmdx: *CmdX) {
    // When the backlog is resized, it is almost impossible to properly adjust the stored lines and color ranges
    // to best represent the new backlog, since the ringbuffer makes it pretty hard to figure out what will
    // fit into the new backlog, and what must be removed.
    // It is also very unlikely that one will often adjust this value during runtime, so it should not be
    // a big problem if the backlog is cleared here.
    for it := cmdx.screens.first; it; it = it.next {
        screen := *it.data;
        if screen.backlog_size == cmdx.backlog_size continue;

        deallocate(*cmdx.global_allocator, screen.backlog);
        screen.backlog = allocate(*cmdx.global_allocator, cmdx.backlog_size);
        screen.backlog_size = cmdx.backlog_size;
        clear_screen(cmdx, screen);
    }
}

update_history_size :: (cmdx: *CmdX) {
    // If the history size gets shrunk down, the history log of each screen may need to be cut down to
    // represent that change. If there are fewer entries in the log than the new size, or if the size
    // actually increased, then there is nothing to be done.
    for it := cmdx.screens.first; it; it = it.next {
        screen := *it.data;
        if screen.history.count > cmdx.history_size    array_remove_range(*screen.history, cmdx.history_size, screen.history.count - 1);
        screen.history_size = cmdx.history_size;
    }
}


/* =========================== Screen Handling =========================== */

activate_screen :: (cmdx: *CmdX, screen: *Screen) {
    // Deactivate the text input of the previous active screen
    if cmdx.active_screen cmdx.active_screen.text_input.active = false;

    // Activate the new screen at the given index
    cmdx.active_screen = screen;
    cmdx.active_screen.text_input.active = true;

    // Render the next frame to report the change to the user
    update_window_name(cmdx);
    draw_next_frame(cmdx);
}

activate_screen_with_index :: (cmdx: *CmdX, index: s64) {
    cmdx_assert(cmdx.active_screen, index >= 0 && index < cmdx.screens.count, "Invalid Screen Index");
    activate_screen(cmdx, linked_list_get(*cmdx.screens, index));
}

activate_next_screen :: (cmdx: *CmdX) {
    activate_screen_with_index(cmdx, (cmdx.active_screen.index + 1) % cmdx.screens.count);
}

adjust_screen_rectangles :: (cmdx: *CmdX) {
    // Adjust the position and size of all screens
    screen_width:     s32 = cmdx.window.width / cmdx.screens.count;
    screen_height:    s32 = cmdx.window.height;
    next_screen_left: s32 = 0;
    next_screen_top:  s32 = 0;

    for it := cmdx.screens.first; it != null; it = it.next {
        screen := *it.data;

        screen.rectangle[0] = next_screen_left;
        screen.rectangle[1] = next_screen_top;
        screen.rectangle[2] = screen.rectangle[0] + xx screen_width;
        screen.rectangle[3] = screen.rectangle[1] + xx screen_height;

        next_screen_left = screen.rectangle[2];
        next_screen_top  = screen.rectangle[1];

        screen.rebuild_virtual_lines = true;
    }
}

// When removing screens, the indices of screens later in the list all need to be shifted down to
// remain correct.
adjust_screen_indices :: (cmdx: *CmdX) {
    for i := 0; i < cmdx.screens.count; ++i {
        screen := linked_list_get(*cmdx.screens, i);
        screen.index = i;
    }
}



/* =========================== CmdX Handling =========================== */

draw_next_frame :: (cmdx: *CmdX) {
    cmdx.draw_frame = true;
}

one_cmdx_frame :: (cmdx: *CmdX) {
    frame_start := get_hardware_time();

    // Poll window updates
    update_window(*cmdx.window);
    check_for_config_reload(cmdx, *cmdx.config);

    if cmdx.window.moved {
        // Because sometimes windows is a little bitch, when resizing a window
        // which is partially outside of the desktop frame, things go bad and we need to re-render.
        draw_next_frame(cmdx);
    }

    if cmdx.window.resized {
        // If the window was resized, adjust the screen rectangles and render next frame to properly
        // fill the new screen area
        adjust_screen_rectangles(cmdx);
        draw_next_frame(cmdx);
    }

    if cmdx.window.key_pressed[Key_Code.F11] {
        // Toggle borderless mode
        cmdx.disabled_title_bar = !cmdx.disabled_title_bar;

        window_style := get_window_style_and_range_check_window_position_and_size(cmdx);
        set_window_style(*cmdx.window, window_style);

        // By changing the window style, the window size changes, meaning text layout changes, therefore
        // the next frame should be rendered
        adjust_screen_rectangles(cmdx);
        draw_next_frame(cmdx);
    }

    if cmdx.window.focused != cmdx.active_screen.text_input.active {
        // If the user just tabbed in or out of cmdx, render the next frame so that the cursor filling
        // state is not stale. This indicates visually to the user whether cmdx is currently focused
        // and ready for keyboard input.
        draw_next_frame(cmdx);
    }

    if cmdx.draw_ui {
        // Prepare the ui
        input: UI_Input = ---;
        input.mouse_position         = .{ xx cmdx.window.mouse_x, xx cmdx.window.mouse_y };
        input.left_button_pressed    = cmdx.window.button_pressed[Button_Code.Left];
        input.left_button_held       = cmdx.window.button_held[Button_Code.Left];
        input.mouse_active           = cmdx.window.mouse_active;
        input.text_input_events      = cmdx.window.text_input_events;
        input.text_input_event_count = cmdx.window.text_input_event_count;
        prepare_ui(*cmdx.ui, input, .{ xx cmdx.window.width, xx cmdx.window.height });

        // At this point actual UI panels can be created. For now, there is no actual UI integration
        // (since it is not really required), but maybe in the future?
    }


    // Handle keyboard input. Actual key presses can trigger shortcuts to actions, text input will go
    // straight into the text input. @Cleanup what happens if the 'A' key is a short cut? We probably
    // only want to trigger an action in that case, and not have it go into the text input...
    cmdx.active_screen.text_input.active = cmdx.window.focused; // Text input events will only be handled if the text input is actually active. This will also render the "disabled" cursor so that the user knows the input isn't active

    // Check if any actions have been triggered in the past frame
    for i := 0; i < cmdx.window.key_pressed.count; ++i {
        if cmdx.window.key_pressed[i] && execute_actions_with_trigger(cmdx, xx i) break;
    }

    // Go to the next screen if ctrl+comma was pressed.
    if cmdx.window.key_held[Key_Code.Control] && cmdx.window.key_pressed[Key_Code.Comma] {
        if cmdx.screens.count == 1 create_screen(cmdx);
        activate_next_screen(cmdx);
    }

    // Close the current screen if ctrl+0 was pressed.
    if cmdx.window.key_held[Key_Code.Control] && cmdx.window.key_pressed[Key_Code._0] && cmdx.screens.count > 1  cmdx.active_screen.marked_for_closing = true;

    // Create a new screen if ctrl+1 was pressed.
    if cmdx.window.key_held[Key_Code.Control] && cmdx.window.key_pressed[Key_Code._1] {
        screen := create_screen(cmdx);
        activate_screen(cmdx, screen);
    }

    if cmdx.window.key_held[Key_Code.Control] && cmdx.window.mouse_wheel_turns != 0 {
        cmdx.font_size += xx cmdx.window.mouse_wheel_turns;
        update_font(cmdx);
        draw_next_frame(cmdx);
    }

    // Update the mouse-hovered screen.
    cmdx.hovered_screen = cmdx.active_screen; // Should no actual screen be hovered because the mouse is outside the window, then just set it to the active screen to avoid any weird glitches
    for it := cmdx.screens.first; it != null; it = it.next {
        screen := *it.data;
        if mouse_over_rectangle(cmdx, screen.rectangle) {
            cmdx.hovered_screen = screen;
            break;
        }
    }

    // Activate a screen when it is hovered and pressed
    if cmdx.window.button_pressed[Button_Code.Left] && cmdx.hovered_screen != cmdx.active_screen {
        activate_screen(cmdx, cmdx.hovered_screen);
    }

    // Handle the actual characters written by the user into the current text input
    handled_some_text_input: bool = false;
    for i := 0; i < cmdx.window.text_input_event_count; ++i {
        event := cmdx.window.text_input_events[i];
        if event.utf32 != 0x9 {
            handle_text_input_event(*cmdx.active_screen.text_input, event); // Do not handle tab keys in the actual text input
            handled_some_text_input = true;
        }
    }

    // The text buffer was updated, update the auto complete options and render the next frame
    if handled_some_text_input {
        cmdx.active_screen.auto_complete_dirty = true;
        draw_next_frame(cmdx);
    }

    // Do one cycle of auto-complete if the tab key has been pressed.
    if cmdx.window.key_pressed[Key_Code.Tab] {
        refresh_auto_complete_options(cmdx, cmdx.active_screen);
        one_autocomplete_cycle(cmdx, cmdx.active_screen);
    }

    // Go up in the history
    if cmdx.window.key_pressed[Key_Code.Arrow_Up] {
        if cmdx.active_screen.history_index + 1 < cmdx.active_screen.history.count {
            ++cmdx.active_screen.history_index;
            set_text_input_string(*cmdx.active_screen.text_input, array_get_value(*cmdx.active_screen.history, cmdx.active_screen.history_index));
        }

        cmdx.active_screen.text_input.time_of_last_input = get_hardware_time(); // Even if there is actually no more history to go back on, still flash the cursor so that the user received some kind of feedback
        draw_next_frame(cmdx);
    }

    // Go down in the history
    if cmdx.window.key_pressed[Key_Code.Arrow_Down] {
        if cmdx.active_screen.history_index >= 1 {
            --cmdx.active_screen.history_index;
            set_text_input_string(*cmdx.active_screen.text_input, array_get_value(*cmdx.active_screen.history, cmdx.active_screen.history_index));
        } else {
            cmdx.active_screen.history_index = -1;
            set_text_input_string(*cmdx.active_screen.text_input, "");
        }

        cmdx.active_screen.text_input.time_of_last_input = get_hardware_time(); // Even if there is actually no more history to go back on, still flash the cursor so that the user received some kind of feedback
        draw_next_frame(cmdx);
    }

    // Check for potential control keys
    if cmdx.active_screen.child_process_running && cmdx.window.key_pressed[Key_Code.C] && cmdx.window.key_held[Key_Code.Control] {
        // Terminate the current running process
        win32_terminate_child_process(cmdx, cmdx.active_screen);
    }

    // Handle input for this screen
    if cmdx.active_screen.text_input.entered {
        // Since the returned value is just a string_view, and the actual text input buffer may be overwritten
        // afterwards, we need to make a copy from the input string, so that it may potentially be used later on.
        input_string := copy_string(*cmdx.frame_allocator, get_string_view_from_text_input(*cmdx.active_screen.text_input));

        // Reset the text input
        cmdx.active_screen.history_index = -1;
        clear_text_input(*cmdx.active_screen.text_input);
        activate_text_input(*cmdx.active_screen.text_input);

        if cmdx.active_screen.child_process_running {
            // Send the input to the child process
            win32_write_to_child_process(cmdx, cmdx.active_screen, input_string);
        } else if input_string.count {
            if cmdx.active_screen.history.count {
                // Only add the new input string to the history if it is not the exact same input
                // as the previous
                previous := array_get_value(*cmdx.active_screen.history, 0);
                if !compare_strings(previous, input_string) add_history(cmdx, cmdx.active_screen, input_string);
            } else add_history(cmdx, cmdx.active_screen, input_string);

            // Print the complete input line into the backlog
            set_themed_color(cmdx.active_screen, .Accent);
            add_text(cmdx, cmdx.active_screen, get_prefix_string(cmdx.active_screen, *cmdx.frame_allocator));
            set_themed_color(cmdx.active_screen, .Default);
            add_line(cmdx, cmdx.active_screen, input_string);

            // Actually launch the command
            handle_input_string(cmdx, input_string);
        }
    }

    // Update each individual screen
    for it := cmdx.screens.first; it != null; it = it.next {
        update_screen(cmdx, *it.data);
    }

    // Destroy all screens that are marked for closing. Do it before the drawing for a faster respone
    // time
    for it := cmdx.screens.first; it != null; it = it.next {
        if it.data.marked_for_closing    close_screen(cmdx, *it.data);
    }

    if cmdx.draw_frame && cmdx.window.width > 0 && cmdx.window.height > 0 {
        // Actually prepare the renderer now if we want to render this screen.
        // Also make sure that the window is not zero-sized, which can happen if the user minimizes
        // this window.
        prepare_renderer(*cmdx.renderer, cmdx.active_theme, *cmdx.font, *cmdx.window);

        // Draw all screens at their position
        for it := cmdx.screens.first; it != null; it = it.next {
            draw_screen(cmdx, *it.data);
        }

        // Render the ui on top of the actual terminal stuff
        if cmdx.draw_ui {
            draw_ui(*cmdx.ui, cmdx.window.frame_time);
            flush_font_buffer(*cmdx.renderer); // Flush all remaining ui texta
        }

        // Finish the screen
        swap_gl_buffers(*cmdx.window);

        cmdx.draw_frame = false;
    }

    // Reset the frame arena
    reset_allocator(*cmdx.frame_allocator);

    // Measure the frame time and sleep accordingly
    frame_end := get_hardware_time();
    active_frame_time: f32 = xx convert_hardware_time(frame_end - frame_start, .Milliseconds);
    requested_frame_time := 1000 / cmdx.requested_fps;
    if cmdx.requested_fps == 0 requested_frame_time = 0; // Unlimited fps

    if active_frame_time < requested_frame_time - 1 {
        time_to_sleep: s32 = xx floorf(requested_frame_time - active_frame_time) - 1;
        Sleep(time_to_sleep);
    }
}

cmdx :: () -> s32 {
    // Set up the memory management of the cmdx instance
    cmdx: CmdX;
    create_memory_arena(*cmdx.frame_memory_arena, 16 * MEGABYTES);
    create_memory_arena(*cmdx.global_memory_arena, 1 * GIGABYTES);
    create_memory_pool(*cmdx.global_memory_pool, *cmdx.global_memory_arena);
    cmdx.global_allocator = memory_pool_allocator(*cmdx.global_memory_pool);
    cmdx.frame_allocator  = memory_arena_allocator(*cmdx.frame_memory_arena);

    // Link the allocators to all important data structures
    cmdx.themes.allocator   = *cmdx.global_allocator;
    cmdx.commands.allocator = *cmdx.global_allocator;
    cmdx.screens.allocator  = *cmdx.global_allocator;

    working_directory := get_working_directory();
    defer deallocate_string(Default_Allocator, *working_directory);

    cmdx.startup_directory = copy_string(*cmdx.global_allocator, working_directory);

    // Register all commands
    register_all_commands(*cmdx);

    // Set the working directory of this program to where to executable file is, so that the data
    // folder can always be accessed.
    run_tree := get_module_path();
    defer deallocate_string(Default_Allocator, *run_tree);
    set_working_directory(run_tree);
    enable_high_resolution_time(); // Enable high resolution sleeping to keep a steady frame rate

    // Set up all the required config properties, and read the config file if it exists
    create_s64_property(*cmdx.config,    "backlog-size",         *cmdx.backlog_size);
    create_s64_property(*cmdx.config,    "history-size",         *cmdx.history_size);
    create_s64_property(*cmdx.config,    "scroll-speed",         *cmdx.scroll_speed);
    create_f32_property(*cmdx.config,    "scroll-interpolation", *cmdx.scroll_interpolation);
    create_bool_property(*cmdx.config,   "enable-line-wrapping", *cmdx.enable_line_wrapping);
    create_string_property(*cmdx.config, "theme",                *cmdx.active_theme_name);
    create_string_property(*cmdx.config, "font-name",            *cmdx.font_path);
    create_s64_property(*cmdx.config,    "font-size",            *cmdx.font_size);
    create_bool_property(*cmdx.config,   "window-borderless",    *cmdx.disabled_title_bar);
    create_s32_property(*cmdx.config,    "window-x",             *cmdx.window.xposition);
    create_s32_property(*cmdx.config,    "window-y",             *cmdx.window.yposition);
    create_u32_property(*cmdx.config,    "window-width",         *cmdx.window.width);
    create_u32_property(*cmdx.config,    "window-height",        *cmdx.window.height);
    create_bool_property(*cmdx.config,   "window-maximized",     *cmdx.window.maximized);
    create_f32_property(*cmdx.config,    "window-fps",           *cmdx.requested_fps);
    read_config_file(*cmdx, *cmdx.config, CONFIG_FILE_NAME);

    // Create the window and the renderer
    window_style := get_window_style_and_range_check_window_position_and_size(*cmdx);
    create_window(*cmdx.window, "cmdX", cmdx.window.width, cmdx.window.height, cmdx.window.xposition, cmdx.window.yposition, window_style); // The title will be replaced when the first screen gets created

    create_gl_context(*cmdx.window, 3, 3);
    create_renderer(*cmdx.renderer);
    draw_next_frame(*cmdx);

    // Now set the taskbar for the window, cause win32 sucks some ass.
    set_window_icon(*cmdx.window, "data/cmdx.ico");

    // Load the font
    update_font(*cmdx);

    // Create the builtin themes
    create_theme(*cmdx, "blue",    .{ 186, 196, 214, 255 }, .{ 248, 173,  52, 255 }, .{ 248, 173,  52, 255 }, .{  21,  33,  42, 255 }, .{ 100, 100, 100, 255 }, .{ 73, 149, 236, 255 } );
    create_theme(*cmdx, "dark",    .{ 255, 255, 255, 255 }, .{ 255, 255, 255, 255 }, .{ 248, 173,  52, 255 }, .{   0,   0,   0, 255 }, .{ 100, 100, 100, 255 }, .{ 73, 149, 236, 255 } );
    create_theme(*cmdx, "gruvbox", .{ 230, 214, 174, 255 }, .{ 230, 214, 174, 255 }, .{ 250, 189,  47, 255 }, .{  40,  40,  40, 255 }, .{ 100, 100, 100, 255 }, .{ 73, 149, 236, 255 } );
    create_theme(*cmdx, "light",   .{  10,  10,  10, 255 }, .{  30,  30,  30, 255 }, .{  51,  94, 168, 255 }, .{ 255, 255, 255, 255 }, .{ 200, 200, 200, 255 }, .{ 73, 149, 236, 255 } );
    create_theme(*cmdx, "monokai", .{ 202, 202, 202, 255 }, .{ 231, 231, 231, 255 }, .{ 141, 208,   6, 255 }, .{  39,  40,  34, 255 }, .{ 100, 100, 100, 255 }, .{ 73, 149, 236, 255 } );
    create_theme(*cmdx, "autumn",  .{ 209, 184, 151, 255 }, .{ 255, 160, 122, 255 }, .{ 255, 127,  36, 255 }, .{   6,  36,  40, 255 }, .{  19, 115, 130, 255 }, .{ 73, 149, 236, 255 } );
    update_active_theme_pointer(*cmdx, cmdx.active_theme_name);

    // Create the ui
    ui_callbacks: UI_Callbacks = .{
        *cmdx,
        ui_draw_text,
        ui_draw_quad,
        ui_set_scissors,
        ui_reset_scissors,
        ui_query_label_size,
        ui_query_character_size
    };

    ui_font_stats: UI_Font_Statistics = .{
        cmdx.font.line_height,
        cmdx.font.ascender,
        cmdx.font.descender
    };

    create_ui(*cmdx.ui, ui_callbacks, UI_Light_Theme, ui_font_stats);

    // After everything has been loaded, actually show the window. This will prevent a small time
    // frame in which the window is just blank white, which does not seem very clean. Instead, the
    // window takes a little longer to show up, but it immediatly gets filled with the first frame.
    show_window(*cmdx.window);

    // Create the main screen and display the welcome message
    screen := create_screen(*cmdx);
    activate_screen(*cmdx, screen);
    welcome_screen(*cmdx, cmdx.active_screen, run_tree);
    flush_config_errors(*cmdx, false);

    cmdx.setup = true;

    // Main loop until the window gets closed
    while !cmdx.window.should_close    one_cmdx_frame(*cmdx);

    // Cleanup
    write_config_file(*cmdx.config, CONFIG_FILE_NAME);
    destroy_ui(*cmdx.ui);
    destroy_renderer(*cmdx.renderer);
    destroy_gl_context(*cmdx.window);
    destroy_window(*cmdx.window);

    // Release all memory.
    destroy_memory_pool(*cmdx.global_memory_pool);
    destroy_memory_arena(*cmdx.global_memory_arena);
    destroy_memory_arena(*cmdx.frame_memory_arena);

    return 0;
}


main :: () -> s32 {
    return cmdx();
}

WinMain :: () -> s32 {
    return cmdx();
}

/*
  The command to compile this program is:
  prometheus src/cmdx.p -o:run_tree/cmdx.exe -subsystem:windows -l:run_tree/.res -run
*/

// @Incomplete: Store history in a file to restore it after program restart
// @Incomplete: Put all these screen hotkeys into the config file somehow (create, close, next screen...)

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
#load "hash_table.p";
#load "math/v2f.p";
#load "math/v3f.p";
#load "math/v4f.p";
#load "math/m4f.p";
#load "math/quatf.p";
#load "math/linear.p";
#load "random.p";

// --- Local files
#load "config.p";
#load "draw.p";
#load "commands.p";
#load "command_handlers.p";
#load "win32.p";

CASCADIO_MONO   :: "C:/windows/fonts/cascadiamono.ttf";
TIMES_NEW_ROMAN :: "C:/windows/fonts/times.ttf";
COURIER_NEW     :: "C:/windows/fonts/cour.ttf";
ARIAL           :: "C:/windows/fonts/arial.ttf";
DEFAULT_FONT    :: COURIER_NEW;

REQUESTED_FPS: f32 : 60;
REQUESTED_FRAME_TIME_MILLISECONDS: f32 : 1000 / REQUESTED_FPS;

CONFIG_FILE_NAME :: ".cmdx-config";

BACKLOG_SIZE :: 65536;
HISTORY_SIZE :: 64;
SCROLL_SPEED :: 3; // In amount of lines per mouse wheel turn

Color_Index :: enum {
    Default;
    Cursor;
    Accent;
    Background;
}

Theme :: struct {
    name: string;
    colors: [Color_Index.count]Color;
}

Source_Range :: struct {
    first: s64; // The index containing the first character of this range in the backlog
    one_plus_last: s64; // One character past the last of this range in the backlog
    wrapped: bool;
}

Color_Range :: struct {
    source: Source_Range;
    color_index: Color_Index; // If this is a valid value (not -1), then the color from the active theme gets used
    true_color: Color; // An actual rgb value specified by the child process. Used if the color index invalid.
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
    render_frame: bool; // When nothing has changed on screen, then there is no need to re-render everything. Save GPU power by not rendering this frame, and instead just reuse the current backbuffer.
    
    // Text Input
    text_input: Text_Input;
    history: [..]string;
    history_index: s32 = -1; // -1 means no history is used
    
    // Backlog
    backlog: *s8 = ---;
    colors: [..]Color_Range;
    lines: [..]Source_Range;
    scroll_offset: s64; // The index for the first line to be rendered at the top of the screen
    viewport_height: s64; // The amount of lines put into the backlog since the last command has been entered. Used for cursor positioning
    
    // Command handling
    commands: [..]Command;
    current_directory: string;
    child_process_name: string;
    child_process_running: bool;
    
    // Styling
    font_size: s64;
    font_path: string;
    font: Font;

    active_theme_name: string;
    active_theme: *Theme;
    themes: [..]Theme;

    config: Config;
    
    // Platform data
    win32: Win32 = ---;
}

/* --- DEBUGGING --- */

debug_print_lines :: (cmdx: *CmdX, location: string) {
    print("=== LINES (%) ===\n", location);

    for i := 0; i < cmdx.lines.count; ++i {
        line := array_get(*cmdx.lines, i);
        print("I %: % -> % ", i, line.first, line.one_plus_last);
        if line.wrapped print("     '%*%' (wrapped)", string_view(*cmdx.backlog[line.first], BACKLOG_SIZE - line.first), string_view(*cmdx.backlog[0], line.one_plus_last)); 
        else print("     '%'", string_view(*cmdx.backlog[line.first], line.one_plus_last - line.first));
        print("\n");
    }

    print("=== LINES (%) ===\n", location);
}

debug_print_colors :: (cmdx: *CmdX, location: string) {
    print("=== COLORS (%) ===\n", location);

    for i := 0; i < cmdx.colors.count; ++i {
        range := array_get(*cmdx.colors, i);
        print("C %: % -> % (% | %, %, %)", i, range.source.first, range.source.one_plus_last, cast(s32) range.color_index, range.true_color.r, range.true_color.g, range.true_color.b);
        if range.source.wrapped print(" (wrapped)");
        print("\n");
    }

    print("=== COLORS (%) ===\n", location);
}

debug_print_history :: (cmdx: *CmdX, location: string) {
    print("=== HISTORY (%) ===\n", location);

    for i := 0; i < cmdx.history.count; ++i {
        string := array_get_value(*cmdx.history, i);
        print("H %: '%'\n", i, string);
    }
    
    print("=== HISTORY (%) ===\n", location);
}


random_line :: (cmdx: *CmdX) {
    color: Color = ---;
    color.r = get_random_integer() % 255;
    color.g = get_random_integer() % 255;
    color.b = get_random_integer() % 255;
    color.a = 255;

    set_true_color(cmdx, color);
    add_line(cmdx, "Hello World, these are 40 Characters.!!!");
}



/* --- Source Range --- */

// Returns true if both ranges share at least one character in the backlog
source_ranges_overlap :: (lhs: Source_Range, rhs: Source_Range) -> bool {
    overlap := false;

    if lhs.wrapped && rhs.wrapped {
        overlap = true;
    } else if lhs.wrapped {
        overlap = lhs.first <= rhs.one_plus_last || lhs.one_plus_last > rhs.first;
    } else if rhs.wrapped {
        overlap = lhs.first <= rhs.one_plus_last || lhs.one_plus_last > rhs.first;
    } else {
        overlap = lhs.first <= rhs.one_plus_last && lhs.one_plus_last > rhs.first;
    }

    return overlap;
}

// Returns true if lhs is completely enclosed by rhs, meaning that there is no character
// in lhs that is not also owned by rhs.
source_range_enclosed :: (lhs: Source_Range, rhs: Source_Range) -> bool {
    enclosed := false;
    
    if lhs.wrapped && rhs.wrapped {
        enclosed = lhs.first >= rhs.first && lhs.one_plus_last <= rhs.one_plus_last;
    } else if lhs.wrapped {
        enclosed = rhs.first == 0 && rhs.one_plus_last == BACKLOG_SIZE - 1; // TODO: Is -1 correct?
    } else if rhs.wrapped {
        // If rhs is wrapped and lhs isn't, then lhs needs to be completely enclosed inside
        // of [0,rhs.one_plus_last]. It should also detect the edge case where lhs is an
        // empty range just at the edge of rhs.one_plus_last (not enclosed).
        // |--->       -->|
        // | ->           |
        enclosed = lhs.first < rhs.one_plus_last && lhs.one_plus_last <= rhs.one_plus_last;
    } else {
        enclosed = lhs.first >= rhs.first && lhs.first < rhs.one_plus_last && lhs.one_plus_last > rhs.first && lhs.one_plus_last <= rhs.one_plus_last;
    }

    return enclosed;
}

// Returns true if the cursor has "passed" the source range, used for determining whether
// a color range should be skipped.
cursor_after_range :: (cursor: s64, wrapped_before: bool, range: Source_Range) -> bool {
    if !range.wrapped && cursor > range.first && cursor >= range.one_plus_last return true;
    if !range.wrapped && wrapped_before && cursor < range.first return true;
    if range.wrapped && wrapped_before && cursor >= range.one_plus_last return true;
    return false;
}

// When lines gets removed from the backlog due to lack of space, all color ranges that only
// operated on the now-removed space should also be removed (since they are useless and actually
// wrong now). If a color range partly covered the removed space, but also covers other space,
// that color range should be adapted to not cover the removed space.
remove_overlapping_color_ranges :: (cmdx: *CmdX, line_range: Source_Range) -> *Color_Range {
    while cmdx.colors.count - 1 {
        color_range := array_get(*cmdx.colors, 0);

        if source_range_enclosed(color_range.source, line_range) {
            // Color range is not used in any remaining line, so it should be removed. This should only
            // happen if it is not the last color range in the list, since the backlog always requires
            // at least one color for rendering.
            array_remove(*cmdx.colors, 0);
        } else if source_ranges_overlap(color_range.source, line_range) {
            // Remove the removed space from the color range
            color_range.source.wrapped = color_range.source.one_plus_last < line_range.one_plus_last;
            color_range.source.first   = line_range.one_plus_last;
            break;
        } else break;
    }
    
    return array_get(*cmdx.colors, cmdx.colors.count - 1);
}

// When new text gets added to the backlog but there is more space for it, we need to remove
// the oldest line in the backlog, to make space for the new text. Remove as many lines as needed
// so that the new text has enough space in it. After removing the necessary lines, also remove
// any color ranges that lived in the now freed-up space.
remove_overlapping_lines :: (cmdx: *CmdX, new_line: Source_Range) -> *Source_Range {
    total_removed_range: Source_Range;
    total_removed_range.first = -1;
    
    while cmdx.lines.count - 1 {
        existing_line := array_get_value(*cmdx.lines, 0);
        
        if source_ranges_overlap(existing_line, new_line) {
            if total_removed_range.first == -1    total_removed_range.first = existing_line.first;
            total_removed_range.one_plus_last = existing_line.one_plus_last;
            total_removed_range.wrapped       = existing_line.wrapped;
            array_remove(*cmdx.lines, 0);
            continue;
        }
            
        break;
    }

    if total_removed_range.first != -1    remove_overlapping_color_ranges(cmdx, total_removed_range);
    
    return array_get(*cmdx.lines, cmdx.lines.count - 1);
}


/* --- Backlog API --- */

render_next_frame :: (cmdx: *CmdX) {
    cmdx.render_frame = true;
}

get_cursor_position_in_line :: (cmdx: *CmdX) -> s64 {
    line_head := array_get(*cmdx.lines, cmdx.lines.count - 1);
    return line_head.one_plus_last - line_head.first; // The current cursor position is considered to be at the end of the current line
}

set_cursor_position_in_line :: (cmdx: *CmdX, x: s64) {
    // Remove part of the backlog line
    line_head := array_get(*cmdx.lines, cmdx.lines.count - 1);
    line_head.one_plus_last = line_head.first + x;
    
    // If part of the backlog just got erased, the end of the color range must be updated too.
    color_head := array_get(*cmdx.colors, cmdx.colors.count - 1);
    color_head.source.one_plus_last = line_head.first + x;
}

set_cursor_position_to_beginning_of_line :: (cmdx: *CmdX) {
    set_cursor_position_in_line(cmdx, 0);
}


prepare_viewport :: (cmdx: *CmdX) {
    cmdx.viewport_height = 0;
}

close_viewport :: (cmdx: *CmdX) {
    new_line(cmdx); // When the last command finishes, append another new line for more reading clarity
}


clear_backlog :: (cmdx: *CmdX) {
    array_clear(*cmdx.lines);
    array_clear(*cmdx.colors);
    new_line(cmdx);
    set_themed_color(cmdx, .Default);
}

new_line :: (cmdx: *CmdX) {
    // Add a new line to the backlog
    new_line_head := array_push(*cmdx.lines);
    
    if cmdx.lines.count > 1 {
        // If there was a previous line, set the start of the new line in the backlog buffer to point 
        // just after the previous line, but only if that previous line does not end on the actual
        // backlog end, which would lead to unfortunate behaviour later on.
        old_line_head := array_get(*cmdx.lines, cmdx.lines.count - 2);
        new_line_head.first = old_line_head.one_plus_last;
        new_line_head.one_plus_last = new_line_head.first;
    }
    
    ++cmdx.viewport_height;
    cmdx.scroll_offset = cmdx.lines.count; // Snap the view back to the bottom. Maybe in the future, we only do this if we are close the the bottom anyway?

    render_next_frame(cmdx);
}

add_text :: (cmdx: *CmdX, text: string) {
    line_head := array_get(*cmdx.lines, cmdx.lines.count - 1);
    
    if line_head.one_plus_last + text.count >= BACKLOG_SIZE {
        // The remaining backlog space is not enough to fit the complete text in it. The line needs to be
        // wrapped around the backlog and restart at the beginning of the backlog ring buffer.
        // The first part is the split of the text that still fits in the end of the backbuffer, then second
        // part gets wrapped around to the beginning.
        first_part_length := BACKLOG_SIZE - line_head.one_plus_last;
        second_part_length := min(text.count - first_part_length, BACKLOG_SIZE - first_part_length); // If the line is too long to fit into the actual backlog (which in practice should never really happen...), then just cut the line off

        second_source_range := Source_Range.{ 0, second_part_length, false };
        line_head = remove_overlapping_lines(cmdx, second_source_range);

        copy_memory(xx *cmdx.backlog[line_head.one_plus_last], xx *text.data[0], first_part_length);
        copy_memory(xx *cmdx.backlog[0], xx *text.data[first_part_length], second_part_length);

        line_head.wrapped = true;
        line_head.one_plus_last = second_part_length;

        // The active color range also needs to be wrapped around the backlog.
        color_head := array_get(*cmdx.colors, cmdx.colors.count - 1);
        if color_head.source.wrapped color_head.source.first = line_head.first; // Not totally sure if this line here is actually necessary... Need to test it.
        color_head.source.one_plus_last = second_part_length;
        color_head.source.wrapped = true;
    } else {
        // If the line still fits into the backlog, just append it to the current head.
        new_source_range := Source_Range.{ line_head.one_plus_last, line_head.one_plus_last + text.count, false };
        line_head = remove_overlapping_lines(cmdx, new_source_range);

        copy_memory(xx *cmdx.backlog[line_head.one_plus_last], xx text.data, text.count);
        line_head.one_plus_last += text.count;
        
        color_head := array_get(*cmdx.colors, cmdx.colors.count - 1);
        color_head.source.one_plus_last += text.count;
    }

    render_next_frame(cmdx);
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


set_color_internal :: (cmdx: *CmdX, true_color: Color, color_index: Color_Index) {
    if cmdx.colors.count {
        color_head := array_get(*cmdx.colors, cmdx.colors.count - 1);

        if color_head.source.first == color_head.source.one_plus_last && !color_head.source.wrapped {
            // If the previous color was not actually used in any source range, then just overwrite that
            // entry with the new data to save space.
            color_head.color_index = color_index;
            color_head.true_color  = true_color;
        } else if color_head.color_index != color_index || !compare_colors(color_head.true_color, true_color) {
            // If this newly set color is different than the previous color (which is getting used), append
            // a new color range to the list
            range: Color_Range = .{ .{ color_head.source.one_plus_last, color_head.source.one_plus_last, false }, color_index, true_color };
            array_add(*cmdx.colors, range);
        }
    } else {
        // If this is the first color to be set, it obviously starts at the beginning of the backlog
        range: Color_Range = .{ .{}, color_index, true_color };
        array_add(*cmdx.colors, range);
    }
}

set_true_color :: (cmdx: *CmdX, color: Color) {
    set_color_internal(cmdx, color, -1);
}

set_themed_color :: (cmdx: *CmdX, index: Color_Index) {
    empty_color: Color;
    set_color_internal(cmdx, empty_color, index);
}


/* --- DRAWING --- */

activate_color_range :: (cmdx: *CmdX, color_range: *Color_Range) {
    if color_range.color_index != -1 set_foreground_color(*cmdx.renderer, cmdx.active_theme.colors[color_range.color_index]);
    else set_foreground_color(*cmdx.renderer, color_range.true_color);
}

draw_backlog_line :: (cmdx: *CmdX, start: s64, end: s64, color_range_index: *s64, color_range: *Color_Range, cursor_x: s64, cursor_y: s64, wrapped_before: bool) -> s64, s64 {   
    for cursor := start; cursor < end; ++cursor {
        character := cmdx.backlog[cursor];
        
        while cursor_after_range(cursor, wrapped_before, color_range.source) && ~color_range_index + 1 < cmdx.colors.count {
            // Increase the current color range
            ~color_range_index += 1;
            ~color_range = array_get_value(*cmdx.colors, ~color_range_index);

            // Set the actual foreground color. If the color range has a 
            activate_color_range(cmdx, color_range);
        }
        
        render_single_character_with_font(*cmdx.font, character, cursor_x, cursor_y, xx draw_single_glyph, xx *cmdx.renderer);
        if cursor + 1 < end     cursor_x += query_glyph_kerned_horizontal_advance(*cmdx.font, character, cmdx.backlog[cursor + 1]);
    }

    return cursor_x, cursor_y;
}

add_history :: (cmdx: *CmdX, input_string: string) {
    // Make space for the new input string if that is required
    if cmdx.history.count == HISTORY_SIZE {
        head := array_get_value(*cmdx.history, cmdx.history.count - 1);
        free_string(head, *cmdx.global_allocator);
        array_remove(*cmdx.history, cmdx.history.count - 1);
    }

    // Since the input_string is just a string_view over the text input's buffer,
    // we need to copy it here.
    array_add_at(*cmdx.history, 0, copy_string(input_string, *cmdx.global_allocator));
}

one_cmdx_frame :: (cmdx: *CmdX) {
    frame_start := get_hardware_time();
    
    // Poll window updates
    update_window(*cmdx.window);
    if cmdx.window.resized render_next_frame(cmdx);

    if cmdx.window.focused && !cmdx.text_input.active render_next_frame(cmdx);
    cmdx.text_input.active = cmdx.window.focused; // Text input events will only be handled if the text input is actually active. This will also render the "disabled" cursor so that the user knows the input isn't active
    
    // Update the terminal input
    for i := 0; i < cmdx.window.text_input_event_count; ++i   handle_text_input_event(*cmdx.text_input, cmdx.window.text_input_events[i]);

    if cmdx.window.text_input_event_count render_next_frame(cmdx);
    
    // Go through the history if the arrow keys have been used
    if cmdx.window.key_pressed[Key_Code.Arrow_Up] {
        if cmdx.history_index + 1 < cmdx.history.count {
            ++cmdx.history_index;
            set_text_input_string(*cmdx.text_input, array_get_value(*cmdx.history, cmdx.history_index));
        }

        cmdx.text_input.time_of_last_input = get_hardware_time(); // Even if there is actually no more history to go back on, still flash the cursor so that the user received some kind of feedback
        render_next_frame(cmdx);
    }

    if cmdx.window.key_pressed[Key_Code.Arrow_Down] {
        if cmdx.history_index >= 1 {
            --cmdx.history_index;
            set_text_input_string(*cmdx.text_input, array_get_value(*cmdx.history, cmdx.history_index));
        } else {
            cmdx.history_index = -1;
            set_text_input_string(*cmdx.text_input, ""); 
        }
                                  
        cmdx.text_input.time_of_last_input = get_hardware_time(); // Even if there is actually no more history to go back on, still flash the cursor so that the user received some kind of feedback
        render_next_frame(cmdx);
    }

    // Update the internal text input rendering state
    text_until_cursor := get_string_view_until_cursor_from_text_input(*cmdx.text_input);
    text_until_cursor_width, text_until_cursor_height := query_text_size(*cmdx.font, text_until_cursor);
    cursor_alpha_previous := cmdx.text_input.cursor_alpha;
    set_text_input_target_position(*cmdx.text_input, xx text_until_cursor_width);
    update_text_input_rendering_data(*cmdx.text_input);
    if cursor_alpha_previous != cmdx.text_input.cursor_alpha render_next_frame(cmdx); // If the cursor changed it's blinking state, then we need to render the next frame for a smooth user experience. The cursor does not change if no input happened for a few seconds.
   
    // Check for potential control keys
    if cmdx.child_process_running && cmdx.window.key_pressed[Key_Code.C] && cmdx.window.key_held[Key_Code.Control] {
        // Terminate the current running process
        win32_terminate_child_process(cmdx);
    }
    
    // Handle input for this frame
    if cmdx.text_input.entered {
        // Since the returned value is just a string_view, and the actual text input buffer may be overwritten
        // afterwards, we need to make a copy from the input string, so that it may potentially be used later on.
        input_string := copy_string(get_string_view_from_text_input(*cmdx.text_input), *cmdx.frame_allocator);

        // Reset the text input
        cmdx.history_index = -1;
        clear_text_input(*cmdx.text_input);
        activate_text_input(*cmdx.text_input);
        print("Cleared text input.\n");
        
        if cmdx.child_process_running {
            // Send the input to the child process
            win32_write_to_child_process(cmdx, input_string);
        } else if input_string.count {
            if cmdx.history.count {
                // Only add the new input string to the history if it is not the exact same input
                // as the previous
                previous := array_get_value(*cmdx.history, 0);
                if !compare_strings(previous, input_string) add_history(cmdx, input_string);
            } else add_history(cmdx, input_string);
            
            // Print the complete input line into the backlog
            set_themed_color(cmdx, .Accent);
            add_text(cmdx, get_prefix_string(cmdx, *cmdx.frame_memory_arena));
            set_themed_color(cmdx, .Default);
            add_line(cmdx, input_string);

            // Actually launch the command
            handle_input_string(cmdx, input_string);
        }
    }
    
    // The amount of visible lines on screen this frame
    visible_line_count: s32 = cast(s32) ceilf(cast(f32) cmdx.window.height / cast(f32) cmdx.font.line_height);
    if cmdx.scroll_offset < visible_line_count - 1   visible_line_count = cmdx.window.height / cmdx.font.line_height; // If we have scrolled to the top of the backlog, then we want all lines to be fully visible, not only partially. Therefore, forget about the "ceilf", instead round downwards to calculate the amount of lines fully visible

    // The actual amount of lines that will be rendered. If the current line head is empty, don't consider it
    // to be an actual line yet, and skip drawing it.
    drawn_line_count: s32 = min(cast(s32) cmdx.lines.count - 1, visible_line_count - 1);
    
    // Handle scrolling with the mouse wheel
    previous_scroll_offset := cmdx.scroll_offset;
    cmdx.scroll_offset = clamp(cmdx.scroll_offset - cmdx.window.mouse_wheel_turns * SCROLL_SPEED, drawn_line_count - 1, cmdx.lines.count - 1);
    if previous_scroll_offset != cmdx.scroll_offset render_next_frame(cmdx);

    if cmdx.render_frame {    
        // Set up the first line to be rendered, as well as the highest line index to be rendered
        line_index: s64 = clamp(cmdx.scroll_offset - drawn_line_count, 0, cmdx.lines.count - 1);
        max_line_index: s64 = line_index + drawn_line_count - 1;

        // Query the first line in the backlog, and the last line to be rendered
        line_tail  := array_get(*cmdx.lines, 0);
        first_line := array_get(*cmdx.lines, line_index);
        line_head  := array_get(*cmdx.lines, cmdx.lines.count - 1);
        
        // If the last line to be rendered is not empty, it means that it is not an empty line. That means that
        // the input string will be appended to the last line, so we can actually fit one more line into the screen.
        if line_head.first != line_head.one_plus_last ++max_line_index;
        
        // If the wrapped line is not currently in view, that information is still important for the color range
        // skipping, since the cursor needs to know whether it has technically wrapped before.
        wrapped_before := first_line.first < line_tail.first; 
        
        // Set up coordinates for rendering
        cursor_x: s32 = 5;
        cursor_y: s32 = cmdx.window.height - drawn_line_count * cmdx.font.line_height - 5;

        // Set up the color ranges
        color_range_index: s64 = 0;
        color_range: Color_Range = array_get_value(*cmdx.colors, color_range_index);
        activate_color_range(cmdx, *color_range);

        // Actually prepare the renderer now if we want to render this frame.
        prepare_renderer(*cmdx.renderer, cmdx.active_theme, *cmdx.font, *cmdx.window);
        
        // Draw all visible lines
        while line_index <= max_line_index {
            line := array_get(*cmdx.lines, line_index);

            if line.wrapped {
                // If this line wraps, then the line actually contains two parts. The first goes from the start
                // until the end of the backlog, the second part starts at the beginning of the backlog and goes
                // until the end of the line. It is easier for draw_backlog_split to do it like this.
                cursor_x, cursor_y = draw_backlog_line(cmdx, line.first, BACKLOG_SIZE, *color_range_index, *color_range, cursor_x, cursor_y, wrapped_before);
                wrapped_before = true; // We have now wrapped a line, which is important for deciding whether a the cursor has passed a color range
                cursor_x += query_glyph_kerned_horizontal_advance(*cmdx.font, cmdx.backlog[BACKLOG_SIZE - 1], cmdx.backlog[0]); // Since kerning cannot happen at the wrapping point automatically, we need to do that manually here.
                cursor_x, cursor_y = draw_backlog_line(cmdx, 0, line.one_plus_last, *color_range_index, *color_range, cursor_x, cursor_y, wrapped_before);
            } else
                cursor_x, cursor_y = draw_backlog_line(cmdx, line.first, line.one_plus_last, *color_range_index, *color_range, cursor_x, cursor_y, wrapped_before);
            
            if line_index + 1 < cmdx.lines.count {
                // If there is another line after this, reset the cursor position. If there isnt, then
                // leave the cursor as is so that the actual text input can be rendered at the correct position
                cursor_y += cmdx.font.line_height;
                cursor_x = 5;
            }
            
            ++line_index;
        }        

        // Render the text input at the end of the backlog
        prefix_string := get_prefix_string(cmdx, *cmdx.frame_memory_arena);
        draw_text_input(*cmdx.renderer, cmdx.active_theme, *cmdx.font, *cmdx.text_input, prefix_string, cursor_x, cursor_y);

        // Finish the frame, sleep until the next one
        swap_gl_buffers(*cmdx.window);

        cmdx.render_frame = false;
    }
        
    // Reset the frame arena
    reset_allocator(*cmdx.frame_allocator);
    
    frame_end := get_hardware_time();
    active_frame_time := convert_hardware_time(frame_end - frame_start, .Milliseconds);
    if active_frame_time < REQUESTED_FRAME_TIME_MILLISECONDS - 1 {
        time_to_sleep: f32 = REQUESTED_FRAME_TIME_MILLISECONDS - active_frame_time;
        Sleep(xx floorf(time_to_sleep) - 1);
    }
}


/* --- SETUP CODE --- */

welcome_screen :: (cmdx: *CmdX, run_tree: string) {    
    set_themed_color(cmdx, .Accent);
    add_line(cmdx, "    Welcome to cmdX.");
    set_themed_color(cmdx, .Default);
    
    add_line(cmdx, "Use the :help command as a starting point.");
    
    config_location := concatenate_strings(run_tree, CONFIG_FILE_NAME, *cmdx.frame_allocator);
    add_formatted_line(cmdx, "The config file can be found under %.", config_location);
    new_line(cmdx);
}

get_prefix_string :: (cmdx: *CmdX, arena: *Memory_Arena) -> string {
    string_builder: String_Builder = ---;
    create_string_builder(*string_builder, arena);
    if !cmdx.child_process_running    append_string(*string_builder, cmdx.current_directory);
    append_string(*string_builder, "> ");
    return finish_string_builder(*string_builder);
}

create_theme :: (cmdx: *CmdX, name: string, font_path: string, default: Color, cursor: Color, accent: Color, background: Color) -> *Theme {
    theme := array_push(*cmdx.themes);
    theme.name = name;
    theme.colors[Color_Index.Default]    = default;
    theme.colors[Color_Index.Cursor]     = cursor;
    theme.colors[Color_Index.Accent]     = accent;
    theme.colors[Color_Index.Background] = background;
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
        destroy_font(*cmdx.font, xx destroy_gl_texture_2d, null);
        create_font(*cmdx.font, cmdx.font_path, cmdx.font_size, true, create_gl_texture_2d, null);
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


/* --- MAIN --- */

cmdx :: () -> s32 {
    // Set up the memory management of the cmdx instance
    cmdx: CmdX;
    create_memory_arena(*cmdx.global_memory_arena, 1 * GIGABYTES);
    create_memory_pool(*cmdx.global_memory_pool, *cmdx.global_memory_arena);
    cmdx.global_allocator  = memory_pool_allocator(*cmdx.global_memory_pool);
    
    create_memory_arena(*cmdx.frame_memory_arena, 16 * MEGABYTES);
    cmdx.frame_allocator = memory_arena_allocator(*cmdx.frame_memory_arena);

    // Link the allocators to all important data structures
    cmdx.history.allocator  = *cmdx.global_allocator;
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
    cmdx.render_frame = true; // Render the first frame

    // Now set the taskbar for the window, cause win32 sucks some ass.
    set_window_icon(*cmdx.window, "data/cmdx.ico");

    // Create the backlog array
    cmdx.backlog = allocate(*cmdx.global_allocator, BACKLOG_SIZE);
    
    // Load the font
    create_font(*cmdx.font, DEFAULT_FONT, cmdx.font_size, true, create_gl_texture_2d, null);
    
    // Create the builtin themes
    create_theme(*cmdx, "light",   DEFAULT_FONT, .{  10,  10,  10, 255 }, .{  30,  30,  30, 255 }, .{  51,  94, 168, 255 }, .{ 255, 255, 255, 255 });
    create_theme(*cmdx, "dark",    DEFAULT_FONT, .{ 255, 255, 255, 255 }, .{ 255, 255, 255, 255 }, .{ 248, 173,  52, 255 }, .{   0,   0,   0, 255 });
    create_theme(*cmdx, "blue",    DEFAULT_FONT, .{ 186, 196, 214, 255 }, .{ 248, 173,  52, 255 }, .{ 248, 173,  52, 255 }, .{  21,  33,  42, 255 });
    create_theme(*cmdx, "monokai", DEFAULT_FONT, .{ 202, 202, 202, 255 }, .{ 231, 231, 231, 255 }, .{ 141, 208,   6, 255 }, .{  39,  40,  34, 255 });
    update_active_theme_pointer(*cmdx);
    
    // Display the welcome message
    clear_backlog(*cmdx); // Prepare the backlog by clearing it. This will create the initial line and color range
    welcome_screen(*cmdx, run_tree);
    
    // After everything has been loaded, actually show the window. This will prevent a small time 
    // frame in which the window is just blank white, which does not seem very clean. Instead, the 
    // window takes a little longer to show up, but it immediatly gets filled with the first frame.
    show_window(*cmdx.window);
        
    // Main loop until the window gets closed
    while !cmdx.window.should_close    one_cmdx_frame(*cmdx);
        
    // Cleanup
    write_config_file(*cmdx.config, CONFIG_FILE_NAME);
    destroy_renderer(*cmdx.renderer);
    destroy_gl_context(*cmdx.window);
    destroy_window(*cmdx.window);

    // Release all memory.
    free_memory_pool(*cmdx.global_memory_pool);
    free_memory_arena(*cmdx.global_memory_arena);
    free_memory_arena(*cmdx.frame_memory_arena);    

    return 0;
}

/*
Depending on the selected subsystem, one of these main procedures will be exported in the object file.
The command to compile this program is:
  prometheus src/cmdx.p -o:run_tree/cmdx.exe -subsystem:windows -l:run_tree/.res -run
*/

main :: () -> s32 {
    return cmdx();    
}

WinMain :: () -> s32 {
    return cmdx();
}

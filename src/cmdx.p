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
#load "config.p";
#load "actions.p";
#load "draw.p";
#load "commands.p";
#load "command_handlers.p";
#load "win32.p";
#load "create_big_file.p";

// --- Default font paths to remember
CASCADIO_MONO   :: "C:/windows/fonts/cascadiamono.ttf";
TIMES_NEW_ROMAN :: "C:/windows/fonts/times.ttf";
COURIER_NEW     :: "C:/windows/fonts/cour.ttf";
ARIAL           :: "C:/windows/fonts/arial.ttf";

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

CmdX_Screen :: struct {
    // Screen rectangle
    rectangle: [4]s32; // top, left, bottom, right. In window pixel space.
    
    // Text Input
    text_input: Text_Input;
    history: [..]string;
    history_index: s64 = -1; // -1 means no history is used
    history_size: s64; // Similar to the backlog_size, this gets copied from the global cmdx setting.
    
    // Auto complete
    auto_complete_options: [..]string;
    auto_complete_index := 0; // This is the next index that will be used for completion when the next tab key is pressed
    auto_complete_start := 0; // This is the first character that is part of the auto-complete. This is usually the start of the current "word"
    auto_complete_dirty := false; // This gets set whenever the auto-complete options are out of date and need to be reevaluated if the user requests auto-complete. Gets set either on text input, or when an option gets implicitely "accepted"
    
    // Backlog
    backlog: *s8 = ---;
    backlog_size: s64; // The amount of bytes allocated for this screen's backlog. CmdX has one backlog_size property which this screen will use, but that property may get reloaded and then we need to remember the previous backlog size, and it is easier to not pass around the cmdX struct everywhere.
    
    colors: [..]Color_Range;
    lines: [..]Source_Range;
    viewport_height: s64; // The amount of lines put into the backlog since the last command has been entered. Used for cursor positioning
    
    // Backlog scrolling
    scroll_target: f64; // The target scroll offset in lines but with fractional values for smoother cross-frame scrolling (e.g. when using the touchpad)
    scroll_position: f64; // The interpolated position which always grows towards the scroll target. Float to have smoother interpolation between frames
    scroll_offset: s64; // The index for the first line to be rendered at the top of the screen. This is always the scroll position rounded down
    
    // Drawing data cached for this screen
    drawn_line_count: s64;
    
    // Subprocess data
    current_directory: string;
    child_process_name: string;
    child_process_running: bool;
    
    // Platform data
    win32: Win32 = ---;
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
    render_frame: bool; // When nothing has changed on screen, then there is no need to re-render everything. Save GPU power by not rendering this frame, and instead just reuse the current backbuffer.
    render_ui: bool; // Currently no UI is actually implemented, therefore this will always be false. Keep this for now, in case we want some UI back in the future.
    ui: UI = ---;
    disabled_title_bar: bool = false; // The user can toggle the window's title bar, since not having it may look cleaner, but disables window movement.
    
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
    history_size:  s64 = 64;    // The number of history lines to keep
    backlog_size:  s64 = 65535; // The size of the backlog for each screen in bytes
    scroll_speed:  s64 = 3;     // In lines per mouse wheel turn
    requested_fps: f32 = 60;
    
    // Screens
    screens: Linked_List(CmdX_Screen);
    active_screen: *CmdX_Screen; // The pointer that is valid for the active_screen_index. Used as a shortcut to avoid an array indexing every time. Since the screens are stored as a linked list, the pointer is valid until the screen gets removed
    active_screen_index: s64 = 0; // The index of the currently active (meaning text input focused) screen.    
}

/* --- DEBUGGING --- */

debug_print_lines :: (screen: *CmdX_Screen) {
    print("=== LINES ===\n");
    
    for i := 0; i < screen.lines.count; ++i {
        line := array_get(*screen.lines, i);
        print("I %: % -> % ", i, line.first, line.one_plus_last);
        if line.wrapped print("     '%*%' (wrapped)", string_view(*screen.backlog[line.first], screen.backlog_size - line.first), string_view(*screen.backlog[0], line.one_plus_last)); 
        else print("     '%'", string_view(*screen.backlog[line.first], line.one_plus_last - line.first));
        print("\n");
    }
    
    print("=== LINES ===\n");
}

debug_print_colors :: (screen: *CmdX_Screen) {
    print("=== COLORS ===\n");
    
    for i := 0; i < screen.colors.count; ++i {
        range := array_get(*screen.colors, i);
        print("C %: % -> % (% | %, %, %)", i, range.source.first, range.source.one_plus_last, cast(s32) range.color_index, range.true_color.r, range.true_color.g, range.true_color.b);
        if range.source.wrapped print(" (wrapped)");
        print("\n");
    }
    
    print("=== COLORS ===\n");
}

debug_print_history :: (screen: *CmdX_Screen) {
    print("=== HISTORY ===\n");
    
    for i := 0; i < screen.history.count; ++i {
        string := array_get_value(*screen.history, i);
        print("H %: '%'\n", i, string);
    }
    
    print("=== HISTORY ===\n");
}

debug_print :: (screen: *CmdX_Screen) {
    debug_print_lines(screen);
    debug_print_colors(screen);
    //debug_print_history(screen);
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



/* --- Source Range --- */

source_ranges_equal :: (lhs: Source_Range, rhs: Source_Range) -> bool {
    return lhs.first == rhs.first && lhs.one_plus_last == rhs.one_plus_last && lhs.wrapped == rhs.wrapped;
}

// Returns true if both ranges share at least one character in the backlog
source_ranges_overlap :: (lhs: Source_Range, rhs: Source_Range) -> bool {
    if source_ranges_equal(lhs, rhs) return true;
    
    overlap := false;
    
    if lhs.wrapped && rhs.wrapped {
        overlap = true;
    } else if lhs.wrapped {
        overlap = rhs.one_plus_last > lhs.first || rhs.first < lhs.one_plus_last;
    } else if rhs.wrapped {
        overlap = lhs.one_plus_last > rhs.first || lhs.first < rhs.one_plus_last;
    } else {
        overlap = lhs.first <= rhs.first && lhs.one_plus_last > rhs.first ||
            rhs.first <= lhs.first && rhs.one_plus_last > lhs.first;
    }
    
    return overlap;
}

// Returns true if lhs is completely enclosed by rhs, meaning that there is no character
// in lhs that is not also owned by rhs.
source_range_enclosed :: (screen: *CmdX_Screen, lhs: Source_Range, rhs: Source_Range) -> bool {
    enclosed := false;
    
    if lhs.wrapped && rhs.wrapped {
        // If both are wrapped, then lhs must start after rhs and end before rhs.
        enclosed = lhs.first >= rhs.first && lhs.one_plus_last <= rhs.one_plus_last;
    } else if lhs.wrapped {
        // If lhs is wrapped and rhs is not, then lhs can only actually be enclosed
        // if rhs covers the complete available range.
        enclosed = rhs.first == 0 && rhs.one_plus_last == screen.backlog_size;
    } else if rhs.wrapped {
        // If rhs is wrapped and lhs isn't, then lhs needs to be completely enclosed inside
        // of [0,rhs.one_plus_last]. It should also detect the edge case where lhs is an
        // empty range just at the edge of rhs.one_plus_last (not enclosed).
        // |--->       -->|  rhs
        // | ->           |  lhs
        // |            ->|  lhs
        enclosed = (lhs.first < rhs.one_plus_last && lhs.one_plus_last <= rhs.one_plus_last) ||
        (lhs.first >= rhs.first && lhs.one_plus_last <= screen.backlog_size);
    } else {
        // If neither are wrapped, then lhs must start after and end before rhs
        enclosed = lhs.first >= rhs.first && lhs.one_plus_last <= rhs.one_plus_last;
    }
    
    return enclosed;
}

source_range_empty :: (source: Source_Range) -> bool {
    return !source.wrapped && source.first == source.one_plus_last;
}

// Returns true if the cursor has "passed" the source range, used for determining whether
// a color range should be skipped.
cursor_after_range :: (cursor: s64, wrapped_before: bool, range: Source_Range) -> bool {
    if !range.wrapped && cursor > range.first && cursor >= range.one_plus_last return true;
    if !range.wrapped && wrapped_before && cursor < range.first return true;
    if range.wrapped && wrapped_before && cursor >= range.one_plus_last return true;
    return false;
}

// When new text gets added to the backlog but there is more space for it, we need to remove
// the oldest line in the backlog, to make space for the new text. Remove as many lines as needed
// so that the new text has enough space in it. After removing the necessary lines, also remove
// any color ranges that lived in the now freed-up space.
remove_overlapping_lines_until_free :: (screen: *CmdX_Screen, new_line: Source_Range) -> *Source_Range {
    total_removed_range: Source_Range;
    total_removed_range.first = -1;

    // TODO(Victor): Since the given range does not overlap with the first line, this while-loop instantly
    // breaks out, leading to absolutely dogshit being done. Do we maybe not want to break out here, or
    // is another procedure required? Not sure if the breaking-out is required for some cases?
    
    while screen.lines.count > 1 {
        existing_line := array_get(*screen.lines, 0);
        
        if source_ranges_overlap(~existing_line, new_line) {
            // If the source ranges overlap, then the existing line must be removed to make space for the
            // new one.
            if total_removed_range.first == -1    total_removed_range.first = existing_line.first;
            total_removed_range.one_plus_last = existing_line.one_plus_last;
            total_removed_range.wrapped      |= existing_line.wrapped;
            array_remove(*screen.lines, 0);
        } else {
            // If the new line does not collide with the current source range, then there is enough space
            // made for the new line in the backlog, and we should stop removing more lines, since that
            // is unnecessary
            break;
        }
    }
    
    if total_removed_range.first != -1 {
        // When lines gets removed from the backlog due to lack of space, all color ranges that only
        // operated on the now-removed space should also be removed (since they are useless and actually
        // wrong now). If a color range partly covered the removed space, but also covers other space,
        // that color range should be adapted to not cover the removed space.
        while screen.colors.count {
            color_range := array_get(*screen.colors, 0);
            
            if screen.colors.count > 1 && (source_range_empty(color_range.source) || source_range_enclosed(screen, color_range.source, total_removed_range)) {
                // Color range is not used in any remaining line, so it should be removed. This should only
                // happen if it is not the last color range in the list, since the backlog always requires
                // at least one color for rendering.
                array_remove(*screen.colors, 0);
            } else if source_ranges_overlap(color_range.source, total_removed_range) {
                // Remove the removed space from the color range
                color_range.source.wrapped = color_range.source.one_plus_last < total_removed_range.one_plus_last;
                color_range.source.first   = total_removed_range.one_plus_last;
                break;
            } else
                break;
        }
    }
        
    return array_get(*screen.lines, screen.lines.count - 1);
}

// When the backlog gets shrunken down, all lines that used that part of the backlog that will be removed
// must be deleted. This differs from the behaviour above, since the procedure above only makes sure there
// is enough space for the new source range specified.
remove_all_overlapping_lines_and_color_ranges :: (screen: *CmdX_Screen, removal_range: Source_Range) {
    // When removing colors, dealing with wrapped removal ranges gives a bit of a headache, but that should
    // never even happen anyway, so just make sure here.
    assert(!removal_range.wrapped, "The removal range was expected to not wrap for more simplicity.");
    
    // Remove all lines that overlap with the removed part of the backlog
    line_index := 0;

    while line_index < screen.lines.count {
        existing_line := array_get(*screen.lines, line_index);

        if source_ranges_overlap(~existing_line, removal_range) {
            array_remove(*screen.lines, line_index);
        } else
            ++line_index;
    }

    // Remove all colors that are enclosed by the removed part of the backlog. If a color range only overlaps
    // with the removal range, then modify the end points of the range to be outside of the removal range.
    color_index := 0;

    while color_index < screen.colors.count {
        existing_color := array_get(*screen.colors, color_index);

        if screen.colors.count > 1 && (source_range_empty(existing_color.source) || source_range_enclosed(screen, existing_color.source, removal_range)) {
            // The color range is completely enclosed and therefore useless from now on. Remove it from the array
            array_remove(*screen.colors, color_index);
        } else if source_ranges_overlap(existing_color.source, removal_range) {
            // If the color range overlaps with the range to remove, but it is not enclosed, then that color
            // range is still partly used and cannot be removed. Instead, fit the color range around the removed
            // range.
            if existing_color.source.wrapped {
                if existing_color.source.first > removal_range.first && removal_range.one_plus_last == screen.backlog_size {
                    //  ---       ---   existing_color
                    //  | | | | | | |   backlog
                    //         ******   removal_range
                    existing_color.source.first   = 0;
                    existing_color.source.wrapped = false;
                } else if existing_color.source.first > removal_range.first && removal_range.one_plus_last < screen.backlog_size {
                    //  ---       ---   existing_color
                    //  | | | | | | |   backlog
                    //        *****     removal_range
                    existing_color.source.first = removal_range.one_plus_last;
                } else if existing_color.source.one_plus_last > removal_range.first && removal_range.first == 0 {
                    //  ---       ---   existing_color
                    //  | | | | | | |   backlog
                    //  ******          removal_range
                    existing_color.source.one_plus_last = screen.backlog_size;
                    existing_color.source.wrapped = false;
                } else if existing_color.source.one_plus_last > removal_range.first && removal_range.first > 0 {
                    //  ---       ---   existing_color
                    //  | | | | | | |   backlog
                    //    ******        removal_range
                    existing_color.source.one_plus_last = removal_range.first;
                }
            } else {
                //     -----        existing_color
                //  | | | | | | |   backlog
                //         ******   removal_range
                if existing_color.source.first < removal_range.first && existing_color.source.one_plus_last > removal_range.first
                    existing_color.source.one_plus_last = removal_range.first;


                //     -----        existing_color
                //  | | | | | | |   backlog
                //  ******          removal_range
                if existing_color.source.one_plus_last >= removal_range.one_plus_last && existing_color.source.first < removal_range.one_plus_last
                    existing_color.source.first = removal_range.one_plus_last;
            }
        } else
            ++color_index;
    }
}


/* --- Backlog API --- */

render_next_frame :: (cmdx: *CmdX) {
    cmdx.render_frame = true;
}

get_cursor_position_in_line :: (screen: *CmdX_Screen) -> s64 {
    line_head := array_get(*screen.lines, screen.lines.count - 1);
    return line_head.one_plus_last - line_head.first; // The current cursor position is considered to be at the end of the current line
}

set_cursor_position_in_line :: (screen: *CmdX_Screen, cursor: s64) {
    // Remove part of the backlog line. The color range must obviously also be adjusted
    line_head := array_get(*screen.lines, screen.lines.count - 1);
    color_head := array_get(*screen.colors, screen.colors.count - 1);
    
    assert(line_head.first + cursor < line_head.one_plus_last || line_head.wrapped, "Invalid cursor position");
    
    if line_head.first + cursor < screen.backlog_size {
        line_head.one_plus_last = line_head.first + cursor;
        line_head.wrapped = false;
        
        while !source_ranges_overlap(~line_head, color_head.source) {
            array_remove(*screen.colors, screen.colors.count - 1);
            color_head = array_get(*screen.colors, screen.colors.count - 1);
        }
        
        color_head.source.one_plus_last = line_head.one_plus_last;
        color_head.source.wrapped = color_head.source.first > color_head.source.one_plus_last;
    } else {
        line_head.one_plus_last = line_head.first + cursor - screen.backlog_size;
        color_head.source.one_plus_last = line_head.one_plus_last;
    }    
}

set_cursor_position_to_beginning_of_line :: (screen: *CmdX_Screen) {
    set_cursor_position_in_line(screen, 0);
}


prepare_viewport :: (screen: *CmdX_Screen) {
    screen.viewport_height = 0;
}

close_viewport :: (cmdx: *CmdX, screen: *CmdX_Screen) {
    new_line(cmdx, screen); // When the last command finishes, append another new line for more reading clarity
}


clear_backlog :: (cmdx: *CmdX, screen: *CmdX_Screen) {
    array_clear(*screen.lines);
    array_clear(*screen.colors);
    new_line(cmdx, screen);
    set_themed_color(screen, .Default);
}

new_line :: (cmdx: *CmdX, screen: *CmdX_Screen) {
    // Add a new line to the backlog
    new_line_head := array_push(*screen.lines);
    
    if screen.lines.count > 1 {
        // If there was a previous line, set the start of the new line in the backlog buffer to point 
        // just after the previous line, but only if that previous line does not end on the actual
        // backlog end, which would lead to unfortunate behaviour later on.
        old_line_head := array_get(*screen.lines, screen.lines.count - 2);
        
        if old_line_head.one_plus_last < screen.backlog_size {
            // The first character is inclusive. If the previous line ends on the backlog size, that would be
            // an invalid index for the first character of the next line...
            new_line_head.first = old_line_head.one_plus_last;
        } else {
            new_line_head.first = 0;
        }            
        
        new_line_head.one_plus_last = new_line_head.first;
    }
    
    ++screen.viewport_height;
    screen.scroll_target = xx screen.lines.count - 1; // Snap the view back to the bottom. Maybe in the future, we only do this if we are close the the bottom anyway?
    
    render_next_frame(cmdx);
}

add_text :: (cmdx: *CmdX, screen: *CmdX_Screen, text: string) {
    // Append text to the latest line
    current_line := array_get(*screen.lines, screen.lines.count - 1);
    
    // Edge-Case: If the current line already has wrapped, and it completely fills the backlog, then there
    // simply is no more space for this new text, therefore just ignore it.
    if current_line.wrapped && current_line.one_plus_last == current_line.first return;
    
    projected_one_plus_last := current_line.one_plus_last + text.count;
    
    if projected_one_plus_last > screen.backlog_size {
        // If the current line would overflow the backlog size, then it needs to be wrapped around
        // the backlog.
        
        // If the line has wrapped before, then the backlog may not have enough space to fit the complete
        // line. Cut off the new text at the size which can still fit into the backlog.
        available_text_space := min(screen.backlog_size, text.count);
        
        // If the current line would grow too big for the backlog, then it needs to be wrapped
        // around the start.
        before_wrap_length := screen.backlog_size - current_line.one_plus_last;
        after_wrap_length  := available_text_space - before_wrap_length;
        
        // Remove all lines that are between the end of the current line until the end of the backlog,
        // and the end of the line after that wrap-around
        to_remove_range := Source_Range.{ current_line.one_plus_last, after_wrap_length, true }; // Do not remove the current line if it is empty (and therefore one_plus_last -> one_plus_last)
        current_line = remove_overlapping_lines_until_free(screen, to_remove_range);
        
        // Copy the subtext contents into the backlog
        copy_memory(*screen.backlog[current_line.one_plus_last], *text.data[0], before_wrap_length);
        copy_memory(*screen.backlog[0], *text.data[before_wrap_length], after_wrap_length);
        
        // The current line will now wrap around
        current_line.wrapped = true;
        current_line.one_plus_last = after_wrap_length;
        
        color_head := array_get(*screen.colors, screen.colors.count - 1);
        color_head.source.wrapped       = true;
        color_head.source.one_plus_last = after_wrap_length;
        return;
    }
    
    if current_line.wrapped && projected_one_plus_last > current_line.first {
        // If the current line still does entirely fit into the backlog, but we detect it in another way
        // (it would overlap itself), then we still need to cut off the line and use the complete backlog
        // for this line
        available_text_space := current_line.first - current_line.one_plus_last;
        subtext := substring_view(text, 0, available_text_space);
        
        // Essentially remove all lines that are not the current one, since we have already figured out
        // that they cannot fit into the backlog together with this new line
        to_remove_range := Source_Range.{ current_line.one_plus_last, current_line.first + 1, false };
        current_line = remove_overlapping_lines_until_free(screen, to_remove_range);
        
        // Copy the subtext contents into the backlog
        copy_memory(*screen.backlog[current_line.one_plus_last], subtext.data, subtext.count);
        
        // Update the current line end, It now takes over the complete backlog
        current_line.one_plus_last = current_line.first;
        
        color_head := array_get(*screen.colors, screen.colors.count - 1);
        color_head.source.one_plus_last = current_line.first;        
        return;
    }
    
    first_line := array_get(*screen.lines, 0);
    if projected_one_plus_last > first_line.first {
        // If the current line would flow into the next line in the backlog (which is actually the first line
        // in the array), then that line will need to be removed.        
        to_remove_range := Source_Range.{ current_line.one_plus_last, projected_one_plus_last, false };
        current_line = remove_overlapping_lines_until_free(screen, to_remove_range);
    }
    
    // Copy the text content into the backlog
    copy_memory(*screen.backlog[current_line.one_plus_last], text.data, text.count);
    
    // The current line now has grown. Increase the source ranges
    current_line.one_plus_last = current_line.one_plus_last + text.count;
    
    color_head := array_get(*screen.colors, screen.colors.count - 1);
    color_head.source.one_plus_last = current_line.one_plus_last;
    
    render_next_frame(cmdx);
}

add_character :: (cmdx: *CmdX, screen: *CmdX_Screen, character: s8) {    
    string: string = ---;
    string.data = *character;
    string.count = 1;
    add_text(cmdx, screen, string);
}

add_formatted_text :: (cmdx: *CmdX, screen: *CmdX_Screen, format: string, args: ..any) {
    required_characters := query_required_print_buffer_size(format, ..args);
    string := allocate_string(required_characters, *cmdx.frame_allocator);
    mprint(string, format, ..args);
    add_text(cmdx, screen, string);
}

add_line :: (cmdx: *CmdX, screen: *CmdX_Screen, text: string) {
    add_text(cmdx, screen, text);
    new_line(cmdx, screen);
}

add_formatted_line :: (cmdx: *CmdX, screen: *CmdX_Screen, format: string, args: ..any) {
    add_formatted_text(cmdx, screen, format, ..args);
    new_line(cmdx, screen);
}


compare_color_range :: (existing: Color_Range, true_color: Color, color_index: Color_Index) -> bool {
    return existing.color_index == color_index && (color_index != -1 || compare_colors(existing.true_color, true_color));
}

set_color_internal :: (screen: *CmdX_Screen, true_color: Color, color_index: Color_Index) {
    if screen.colors.count {
        color_head := array_get(*screen.colors, screen.colors.count - 1);
        
        if color_head.source.first == color_head.source.one_plus_last && !color_head.source.wrapped {
            // If the previous color was not actually used in any source range, then just overwrite that
            // entry with the new data to save space.
            merged_with_previous := false;
            
            if screen.colors.count >= 2 {
                previous_color_head := array_get(*screen.colors, screen.colors.count - 2);
                if compare_color_range(~previous_color_head, true_color, color_index) {
                    previous_color_head.color_index = color_index;
                    previous_color_head.true_color  = true_color;
                    merged_with_previous = true;
                    array_remove(*screen.colors, screen.colors.count - 1); // Remove the new head, since it is useless
                }
            }
            
            if !merged_with_previous {
                // If we have not merged with the previous color, then set reuse the current head for the new color.
                color_head.color_index = color_index;
                color_head.true_color  = true_color;
            }
        } else if !compare_color_range(~color_head, true_color, color_index) {
            // If this newly set color is different than the previous color (which is getting used), append
            // a new color range to the list
            range: Color_Range = .{ .{ color_head.source.one_plus_last, color_head.source.one_plus_last, false }, color_index, true_color };
            array_add(*screen.colors, range);
        }
    } else {
        // If this is the first color to be set, it obviously starts at the beginning of the backlog
        range: Color_Range = .{ .{}, color_index, true_color };
        array_add(*screen.colors, range);
    }
}

set_true_color :: (screen: *CmdX_Screen, color: Color) {
    set_color_internal(screen, color, -1);
}

set_themed_color :: (screen: *CmdX_Screen, index: Color_Index) {
    empty_color: Color;
    set_color_internal(screen, empty_color, index);
}


/* --- DRAWING --- */

calculate_number_of_visible_lines :: (cmdx: *CmdX, scroll_offset: s64, available_lines: s64) -> s64 {
    // Always subtract one line which will be used for the input and not the backlog
    lines_fitting_on_screen := cast(s64) ceilf(cast(f32) cmdx.window.height / cast(f32) cmdx.font.line_height) - 1;
    
    if scroll_offset < lines_fitting_on_screen {
        // If the user has scrolled all the way to the top, then the very first line drawn (at the top of the
        // window) should be fully visible, and not only partially. Therefore calculate the number of lines that
        // fully fit into the screen space, by rounding the division down and not up.
        lines_fitting_on_screen = cmdx.window.height / cmdx.font.line_height - 1;
    }
    
    return min(available_lines, lines_fitting_on_screen);
}

activate_color_range :: (cmdx: *CmdX, color_range: *Color_Range) {
    if color_range.color_index != -1 set_foreground_color(*cmdx.renderer, cmdx.active_theme.colors[color_range.color_index]);
    else set_foreground_color(*cmdx.renderer, color_range.true_color);
}

draw_backlog_line :: (cmdx: *CmdX, screen: *CmdX_Screen, start: s64, end: s64, color_range_index: *s64, color_range: *Color_Range, cursor_x: s64, cursor_y: s64, wrapped_before: bool) -> s64, s64 {   
    set_background_color(*cmdx.renderer, cmdx.active_theme.colors[Color_Index.Background]);
    
    for cursor := start; cursor < end; ++cursor {
        character := screen.backlog[cursor];
        
        while cursor_after_range(cursor, wrapped_before, color_range.source) && ~color_range_index + 1 < screen.colors.count {
            // Increase the current color range
            ~color_range_index += 1;
            ~color_range = array_get_value(*screen.colors, ~color_range_index);
            
            // Set the actual foreground color. If the color range has a 
            activate_color_range(cmdx, color_range);
        }
        
        render_single_character_with_font(*cmdx.font, character, cursor_x, cursor_y, xx draw_single_glyph, xx *cmdx.renderer);
        if cursor + 1 < end     cursor_x += query_glyph_kerned_horizontal_advance(*cmdx.font, character, screen.backlog[cursor + 1]);
    }
    
    return cursor_x, cursor_y;
}

add_history :: (cmdx: *CmdX, screen: *CmdX_Screen, input_string: string) {
    // Make space for the new input string if that is required
    if screen.history.count == screen.history_size {
        head := array_get_value(*screen.history, screen.history.count - 1);
        free_string(head, *cmdx.global_allocator);
        array_remove(*screen.history, screen.history.count - 1);
    }
    
    // Since the input_string is just a string_view over the text input's buffer,
    // we need to copy it here.
    array_add_at(*screen.history, 0, copy_string(input_string, *cmdx.global_allocator));
}

refresh_auto_complete_options :: (cmdx: *CmdX, screen: *CmdX_Screen) {
    if !screen.auto_complete_dirty return;
    
    // Clear the previous auto complete options and deallocate all strings
    for i := 0; i < screen.auto_complete_options.count; ++i {
        string := array_get_value(*screen.auto_complete_options, i);
        free_string(string, *cmdx.global_allocator);
    }
    
    array_clear(*screen.auto_complete_options);
    screen.auto_complete_index = 0;
    
    // Gauge the text that should be auto-completed next
    string_until_cursor := string_view(screen.text_input.buffer, screen.text_input.cursor);    
    last_space, space_found := search_string_reverse(string_until_cursor, ' ');
    last_slash, slash_found := search_string_reverse(string_until_cursor, '/');
    
    // Update the auto-complete start index
    screen.auto_complete_start = 0;
    if space_found && last_space > screen.auto_complete_start    screen.auto_complete_start = last_space + 1;
    if slash_found && last_slash > screen.auto_complete_start    screen.auto_complete_start = last_slash + 1;
    
    if last_space + 1 == screen.text_input.cursor    return; // If the current auto-complete "word" is empty, don't bother completing anything, since it could mean anything and this is probably more annoying than useful to the user.
    
    text_to_complete := substring_view(screen.text_input.buffer, screen.auto_complete_start, screen.text_input.cursor);
    
    if screen.auto_complete_start == 0 {
        // Add all commands, but only if this could actually be a command (it is actually the first thing in
        // the input string)
        for i := 0; i < cmdx.commands.count; ++i {
            command := array_get(*cmdx.commands, i);
            if string_starts_with(command.name, text_to_complete) {
                // Since the options array also includes file names which need to be allocated and freed once
                // they are no longer needed, we also need to copy this name so that it can be freed.
                command_name_copy := copy_string(command.name, *cmdx.global_allocator);
                array_add(*screen.auto_complete_options, command_name_copy);
            }
        }
    }
    
    // Add all files in the current folder to the auto-complete.
    
    files_directory := screen.current_directory;
    directory_start := 0;
    if space_found     directory_start = last_space + 1;
    
    if slash_found && last_slash > directory_start {
        // If the user has already supplied a folder (e.g. some/path/file_), then get the files in that
        // directory, not the current one.
        files_directory = get_path_relative_to_cd(cmdx, substring_view(screen.text_input.buffer, directory_start, last_slash));
    }
    
    files := get_files_in_folder(files_directory, *cmdx.frame_allocator);
    
    for i := 0; i < files.count; ++i {
        file := array_get_value(*files, i);
        if string_starts_with(file, text_to_complete) {
            // Check if the given path is actually a folder. If so, then append a final slash
            // to it, to make it easier to just auto-complete to a path without having to type the slashes
            // themselves. @@Robustness maybe return this information along with the path in the
            // get_files_in_folder procedure?
            full_path := concatenate_strings(files_directory, "\\", *cmdx.frame_allocator);
            full_path = concatenate_strings(full_path, file, *cmdx.frame_allocator);
            
            file_name_copy: string = ---;
            if folder_exists(full_path) {
                file_name_copy = concatenate_strings(file, "/", *cmdx.global_allocator);
            } else
                file_name_copy = copy_string(file, *cmdx.global_allocator);
            
            array_add(*screen.auto_complete_options, file_name_copy);
        }
    }
    
    screen.auto_complete_dirty = false;
}

one_autocomplete_cycle :: (cmdx: *CmdX, screen: *CmdX_Screen) {
    if !cmdx.active_screen.auto_complete_options.count return;
    
    remaining_input_string := substring_view(screen.text_input.buffer, 0, screen.auto_complete_start);
    auto_completion := array_get_value(*screen.auto_complete_options, screen.auto_complete_index);
    
    full_string := concatenate_strings(remaining_input_string, auto_completion, *cmdx.frame_allocator);
    
    set_text_input_string(*screen.text_input, full_string);
    
    screen.auto_complete_index = (screen.auto_complete_index + 1) % screen.auto_complete_options.count;
    
    // If there was only one option, then we can be sure that the user wanted this one (or at least that
    // there is no other option for the user anyway). In that case, accept this option as the correct one,
    // and resume normal operation. This allows the user to quickly auto-complete paths if there is the
    // supplied information is unique enough.
    if screen.auto_complete_options.count == 1    screen.auto_complete_dirty = true;
}

draw_cmdx_screen :: (cmdx: *CmdX, screen: *CmdX_Screen) {
    // Set up the first line to be rendered, as well as the highest line index to be rendered
    current_line_index: s64 = screen.scroll_offset - screen.drawn_line_count;
    last_line_index: s64 = current_line_index + screen.drawn_line_count - 1; // The last line (inclusive!) to be drawn
    
    // Query the first line in the backlog, and the last line to be rendered
    line_tail  := array_get(*screen.lines, 0);
    first_line := array_get(*screen.lines, current_line_index);
    line_head  := array_get(*screen.lines, screen.lines.count - 1);
    
    // If the last line to be rendered is not empty, it means that it is not an empty line. That means that
    // the input string will be appended to the last line, so we can actually fit one more line into the screen.
    if line_head.first != line_head.one_plus_last ++last_line_index;
    
    // If the wrapped line is not currently in view, that information is still important for the color range
    // skipping, since the cursor needs to know whether it has technically wrapped before.
    wrapped_before := first_line.first < line_tail.first; 
    
    // Set up coordinates for rendering
    cursor_x: s32 = screen.rectangle[0] + 5;
    cursor_y: s32 = screen.rectangle[3] - screen.drawn_line_count * cmdx.font.line_height - 5;
    
    // Set up the color ranges
    color_range_index: s64 = 0;
    color_range: Color_Range = array_get_value(*screen.colors, color_range_index);
    activate_color_range(cmdx, *color_range);
    
    // Set scissors to avoid drawing into other screens' spaces.
    set_scissors(screen.rectangle[0], screen.rectangle[1], screen.rectangle[2] - screen.rectangle[0], screen.rectangle[3] - screen.rectangle[1], cmdx.window.height);
    
    // Draw all visible lines
    while current_line_index <= last_line_index {
        line := array_get(*screen.lines, current_line_index);
        
        if line.wrapped {
            // If this line wraps, then the line actually contains two parts. The first goes from the start
            // until the end of the backlog, the second part starts at the beginning of the backlog and goes
            // until the end of the line. It is easier for draw_backlog_split to do it like this.
            cursor_x, cursor_y = draw_backlog_line(cmdx, screen, line.first, screen.backlog_size, *color_range_index, *color_range, cursor_x, cursor_y, wrapped_before);
            wrapped_before = true; // We have now wrapped a line, which is important for deciding whether a the cursor has passed a color range
            cursor_x += query_glyph_kerned_horizontal_advance(*cmdx.font, screen.backlog[screen.backlog_size - 1], screen.backlog[0]); // Since kerning cannot happen at the wrapping point automatically, we need to do that manually here.
            cursor_x, cursor_y = draw_backlog_line(cmdx, screen, 0, line.one_plus_last, *color_range_index, *color_range, cursor_x, cursor_y, wrapped_before);
        } else
            cursor_x, cursor_y = draw_backlog_line(cmdx, screen, line.first, line.one_plus_last, *color_range_index, *color_range, cursor_x, cursor_y, wrapped_before);
        
        if current_line_index + 1 < screen.lines.count {
            // If there is another line after this, reset the cursor position. If there isnt, then
            // leave the cursor as is so that the actual text input can be rendered at the correct position
            cursor_y += cmdx.font.line_height;
            cursor_x = screen.rectangle[0] + 5;
        }
        
        ++current_line_index;
    }        
    
    // Render the text input at the end of the backlog
    prefix_string := get_prefix_string(screen, *cmdx.frame_memory_arena);
    draw_text_input(*cmdx.renderer, cmdx.active_theme, *cmdx.font, *screen.text_input, prefix_string, cursor_x, cursor_y);
    
    // If this is not the active screen, then overlay some darkening quad to make it easier for the user to
    // see that this is not the active one.
    if cmdx.active_screen != screen {
        deactive_color := Color.{ 0, 0, 0, 100 };
        draw_quad(*cmdx.renderer, screen.rectangle[0], screen.rectangle[1], screen.rectangle[2] - screen.rectangle[0], screen.rectangle[3] - screen.rectangle[1], deactive_color);
    }
    
    // Disable scissors after the screen has been rendered to avoid some weird artifacts. To avoid some left-over
    // text being rendered after this with invalid scissors, flush the font buffer now.
    flush_font_buffer(*cmdx.renderer);
    disable_scissors();
}

one_cmdx_frame :: (cmdx: *CmdX) {
    frame_start := get_hardware_time();
    
    // Poll window updates
    update_window(*cmdx.window);
    check_for_config_reload(cmdx, *cmdx.config);

    if cmdx.window.moved {
        // Because sometimes windows is a little bitch, when resizing a window
        // which is partially outside of the desktop frame, things go bad and we need to re-render.
        render_next_frame(cmdx);
    }
    
    if cmdx.window.resized {
        adjust_screen_rectangles(cmdx);
        render_next_frame(cmdx); // If the window got resized, render the next frame
    }

    if cmdx.window.key_pressed[Key_Code.F11] {
        cmdx.disabled_title_bar = !cmdx.disabled_title_bar;
        
        if cmdx.disabled_title_bar    set_window_style(*cmdx.window, .Hide_Title_Bar);
        else set_window_style(*cmdx.window, .Platform_Default);

        // By changing the window style, the window size changes, meaning text layout changes, therefore
        // the next frame should be rendered
        adjust_screen_rectangles(cmdx);
        render_next_frame(cmdx);
    }
    
    if cmdx.window.focused && !cmdx.active_screen.text_input.active render_next_frame(cmdx); // If the user just tabbed back into cmdx, make sure to render one frame
    
    if cmdx.render_ui {
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
    
    if cmdx.window.key_pressed[Key_Code.F1] debug_print(cmdx.active_screen);

    // Check if any actions have been triggered in the past frame
    for i := 0; i < cmdx.window.key_pressed.count; ++i {
        if cmdx.window.key_pressed[i] && execute_actions_with_trigger(cmdx, xx i) break;
    }
    
    // @Cleanup put all these screen hotkeys into the config file somehow
    // Go to the next screen if ctrl+comma was pressed.
    if cmdx.window.key_held[Key_Code.Control] && cmdx.window.key_pressed[Key_Code.Comma]  activate_next_screen(cmdx);
    
    // Close the current screen if ctrl+0 was pressed.
    if cmdx.window.key_held[Key_Code.Control] && cmdx.window.key_pressed[Key_Code._0] && cmdx.screens.count > 1  close_screen(cmdx, cmdx.active_screen);
    
    if cmdx.window.key_held[Key_Code.Control] && cmdx.window.key_pressed[Key_Code._1] create_and_activate_screen(cmdx);
    
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
        render_next_frame(cmdx);
    }
    
    // Do one cycle of auto-complete if the tab key has been pressed.
    if cmdx.window.key_pressed[Key_Code.Tab] {
        refresh_auto_complete_options(cmdx, cmdx.active_screen);
        one_autocomplete_cycle(cmdx, cmdx.active_screen);
    }
    
    // Go through the history if the arrow keys have been used
    if cmdx.window.key_pressed[Key_Code.Arrow_Up] {
        if cmdx.active_screen.history_index + 1 < cmdx.active_screen.history.count {
            ++cmdx.active_screen.history_index;
            set_text_input_string(*cmdx.active_screen.text_input, array_get_value(*cmdx.active_screen.history, cmdx.active_screen.history_index));
        }
        
        cmdx.active_screen.text_input.time_of_last_input = get_hardware_time(); // Even if there is actually no more history to go back on, still flash the cursor so that the user received some kind of feedback
        render_next_frame(cmdx);
    }
    
    if cmdx.window.key_pressed[Key_Code.Arrow_Down] {
        if cmdx.active_screen.history_index >= 1 {
            --cmdx.active_screen.history_index;
            set_text_input_string(*cmdx.active_screen.text_input, array_get_value(*cmdx.active_screen.history, cmdx.active_screen.history_index));
        } else {
            cmdx.active_screen.history_index = -1;
            set_text_input_string(*cmdx.active_screen.text_input, ""); 
        }
        
        cmdx.active_screen.text_input.time_of_last_input = get_hardware_time(); // Even if there is actually no more history to go back on, still flash the cursor so that the user received some kind of feedback
        render_next_frame(cmdx);
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
        input_string := copy_string(get_string_view_from_text_input(*cmdx.active_screen.text_input), *cmdx.frame_allocator);
        
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
            add_text(cmdx, cmdx.active_screen, get_prefix_string(cmdx.active_screen, *cmdx.frame_memory_arena));
            set_themed_color(cmdx.active_screen, .Default);
            add_line(cmdx, cmdx.active_screen, input_string);
            
            // Actually launch the command
            handle_input_string(cmdx, input_string);
        }
    }
    
    // Update each individual screen
    for it := cmdx.screens.first; it != null; it = it.next {
        screen := *it.data;
        
        // Update the currently running child process
        if screen.child_process_running && !win32_update_spawned_process(cmdx, screen) {
            // If CmdX is terminating, or if the child process has disconnected from us (either by terminating
            // itself, or by closing the pipes), then close the connectoin to it.
            win32_detach_spawned_process(cmdx, screen);
        }
        
        // Update the text input's cursor rendering data
        text_until_cursor := get_string_view_until_cursor_from_text_input(*screen.text_input);
        text_until_cursor_width, text_until_cursor_height := query_text_size(*cmdx.font, text_until_cursor);
        cursor_alpha_previous := screen.text_input.cursor_alpha;
        set_text_input_target_position(*screen.text_input, xx text_until_cursor_width);
        update_text_input_rendering_data(*screen.text_input);
        if cursor_alpha_previous != screen.text_input.cursor_alpha    render_next_frame(cmdx); // If the cursor changed it's blinking state, then we need to render the next frame for a smooth user experience. The cursor does not change if no input happened for a few seconds.
        
        // Handle scrolling in this screen
        new_scroll_target := screen.scroll_target;
        
        if cmdx.active_screen == screen || cmdx.window.key_held[Key_Code.Shift] {
            // Only actually do scrolling if this is either the active screen, or the shift key is held,
            // indicating that all screens should be scrolled simultaneously
            new_scroll_target = xx screen.scroll_target - cast(f64) cmdx.window.mouse_scroll_turns * xx cmdx.scroll_speed;
            if cmdx.window.key_pressed[Key_Code.Page_Down] new_scroll_target = xx screen.lines.count - 1; // Scroll to the bottom of the backlog.
            if cmdx.window.key_pressed[Key_Code.Page_Up]   new_scroll_target = 0; // Scroll all the way to the top of the backlog. While 0 is not actually a valid scroll target, it makes sure that it goes all the way to the top in the calculate_number_of_visible_lines procedure. The value will be clamped below.
        }
        
        previous_scroll_offset := screen.scroll_offset;
        total_line_count := screen.lines.count - 1; // Do not count the "input echo" line, which is the line head
        current_drawn_line_count := calculate_number_of_visible_lines(cmdx, cast(s64) round(new_scroll_target), total_line_count); // Estimate the number of drawn lines at the current scroll target
        
        // Calculate the number of drawn lines at the target scrolling position, so that the target can be
        // clamped with the correct values.
        screen.scroll_target    = clamp(new_scroll_target, xx current_drawn_line_count, xx total_line_count);
        screen.scroll_position += (screen.scroll_target - screen.scroll_position) * 0.25;
        screen.scroll_offset    = clamp(cast(s64) round(screen.scroll_position), current_drawn_line_count, total_line_count);
        
        screen.drawn_line_count = calculate_number_of_visible_lines(cmdx, screen.scroll_offset, total_line_count);
        
        if previous_scroll_offset != screen.scroll_offset render_next_frame(cmdx); // Since scrolling can happen without any user input (through interpolation), always render a frame if the scroll offset changed.
    }
    
    if cmdx.render_frame || cmdx.render_ui {    
        // Actually prepare the renderer now if we want to render this screen.
        prepare_renderer(*cmdx.renderer, cmdx.active_theme, *cmdx.font, *cmdx.window);

        // Draw all screens at their position
        for it := cmdx.screens.first; it != null; it = it.next {
            draw_cmdx_screen(cmdx, *it.data);
        }
        
        // Render the ui on top of the actual terminal stuff
        if cmdx.render_ui {
            draw_ui(*cmdx.ui, cmdx.window.frame_time);
            flush_font_buffer(*cmdx.renderer); // Flush all remaining ui texta
        }
        
        // Finish the screen, sleep until the next one
        swap_gl_buffers(*cmdx.window);
        
        cmdx.render_frame = false;
    }
    
    // Reset the frame arena
    reset_allocator(*cmdx.frame_allocator);
    
    // Measure the frame time and sleep accordingly
    frame_end := get_hardware_time();
    active_frame_time := convert_hardware_time(frame_end - frame_start, .Milliseconds);
    requested_frame_time := 1000 / cmdx.requested_fps;
    if cmdx.requested_fps == 0 requested_frame_time = 0; // Unlimited fps
    
    if active_frame_time < requested_frame_time - 1 {
        time_to_sleep: s32 = xx floorf(requested_frame_time - active_frame_time) - 1;
        Sleep(time_to_sleep);        
    }
}



/* --- SCREEN API --- */

create_screen :: (cmdx: *CmdX) -> s64 {
    // Actually create the new screen, set the proper allocators for arrays and so forth
    screen := linked_list_push(*cmdx.screens);
    screen.auto_complete_options.allocator = *cmdx.global_allocator;
    screen.history.allocator = *cmdx.global_allocator;
    screen.colors.allocator  = *cmdx.global_allocator;
    screen.lines.allocator   = *cmdx.global_allocator;
    screen.current_directory = copy_string(cmdx.startup_directory, *cmdx.global_allocator);
    screen.text_input.active = true;
    screen.backlog_size      = cmdx.backlog_size;
    screen.backlog           = allocate(*cmdx.global_allocator, screen.backlog_size);
    screen.history_size      = cmdx.history_size;
    
    // Set up the backlog for this screen
    clear_backlog(cmdx, screen);
    
    // Readjust the screen rectangles with the new screen
    adjust_screen_rectangles(cmdx);
    
    return cmdx.screens.count - 1;
}

create_and_activate_screen :: (cmdx: *CmdX) {
    index := create_screen(cmdx);
    activate_screen(cmdx, index);
}

close_screen :: (cmdx: *CmdX, screen: *CmdX_Screen) {
    // Deallocate all the data that was allocated for this screen when it was created
    deallocate(*cmdx.global_allocator, screen.backlog);
    free_string(screen.current_directory, *cmdx.global_allocator);
    
    // Remove the screen from the linked list
    linked_list_remove_pointer(*cmdx.screens, screen);
    
    cmdx.active_screen_index = cmdx.active_screen_index % cmdx.screens.count; // Make sure the active screen index is still in bounds
    cmdx.active_screen = linked_list_get(*cmdx.screens, cmdx.active_screen_index);
    
    // Readjust the screen rectangles of the remaining screens
    adjust_screen_rectangles(cmdx);
}

activate_screen :: (cmdx: *CmdX, index: s64) {
    assert(index >= 0 && index < cmdx.screens.count, "Invalid Screen Index");    
    
    if cmdx.active_screen cmdx.active_screen.text_input.active = false;
    
    cmdx.active_screen_index = index;
    cmdx.active_screen = linked_list_get(*cmdx.screens, index);
    
    cmdx.active_screen.text_input.active = true;
    
    update_window_name(cmdx);
    render_next_frame(cmdx);
}

activate_next_screen :: (cmdx: *CmdX) {
    activate_screen(cmdx, (cmdx.active_screen_index + 1) % cmdx.screens.count);
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
    }
}



/* --- SETUP CODE --- */

welcome_screen :: (cmdx: *CmdX, screen: *CmdX_Screen, run_tree: string) {    
    config_location := concatenate_strings(run_tree, CONFIG_FILE_NAME, *cmdx.frame_allocator);
    
    set_themed_color(screen, .Accent);
    add_line(cmdx, screen, "    Welcome to cmdX.");
    set_themed_color(screen, .Default);    
    add_line(cmdx, screen, "Use the :help command as a starting point.");    
    add_formatted_line(cmdx, screen, "The config file can be found under %.", config_location);
    new_line(cmdx, screen);    
}

get_prefix_string :: (screen: *CmdX_Screen, arena: *Memory_Arena) -> string {
    string_builder: String_Builder = ---;
    create_string_builder(*string_builder, arena);
    if !screen.child_process_running    append_string(*string_builder, screen.current_directory);
    append_string(*string_builder, "> ");
    return finish_string_builder(*string_builder);
}

create_theme :: (cmdx: *CmdX, name: string, default: Color, cursor: Color, accent: Color, background: Color) -> *Theme {
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
    
    // No theme with that name could be found. Report it back to the user.
    config_error(cmdx, "No loaded theme named '%' could be found.", cmdx.active_theme_name);
    
    if !cmdx.active_theme {
        // If there is no valid active theme pointer, revert back to the default since a theme pointer
        // is required. If there is already a theme loaded and the user tried to switch to a different
        // one, then just ignore this and leave everything as was.
        cmdx.active_theme = *cmdx.themes.data[0];
    }

    // The config system expects to be able to deallocate this eventually
    free_string(cmdx.active_theme_name, cmdx.config.allocator);
    cmdx.active_theme_name = copy_string(cmdx.active_theme.name, cmdx.config.allocator);
}

update_font :: (cmdx: *CmdX) {
    destroy_font(*cmdx.font, xx destroy_gl_texture_2d, null);
    create_font(*cmdx.font, cmdx.font_path, cmdx.font_size, true, create_gl_texture_2d, null);
}

update_active_process_name :: (cmdx: *CmdX, screen: *CmdX_Screen, process_name: string) {
    if compare_strings(screen.child_process_name, process_name) return;
    
    if screen.child_process_name.count   free_string(screen.child_process_name, *cmdx.global_allocator);
    screen.child_process_name = copy_string(process_name, *cmdx.global_allocator);
    
    update_window_name(cmdx);
}

update_window_name :: (cmdx: *CmdX) {
    builder: String_Builder = ---;
    create_string_builder(*builder, *cmdx.frame_memory_arena);
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
        clear_backlog(cmdx, screen);
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


/* --- MAIN --- */

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
    
    cmdx.startup_directory = copy_string(get_working_directory(), *cmdx.global_allocator);
    
    // Register all commands
    register_all_commands(*cmdx);
    
    // Set the working directory of this program to where to executable file is, so that the data 
    // folder can always be accessed.
    run_tree := get_module_path();
    defer free_string(run_tree, Default_Allocator);
    set_working_directory(run_tree);
    enable_high_resolution_time(); // Enable high resolution sleeping to keep a steady frame rate
    
    // Set up all the required config properties, and read the config file if it exists
    create_s64_property(*cmdx.config, "backlog-size", *cmdx.backlog_size);
    create_s64_property(*cmdx.config, "history-size", *cmdx.history_size);
    create_s64_property(*cmdx.config, "scroll-speed", *cmdx.scroll_speed);
    create_string_property(*cmdx.config, "theme", *cmdx.active_theme_name);
    create_string_property(*cmdx.config, "font-name", *cmdx.font_path);
    create_s64_property(*cmdx.config, "font-size",     *cmdx.font_size);
    create_u32_property(*cmdx.config, "window-x",      *cmdx.window.xposition);
    create_u32_property(*cmdx.config, "window-y",      *cmdx.window.yposition);
    create_u32_property(*cmdx.config, "window-width",  *cmdx.window.width);
    create_u32_property(*cmdx.config, "window-height", *cmdx.window.height);
    create_bool_property(*cmdx.config, "window-maximized", *cmdx.window.maximized);
    create_f32_property(*cmdx.config, "window-fps", *cmdx.requested_fps);
    read_config_file(*cmdx, *cmdx.config, CONFIG_FILE_NAME);
    
    // Create the window and the renderer
    create_window(*cmdx.window, "cmdX", cmdx.window.width, cmdx.window.height, cmdx.window.xposition, cmdx.window.yposition, cmdx.window.maximized, .Platform_Default); // The title will be replaced when the first screen gets created

    create_gl_context(*cmdx.window, 3, 3);
    create_renderer(*cmdx.renderer);
    render_next_frame(*cmdx);
    
    // Now set the taskbar for the window, cause win32 sucks some ass.
    set_window_icon(*cmdx.window, "data/cmdx.ico");
    
    // Load the font
    create_font(*cmdx.font, cmdx.font_path, cmdx.font_size, true, create_gl_texture_2d, null);
    
    // Create the builtin themes
    create_theme(*cmdx, "blue",    .{ 186, 196, 214, 255 }, .{ 248, 173,  52, 255 }, .{ 248, 173,  52, 255 }, .{  21,  33,  42, 255 });
    create_theme(*cmdx, "dark",    .{ 255, 255, 255, 255 }, .{ 255, 255, 255, 255 }, .{ 248, 173,  52, 255 }, .{   0,   0,   0, 255 });
    create_theme(*cmdx, "gruvbox", .{ 230, 214, 174, 255 }, .{ 230, 214, 174, 255 }, .{ 250, 189,  47, 255 }, .{  40,  40,  40, 255 });
    create_theme(*cmdx, "light",   .{  10,  10,  10, 255 }, .{  30,  30,  30, 255 }, .{  51,  94, 168, 255 }, .{ 255, 255, 255, 255 });
    create_theme(*cmdx, "monokai", .{ 202, 202, 202, 255 }, .{ 231, 231, 231, 255 }, .{ 141, 208,   6, 255 }, .{  39,  40,  34, 255 });
    update_active_theme_pointer(*cmdx);
    
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
    create_screen(*cmdx);
    activate_screen(*cmdx, 0);
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

// @Incomplete store history in a file to restore it after program restart

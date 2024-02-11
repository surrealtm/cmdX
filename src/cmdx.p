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
CASCADIO_MONO    :: "C:\\windows\\fonts\\cascadiamono.ttf";
TIMES_NEW_ROMAN  :: "C:\\windows\\fonts\\times.ttf";
COURIER_NEW      :: "C:\\windows\\fonts\\cour.ttf";
ARIAL            :: "C:\\windows\\fonts\\arial.ttf";
FIRACODE_REGULAR :: "C:\\source\\cmdX\\run_tree\\data\\FiraCode-Regular.ttf";

// --- Some visual constants
OFFSET_FROM_SCREEN_BORDER :: 5; // How many pixels to leave empty between the text and the screen border
SCROLL_BAR_WIDTH :: 10;

Color_Index :: enum {
    Default;    // The default font color
    Cursor;     // The color of the cursor
    Accent;     // The color of highlit text, e.g. input lines
    Background; // The background of the terminal backlog
    Scrollbar;  // The background of the scrollbar
}

Draw_Overlay :: enum {
    None             :: 0;
    Line_Backgrounds :: 1;
    Whitespaces      :: 2;
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

Virtual_Line :: struct {
    source: Source_Range;
}

CmdX_Screen :: struct {
    // Screen rectangle
    index: s64 = ---;
    rectangle: [4]s32; // top, left, bottom, right. In window pixel space.
    marked_for_closing: bool = false; // Since we do not want to just remove screens while still handling commands, do it after all commands have been resolved and we know nothing wants to interact with this screen anymore

    // Backlog
    backlog: *u8 = ---;
    backlog_size: s64; // The amount of bytes allocated for this screen's backlog. CmdX has one backlog_size property which this screen will use, but that property may get reloaded and then we need to remember the previous backlog size, and it is easier to not pass around the cmdX struct everywhere.
    backlog_colors: [..]Color_Range;
    backlog_lines: [..]Source_Range; // The actual lines as they are read in from the input.
    virtual_lines: [..]Virtual_Line; // The wrapped lines as they are actually rendered. Built from the backlog lines, therefore volatile.
    viewport_height: s64; // The amount of lines put into the backlog since the last command has been entered. Used for cursor positioning

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

    // Backlog scrolling information
    scroll_target_offset: f64; // The target scroll offset in virtual lines but with fractional values for smoother cross-frame scrolling (e.g. when using the touchpad)
    scroll_interpolation: f64; // The interpolated position which always grows towards the scroll target. Float to have smoother interpolation between frames
    scroll_line_offset: s64; // The index for the first virtual line to be rendered at the top of the screen. This is always the scroll position rounded down
    enable_auto_scroll: s64; // If this is set to true, the scroll target jumps to the end of the backlog whenever new input is read from the subprocess / command.
    added_text_this_frame: bool; // Auto scroll works when virtual lines are, but we build the virtual lines array every frame, so we need this for a heuristic to know the virtual lines array has changed.
    
    // Cached drawing information
    first_line_x_position: s64; // The x-position in screen-pixel-space at which the virutal lines should start
    first_line_y_position: s64; // The y-position in screen-pixel-space at which the first virtual line should be rendered
    first_line_to_draw: s64; // Index of the virtual line that goes at the very top of the screen
    last_line_to_draw: s64; // Index of the virtual last line to be rendered towards the bottom of the screen
    line_wrapped_before_first: bool; // If the virtual line which wraps around the buffer comes before the first line to be drawn, that information is required for color range skipping.

    // Scrollbar data, which needs to be in sync for the logic and drawing
    scrollbar_hitbox_rectangle: [4]s32; // Screen space rectangle which detects hovering for the scroll bar
    scrollbar_visual_rectangle: [4]s32; // Screen space rectangle which is drawn on the screen this frame
    scrollbar_hitbox_hovered: bool;
    scrollbar_visual_color: Color; // The color with which to render the visual rectangle. Changes depending on the hover state
    scrollknob_hitbox_rectangle: [4]s32; // Screen space rectangle which detects hovering for the scroll knob
    scrollknob_visual_rectangle: [4]s32; // Screen space rectangle which is drawn on the screen this frame
    scrollknob_hitbox_hovered: bool;
    scrollknob_visual_color: Color;
    
    scrollknob_dragged: bool; // Set to true once the user left-clicked and had the knob hovered in that frame. Set to false when the left button is released.
    scrollknob_drag_offset: f64; // Offset from the top of the knob to where the mouse cursor was when dragging started. This is used to position the knob relative to the mouse cursor, because we always want to position the same "pixel" of the knob under the mouse cursor

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
    draw_frame: bool; // When nothing has changed on screen, then there is no need to re-render everything. Save GPU power by not rendering this frame, and instead just reuse the current backbuffer.
    draw_ui: bool; // Currently no UI is actually implemented, therefore this will always be false. Keep this for now, in case we want some UI back in the future.
    ui: UI;
    disabled_title_bar: bool = false; // The user can toggle the window's title bar, since not having it may look cleaner, but disables window movement.
    draw_overlays: Draw_Overlay = .None;

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
    hovered_screen: *CmdX_Screen; // The screen over which the mouse currently hovers. Scrolling occurs in this screen. When the left button is pressed, this screen gets activated.
    active_screen: *CmdX_Screen; // Screen with active text input and highlighted rendering.
}

/* --- DEBUGGING --- */

debug_print_lines :: (printer: *Print_Buffer, screen: *CmdX_Screen) {
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

debug_print_colors :: (printer: *Print_Buffer, screen: *CmdX_Screen) {
    bprint(printer, "=== COLORS ===\n");

    for i := 0; i < screen.backlog_colors.count; ++i {
        range := array_get(*screen.backlog_colors, i);
        bprint(printer, "C %: % -> % (% | %, %, %)", i, range.source.first, range.source.one_plus_last, cast(s32) range.color_index, range.true_color.r, range.true_color.g, range.true_color.b);
        if range.source.wrapped bprint(printer, " (wrapped)");
        bprint(printer, "\n");
    }

    bprint(printer, "=== COLORS ===\n");
}

debug_print_history :: (printer: *Print_Buffer, screen: *CmdX_Screen) {
    bprint(printer, "=== HISTORY ===\n");

    for i := 0; i < screen.history.count; ++i {
        string := array_get_value(*screen.history, i);
        bprint(printer, "H %: '%'\n", i, string);
    }

    bprint(printer, "=== HISTORY ===\n");
}

debug_print_to_file :: (file_path: string, screen: *CmdX_Screen) {
    printer: Print_Buffer;
    create_file_printer(*printer, file_path);

    debug_print_lines(*printer, screen);
    debug_print_colors(*printer, screen);
    debug_print_history(*printer, screen);

    close_file_printer(*printer);
}

debug_print :: (screen: *CmdX_Screen) {
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


cmdx_assert :: (active_screen: *CmdX_Screen, condition: bool, text: string) {
    if condition return;

    debug_print_to_file("cmdx_log.txt", active_screen);
    assert(condition, text);
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

source_range_ends_before_other_source_range :: (lhs: Source_Range, rhs: Source_Range) -> bool {
    if !lhs.wrapped && rhs.wrapped return true;
    if lhs.wrapped && !rhs.wrapped return false;
    return lhs.one_plus_last < rhs.one_plus_last;    
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

increase_source_range :: (screen: *CmdX_Screen, range: *Source_Range) {
    ++range.one_plus_last;
    if range.one_plus_last > screen.backlog_size {
        range.one_plus_last = 0;
        range.wrapped = true;
    }
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

    while screen.backlog_lines.count > 1 {
        existing_line := array_get(*screen.backlog_lines, 0);

        if source_ranges_overlap(~existing_line, new_line) {
            // If the source ranges overlap, then the existing line must be removed to make space for the
            // new one.
            if total_removed_range.first == -1    total_removed_range.first = existing_line.first;
            total_removed_range.one_plus_last = existing_line.one_plus_last;
            total_removed_range.wrapped       = total_removed_range.one_plus_last < total_removed_range.first;
            array_remove(*screen.backlog_lines, 0);

            // Since the scroll offset is an index into the backlog, we need to adjust the scroll offset
            // whenever indices shift. The text on screen should not visually move, so disable any
            // smoothing animation by decreasing all three values.
            screen.scroll_target_offset -= 1;
            screen.scroll_interpolation -= 1;
            screen.scroll_line_offset   -= 1;
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
        while screen.backlog_colors.count {
            color_range := array_get(*screen.backlog_colors, 0);

            if screen.backlog_colors.count > 1 && (source_range_empty(color_range.source) || source_range_enclosed(screen, color_range.source, total_removed_range)) {
                // Color range is not used in any remaining line, so it should be removed. This should only
                // happen if it is not the last color range in the list, since the backlog always requires
                // at least one color for rendering.
                array_remove(*screen.backlog_colors, 0);
            } else if source_ranges_overlap(color_range.source, total_removed_range) {
                // Remove the removed space from the color range
                color_range.source.wrapped = color_range.source.one_plus_last < total_removed_range.one_plus_last;
                color_range.source.first   = total_removed_range.one_plus_last;
                break;
            } else
                break;
        }
    }

    return array_get(*screen.backlog_lines, screen.backlog_lines.count - 1);
}


/* --- Backlog API --- */

get_cursor_position_in_line :: (screen: *CmdX_Screen) -> s64 {
    cmdx_assert(screen, screen.backlog_lines.count > 0, "Screen Backlog is empty");

    line_head := array_get(*screen.backlog_lines, screen.backlog_lines.count - 1);
    return line_head.one_plus_last - line_head.first; // The current cursor position is considered to be at the end of the current line
}

set_cursor_position_in_line :: (screen: *CmdX_Screen, cursor: s64) {
    // Remove part of the backlog line. The color range must obviously also be adjusted
    line_head := array_get(*screen.backlog_lines, screen.backlog_lines.count - 1);
    color_head := array_get(*screen.backlog_colors, screen.backlog_colors.count - 1);

    cmdx_assert(screen, line_head.first + cursor < line_head.one_plus_last || line_head.wrapped, "Invalid cursor position");

    if line_head.first + cursor < screen.backlog_size {
        line_head.one_plus_last = line_head.first + cursor;
        line_head.wrapped = false;

        while !source_ranges_overlap(~line_head, color_head.source) {
            array_remove(*screen.backlog_colors, screen.backlog_colors.count - 1);
            color_head = array_get(*screen.backlog_colors, screen.backlog_colors.count - 1);
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


prepare_viewport :: (cmdx: *CmdX, screen: *CmdX_Screen) {
    screen.viewport_height = 0;
}

close_viewport :: (cmdx: *CmdX, screen: *CmdX_Screen) {
    // When closing the viewport, we want one empty line between the last text of the called process (or builtin
    // command), and the next input line. If the subprocess ended on an empty line, we only need to add one
    // empty line and we are good. If the subprocess ended on an unfinished line (which can happen if the
    // process is terminated, or if the process just has weird formatting...) we need to complete that line,
    // and then add the empty one.
    line_head := array_get(*cmdx.active_screen.backlog_lines, cmdx.active_screen.backlog_lines.count - 1);
    if line_head.first != line_head.one_plus_last new_line(cmdx, cmdx.active_screen);

    new_line(cmdx, screen);
}


clear_backlog :: (cmdx: *CmdX, screen: *CmdX_Screen) {
    array_clear(*screen.backlog_lines);
    array_clear(*screen.virtual_lines);
    array_clear(*screen.backlog_colors);
    new_line(cmdx, screen);
    set_themed_color(screen, .Default);
}

new_line :: (cmdx: *CmdX, screen: *CmdX_Screen)  {
    // Add a new line to the backlog
    new_line_head := array_push(*screen.backlog_lines);

    if screen.backlog_lines.count > 1 {
        // If there was a previous line, set the start of the new line in the backlog buffer to point
        // just after the previous line, but only if that previous line does not end on the actual
        // backlog end, which would lead to unfortunate behaviour later on.
        old_line_head := array_get(*screen.backlog_lines, screen.backlog_lines.count - 2);

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
    screen.added_text_this_frame = true;

    draw_next_frame(cmdx);
}

add_text :: (cmdx: *CmdX, screen: *CmdX_Screen, text: string) {
    // Figure out the line to which to append the text. If no line exists yet in the backlog, then
    // create a new one. If there is at least one line, only append to the existing line if it isn't
    // complete yet. If it is, then create a new line and add the text to that.
    current_line := array_get(*screen.backlog_lines, screen.backlog_lines.count - 1);

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

        color_head := array_get(*screen.backlog_colors, screen.backlog_colors.count - 1);
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

        color_head := array_get(*screen.backlog_colors, screen.backlog_colors.count - 1);
        color_head.source.one_plus_last = current_line.first;
        return;
    }

    first_line := array_get(*screen.backlog_lines, 0);
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

    color_head := array_get(*screen.backlog_colors, screen.backlog_colors.count - 1);
    color_head.source.one_plus_last = current_line.one_plus_last;
    color_head.source.wrapped = color_head.source.one_plus_last <= color_head.source.first;

    // Snap scrolling, draw the next frame
    screen.added_text_this_frame = true;
    draw_next_frame(cmdx);
}

add_character :: (cmdx: *CmdX, screen: *CmdX_Screen, character: u8) {
    string: string = ---;
    string.data = *character;
    string.count = 1;
    add_text(cmdx, screen, string);
}

add_formatted_text :: (cmdx: *CmdX, screen: *CmdX_Screen, format: string, args: ..Any) {
    required_characters := query_required_print_buffer_size(format, ..args);
    string := allocate_string(*cmdx.frame_allocator, required_characters);
    mprint(string, format, ..args);
    add_text(cmdx, screen, string);
}

add_line :: (cmdx: *CmdX, screen: *CmdX_Screen, text: string) {
    add_text(cmdx, screen, text);
    new_line(cmdx, screen);
}

add_formatted_line :: (cmdx: *CmdX, screen: *CmdX_Screen, format: string, args: ..Any) {
    add_formatted_text(cmdx, screen, format, ..args);
    new_line(cmdx, screen);
}


compare_color_range :: (existing: Color_Range, true_color: Color, color_index: Color_Index) -> bool {
    return existing.color_index == color_index && (color_index != -1 || compare_colors(existing.true_color, true_color));
}

set_color_internal :: (screen: *CmdX_Screen, true_color: Color, color_index: Color_Index) {
    if screen.backlog_colors.count {
        color_head := array_get(*screen.backlog_colors, screen.backlog_colors.count - 1);

        if color_head.source.first == color_head.source.one_plus_last && !color_head.source.wrapped {
            // If the previous color was not actually used in any source range, then just overwrite that
            // entry with the new data to save space.
            merged_with_previous := false;

            if screen.backlog_colors.count >= 2 {
                previous_color_head := array_get(*screen.backlog_colors, screen.backlog_colors.count - 2);
                if compare_color_range(~previous_color_head, true_color, color_index) {
                    previous_color_head.color_index = color_index;
                    previous_color_head.true_color  = true_color;
                    merged_with_previous = true;
                    array_remove(*screen.backlog_colors, screen.backlog_colors.count - 1); // Remove the new head, since it is useless
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
            first := color_head.source.one_plus_last;
            if first == screen.backlog_size first = 0; // one_plus_last can go one over the backlog bounds, but first cannot, so detect that edge case here
            range: Color_Range = .{ .{ first, first, false }, color_index, true_color };
            array_add(*screen.backlog_colors, range);
        }
    } else {
        // If this is the first color to be set, it obviously starts at the beginning of the backlog
        range: Color_Range = .{ .{}, color_index, true_color };
        array_add(*screen.backlog_colors, range);
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

mouse_over_rectangle :: (cmdx: *CmdX, rectangle: []s32) -> bool {
    return cmdx.window.mouse_x >= rectangle[0] && cmdx.window.mouse_x < rectangle[2] &&
        cmdx.window.mouse_y >= rectangle[1] && cmdx.window.mouse_y < rectangle[3];
}

activate_color_range :: (cmdx: *CmdX, color_range: *Color_Range) {
    if color_range.color_index != -1 set_foreground_color(*cmdx.renderer, cmdx.active_theme.colors[color_range.color_index]);
    else set_foreground_color(*cmdx.renderer, color_range.true_color);
}

draw_backlog_text :: (cmdx: *CmdX, screen: *CmdX_Screen, start: s64, end: s64, line_wrapped: bool, color_range_index: *s64, color_range: *Color_Range, cursor_x: s64, cursor_y: s64, wrapped_before: bool) -> s64, s64 {
    set_background_color(*cmdx.renderer, cmdx.active_theme.colors[Color_Index.Background]);

    for cursor := start; cursor < end; ++cursor {
        character := screen.backlog[cursor];

        while cursor_after_range(cursor, wrapped_before, color_range.source) && ~color_range_index + 1 < screen.backlog_colors.count {
            // Increase the current color range
            ~color_range_index += 1;
            ~color_range = array_get_value(*screen.backlog_colors, ~color_range_index);

            // Set the actual foreground color.
            activate_color_range(cmdx, color_range);
        }

        render_single_character_with_font(*cmdx.font, character, cursor_x, cursor_y, draw_single_glyph, *cmdx.renderer);

        if cmdx.draw_overlays & .Whitespaces && character == ' ' {
            set_background_color(*cmdx.renderer, .{ 255, 0, 255, 255 });
            render_single_character_with_font(*cmdx.font, '#', cursor_x, cursor_y, draw_single_glyph, *cmdx.renderer);
            set_background_color(*cmdx.renderer, cmdx.active_theme.colors[Color_Index.Background]);
        }

        if cursor + 1 < end {
            cursor_x += query_glyph_kerned_horizontal_advance(*cmdx.font, character, screen.backlog[cursor + 1]);
        } else if !line_wrapped {
            // If this is the very last character in the backlog to be rendered, then add the horizontal advance
            // so that the input cursor is rendered next to this character.
            // If the line is wrapped, then the caller properly handles kerning to the next character in the
            // line, so we don't have to handle that here.
            cursor_x += query_glyph_horizontal_advance(*cmdx.font, character);
        }
    }

    if end == color_range.source.one_plus_last && color_range_index + 1 < screen.backlog_colors.count {
        // There is an edge case where the color range's one_plus_last == backlog_size, and so the cursor
        // never reaches one_plus_last in the above loop, therefore the color range never gets skipped.
        // Deal with this edge case here.
        ~color_range_index += 1;
        ~color_range = array_get_value(*screen.backlog_colors, ~color_range_index);

        // Set the actual foreground color.
        activate_color_range(cmdx, color_range);
    }

    return cursor_x, cursor_y;
}

add_history :: (cmdx: *CmdX, screen: *CmdX_Screen, input_string: string) {
    // Make space for the new input string if that is required
    if screen.history.count == screen.history_size {
        head := array_get_value(*screen.history, screen.history.count - 1);
        deallocate_string(*cmdx.global_allocator, *head);
        array_remove(*screen.history, screen.history.count - 1);
    }

    // Since the input_string is just a string_view over the text input's buffer,
    // we need to copy it here.
    array_add_at(*screen.history, 0, copy_string(*cmdx.global_allocator, input_string));
}

refresh_auto_complete_options :: (cmdx: *CmdX, screen: *CmdX_Screen) {
    if !screen.auto_complete_dirty return;

    // Clear the previous auto complete options and deallocate all strings
    for i := 0; i < screen.auto_complete_options.count; ++i {
        string := array_get_value(*screen.auto_complete_options, i);
        deallocate_string(*cmdx.global_allocator, *string);
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
                command_name_copy := copy_string(*cmdx.global_allocator, command.name);
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

    files := get_files_in_folder(*cmdx.frame_allocator, files_directory, false);

    for i := 0; i < files.count; ++i {
        file := array_get_value(*files, i);
        if string_starts_with(file, text_to_complete) {
            // Check if the given path is actually a folder. If so, then append a final slash
            // to it, to make it easier to just auto-complete to a path without having to type the slashes
            // themselves. @@Robustness maybe return this information along with the path in the
            // get_files_in_folder procedure?
            full_path := concatenate_strings(*cmdx.frame_allocator, files_directory, "\\");
            full_path = concatenate_strings(*cmdx.frame_allocator, full_path, file);

            file_name_copy: string = ---;
            if folder_exists(full_path) {
                file_name_copy = concatenate_strings(*cmdx.global_allocator, file, "/");
            } else
                file_name_copy = copy_string(*cmdx.global_allocator, file);

            array_add(*screen.auto_complete_options, file_name_copy);
        }
    }

    screen.auto_complete_dirty = false;
}

one_autocomplete_cycle :: (cmdx: *CmdX, screen: *CmdX_Screen) {
    if !cmdx.active_screen.auto_complete_options.count return;

    remaining_input_string := substring_view(screen.text_input.buffer, 0, screen.auto_complete_start);
    auto_completion := array_get_value(*screen.auto_complete_options, screen.auto_complete_index);

    full_string := concatenate_strings(*cmdx.frame_allocator, remaining_input_string, auto_completion);

    set_text_input_string(*screen.text_input, full_string);

    screen.auto_complete_index = (screen.auto_complete_index + 1) % screen.auto_complete_options.count;

    // If there was only one option, then we can be sure that the user wanted this one (or at least that
    // there is no other option for the user anyway). In that case, accept this option as the correct one,
    // and resume normal operation. This allows the user to quickly auto-complete paths if there is the
    // supplied information is unique enough.
    if screen.auto_complete_options.count == 1    screen.auto_complete_dirty = true;
}

build_virtual_lines_for_screen :: (cmdx: *CmdX, screen: *CmdX_Screen) {
    active_screen_width := screen.rectangle[2] - screen.rectangle[0] - OFFSET_FROM_SCREEN_BORDER * 2;

    if screen.last_line_to_draw - screen.first_line_to_draw + 1 < screen.virtual_lines.count {
        // Scroll bar is drawn, decrease the active screen width
        active_screen_width = screen.scrollbar_visual_rectangle[0] - screen.rectangle[0] - OFFSET_FROM_SCREEN_BORDER * 2;
    }

    array_clear(*screen.virtual_lines);
    
    for i := 0; i < screen.backlog_lines.count; ++i {
        backlog_line  := array_get_value(*screen.backlog_lines, i);

        if source_range_empty(backlog_line) {
            // Empty lines should just be copied into the virtual line array.
            virtual_line := array_push(*screen.virtual_lines);
            virtual_line.source = backlog_line;
            continue;
        }
        
        virtual_range := Source_Range.{ backlog_line.first, backlog_line.first, false };
        virtual_width := 0; // The current virtual line width in pixels

        while source_range_ends_before_other_source_range(virtual_range, backlog_line) {
            next_character := screen.backlog[virtual_range.one_plus_last];
            
            while source_range_ends_before_other_source_range(virtual_range, backlog_line) && virtual_width + query_glyph_horizontal_advance(*cmdx.font, next_character) < active_screen_width {
                virtual_width += query_glyph_horizontal_advance(*cmdx.font, next_character);
                increase_source_range(screen, *virtual_range);
                next_character = screen.backlog[virtual_range.one_plus_last];
            }

            virtual_line := array_push(*screen.virtual_lines);
            virtual_line.source = virtual_range;

            virtual_width = 0;
            virtual_range = .{ virtual_range.one_plus_last, virtual_range.one_plus_last, false };
        }
    }

    if screen.enable_auto_scroll && screen.added_text_this_frame {
        // Snap the view back to the bottom.
        screen.scroll_target_offset = xx screen.virtual_lines.count;
    }

    screen.added_text_this_frame = false;
}


draw_cmdx_screen :: (cmdx: *CmdX, screen: *CmdX_Screen) {
    // Set up the cursor coordinates for rendering.
    cursor_x: s32 = screen.first_line_x_position;
    cursor_y: s32 = screen.first_line_y_position;

    // Set up the color ranges.
    wrapped_before := screen.line_wrapped_before_first;
    color_range_index: s64 = 0;
    color_range: Color_Range = array_get_value(*screen.backlog_colors, color_range_index);
    activate_color_range(cmdx, *color_range);

    // Set scissors to avoid drawing into other screens' spaces.
    set_scissors(screen.rectangle[0], screen.rectangle[1], screen.rectangle[2] - screen.rectangle[0], screen.rectangle[3] - screen.rectangle[1], cmdx.window.height);

    // Draw all visible lines
    current_line_index := screen.first_line_to_draw;
    while current_line_index <= screen.last_line_to_draw {
        line := array_get(*screen.virtual_lines, current_line_index);
        source_range := line.source;
        
        if source_range.wrapped {
            // If this line wraps, then the line actually contains two parts. The first goes from the start
            // until the end of the backlog, the second part starts at the beginning of the backlog and goes
            // until the end of the line. It is easier for draw_backlog_split to do it like this.
            cursor_x, cursor_y = draw_backlog_text(cmdx, screen, source_range.first, screen.backlog_size, true, *color_range_index, *color_range, cursor_x, cursor_y, wrapped_before);
            wrapped_before = true; // We have now wrapped a line, which is important for deciding whether a the cursor has passed a color range
            cursor_x += query_glyph_kerned_horizontal_advance(*cmdx.font, screen.backlog[screen.backlog_size - 1], screen.backlog[0]); // Since kerning cannot happen at the wrapping point automatically, we need to do that manually here.
            cursor_x, cursor_y = draw_backlog_text(cmdx, screen, 0, source_range.one_plus_last, false, *color_range_index, *color_range, cursor_x, cursor_y, wrapped_before);
        } else
            cursor_x, cursor_y = draw_backlog_text(cmdx, screen, source_range.first, source_range.one_plus_last, false, *color_range_index, *color_range, cursor_x, cursor_y, wrapped_before);

        if cmdx.draw_overlays & .Line_Backgrounds {
            draw_quad(*cmdx.renderer, screen.first_line_x_position, cursor_y - cmdx.font.line_height, cursor_x, cursor_y, .{ 255, 255, 0, 255 });
        }

        // If this is not the last line in the backlog, position the cursor on the next line.
        // If it is the last line, then the text input should be appened to this line.
        if current_line_index + 1 != screen.virtual_lines.count {
            cursor_y += cmdx.font.line_height;
            cursor_x = screen.first_line_x_position;
        }

        ++current_line_index;
    }

    // Draw the text input at the end of the backlog
    prefix_string := get_prefix_string(screen, *cmdx.frame_allocator);
    draw_text_input(*cmdx.renderer, cmdx.active_theme, *cmdx.font, *screen.text_input, prefix_string, cursor_x, cursor_y);

    // Draw the scroll bar only if the backlog is bigger than the available screen size.
    // If the scrollbar is not hovered, make it a bit thinner.
    if screen.last_line_to_draw - screen.first_line_to_draw + 1 < screen.virtual_lines.count {
        // The scrollbar background rectangle is used to detect whether the mouse is currently hovering it.
        // The visual of the background is a bit smaller to not look as distracting, but the hitbox being
        // bigger should make it easier to select.
        draw_rectangle(*cmdx.renderer, screen.scrollbar_visual_rectangle, screen.scrollbar_visual_color);
        draw_rectangle(*cmdx.renderer, screen.scrollknob_visual_rectangle, screen.scrollknob_visual_color);
    }

    // If this is not the active screen, then overlay some darkening quad to make it easier for the user to
    // see that this is not the active one.
    if cmdx.active_screen != screen {
        deactive_color := Color.{ 0, 0, 0, 100 };
        draw_quad(*cmdx.renderer, screen.rectangle[0], screen.rectangle[1], screen.rectangle[2], screen.rectangle[3], deactive_color);
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

    if cmdx.window.button_pressed[Button_Code.Left] && cmdx.hovered_screen != cmdx.active_screen {
        // Activate a screen when it is hovered and pressed
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
        screen := *it.data;

        //
        // Update the currently running child process
        //
        if screen.child_process_running && !win32_update_spawned_process(cmdx, screen) {
            // If CmdX is terminating, or if the child process has disconnected from us (either by terminating
            // itself, or by closing the pipes), then close the connectoin to it.
            win32_detach_spawned_process(cmdx, screen);
        }

        //
        // Update the virtual line list for this screen
        //
        build_virtual_lines_for_screen(cmdx, screen);

        //
        // Handle scrolling in this screen
        //

        new_scroll_target := screen.scroll_target_offset;

        if (cmdx.hovered_screen == screen || cmdx.window.key_held[Key_Code.Shift]) && !cmdx.window.key_held[Key_Code.Control] {
            // Only actually do mouse scrolling if this is either the hovered screen, or the shift key is held,
            // indicating that all screens should be scrolled simultaneously
            new_scroll_target = xx screen.scroll_target_offset - cast(f64) cmdx.window.mouse_wheel_turns * xx cmdx.scroll_speed;
        }

        if cmdx.active_screen == screen {
            // Only actually do keyboard scrolling if this is either the active screen, or the shift key is held,
            // indicating that all screens should be scrolled simultaneously
            if cmdx.window.key_pressed[Key_Code.Page_Down] new_scroll_target = xx screen.virtual_lines.count; // Scroll to the bottom of the backlog.
            if cmdx.window.key_pressed[Key_Code.Page_Up]   new_scroll_target = 0; // Scroll all the way to the top of the backlog.
        }

        previous_scroll_offset := screen.scroll_line_offset;

        // Calculate the number of lines that definitely fit on screen, so that the scroll offset can never
        // go below that number. This means that we cannot scroll past the very first line at the very top
        // of the screen. Also calculate the number of partial lines that would fit on screen, if we are fine
        // with the top-most line potentially being partly cut off at the top of the window.
        active_screen_height := (screen.rectangle[3] - screen.rectangle[1] - OFFSET_FROM_SCREEN_BORDER);
        complete_lines_fitting_on_screen: s64 = min(active_screen_height / cmdx.font.line_height, screen.virtual_lines.count);
        partial_lines_fitting_on_screen : s64 = min(cast(s64) ceil(xx active_screen_height / xx cmdx.font.line_height), screen.virtual_lines.count);
        
        // Calculate the number of drawn lines at the target scrolling position, so that the target can be
        // clamped with the correct values.
        highest_allowed_scroll_offset := screen.virtual_lines.count - complete_lines_fitting_on_screen;
        screen.scroll_target_offset    = clamp(new_scroll_target, 0, xx highest_allowed_scroll_offset);
        screen.scroll_interpolation    = clamp(damp(screen.scroll_interpolation, screen.scroll_target_offset, 10, xx cmdx.window.frame_time), 0, xx highest_allowed_scroll_offset);
        screen.scroll_line_offset      = clamp(cast(s64) round(screen.scroll_interpolation), 0, highest_allowed_scroll_offset);
        screen.enable_auto_scroll      = screen.scroll_target_offset == xx highest_allowed_scroll_offset;
                
        //
        // Set up drawing data for this frame
        //
       
        // Calculate the actual number of drawn lines at the new scrolling offset. If the user has not
        // scrolled all the way to the top, allow one line to be cut off partially.
        final_drawn_line_count: s64 = 0;
        if screen.scroll_line_offset > 0 {
            final_drawn_line_count = partial_lines_fitting_on_screen;
        } else
            final_drawn_line_count = complete_lines_fitting_on_screen;

        screen.first_line_to_draw = screen.scroll_line_offset - (final_drawn_line_count - complete_lines_fitting_on_screen);
        screen.last_line_to_draw  = screen.first_line_to_draw + final_drawn_line_count - 1;

        // If we are not completely scrolled to the bottom, then we need the last line on the screen to be
        // the input line. If we are completely scrolled to the bottom, that line is shared between the
        // backlog and the input line.
        if screen.last_line_to_draw != screen.virtual_lines.count - 1    --screen.last_line_to_draw;

        // Set the appropriate screen space coordinates for the first backlog line to be drawn.
        screen.first_line_x_position = screen.rectangle[0] + OFFSET_FROM_SCREEN_BORDER;
        screen.first_line_y_position = screen.rectangle[3] - (final_drawn_line_count - 1) * cmdx.font.line_height - OFFSET_FROM_SCREEN_BORDER; // The text drawing expects the y coordinate to be the bottom of the line, so if there is only one line to be drawn, we want this y position to be the bottom of the screen (and so on)

        // If any of the lines above the first line to be rendered already wrapped around the backlog, that
        // information needs to be stored for drawing each backlog line to properly handle color wrapping.
        first_line_in_backlog := array_get(*screen.virtual_lines, 0);
        first_line_to_draw := array_get(*screen.virtual_lines, screen.first_line_to_draw);
        screen.line_wrapped_before_first = first_line_to_draw.source.first < first_line_in_backlog.source.first;

        if previous_scroll_offset != screen.scroll_line_offset draw_next_frame(cmdx); // Since scrolling can happen without any user input (through interpolation), always render a frame if the scroll offset changed.       


        //
        // Update the scroll bar of this screen. The scroll bar is always oriented around the scroll target, not
        // the scroll position. This looks smoother when a lot of input is coming in (the knob doesn't jump
        // around), and the user also expects to control the scroll target with the knob, not the scroll posiiton.
        // For that to work, we need to manually calculate the first and last line that would be drawn if the
        // scroll target was the actual scroll position right now, since that is what the scroll bar should
        // represent.
        //

        visible_lines_in_scrollbar_area: s64 = complete_lines_fitting_on_screen;
        first_line_offset := visible_lines_in_scrollbar_area - complete_lines_fitting_on_screen;
        
        first_line_in_scrollbar_area: s64 = xx screen.scroll_target_offset - first_line_offset;
        first_line_percentage   := cast(f64) (first_line_in_scrollbar_area)    / cast(f64) screen.virtual_lines.count;
        visible_line_percentage := cast(f64) (visible_lines_in_scrollbar_area) / cast(f64) screen.virtual_lines.count;

        scrollbar_hitbox_width: s32 = SCROLL_BAR_WIDTH;
        scrollbar_hitbox_height := screen.rectangle[3] - OFFSET_FROM_SCREEN_BORDER - screen.rectangle[1] - OFFSET_FROM_SCREEN_BORDER;
        screen.scrollbar_hitbox_rectangle = { screen.rectangle[2] - scrollbar_hitbox_width - OFFSET_FROM_SCREEN_BORDER, screen.rectangle[1] + OFFSET_FROM_SCREEN_BORDER, screen.rectangle[2] - OFFSET_FROM_SCREEN_BORDER, screen.rectangle[1] + OFFSET_FROM_SCREEN_BORDER + scrollbar_hitbox_height };

        scrollknob_hitbox_offset: s64 = cast(s32) (cast(f64) scrollbar_hitbox_height * first_line_percentage);
        scrollknob_hitbox_height: s64 = cast(s32) (cast(f64) scrollbar_hitbox_height * visible_line_percentage);

        screen.scrollknob_hitbox_rectangle = { screen.scrollbar_hitbox_rectangle[0], screen.scrollbar_hitbox_rectangle[1] + scrollknob_hitbox_offset, screen.scrollbar_hitbox_rectangle[2], screen.scrollbar_hitbox_rectangle[1] + scrollknob_hitbox_offset + scrollknob_hitbox_height };
        

        //
        // Handle mouse input on the scrollbar. Store the input state in local variables first, and then check
        // if anything changed to the last frame, so that a new frame is only rendered if the state (and
        // therefore the visual feedback on screen) changed.
        //

        scrollbar_hovered  := mouse_over_rectangle(cmdx, screen.scrollbar_hitbox_rectangle);
        scrollknob_hovered := mouse_over_rectangle(cmdx, screen.scrollknob_hitbox_rectangle);
        scrollknob_dragged := screen.scrollknob_dragged;

        if scrollknob_hovered && cmdx.window.button_pressed[Button_Code.Left] {
            scrollknob_dragged = true; // Start dragging the knob if the user just pressed left-click on it
            screen.scrollknob_drag_offset = xx (cmdx.window.mouse_y - screen.scrollknob_hitbox_rectangle[1]);
        }
            
        if !scrollknob_dragged && scrollbar_hovered && cmdx.window.button_pressed[Button_Code.Left] {
            // If the user left-clicked somewhere on the scrollbar outside of the knob, then immediatly move
            // the knob to the mouse position, and start dragging. The knob's center should be placed under
            // the cursor, that feels juicy when warping the knob under the cursor.
            scrollknob_dragged = true;
            screen.scrollknob_drag_offset = xx (screen.scrollknob_hitbox_rectangle[3] - screen.scrollknob_hitbox_rectangle[1]) / 2;
        }

        if scrollknob_dragged {
            target_drag_position: f64 = xx (cmdx.window.mouse_y - screen.scrollbar_hitbox_rectangle[1]) - screen.scrollknob_drag_offset;
            target_inside_scrollbar_area: f64 = target_drag_position / xx (screen.scrollbar_hitbox_rectangle[3] - screen.scrollbar_hitbox_rectangle[1]);

            screen.scroll_target_offset = target_inside_scrollbar_area * xx screen.virtual_lines.count + xx first_line_offset;
        }
        
        if !cmdx.window.button_held[Button_Code.Left] scrollknob_dragged = false; // Stop dragging the knob when the user released the left mouse button

        // If any state changed during this frame, then we should render it to give immediate feedback to the
        // user.
        if screen.scrollbar_hitbox_hovered != scrollbar_hovered || screen.scrollknob_hitbox_hovered != scrollknob_hovered || screen.scrollknob_dragged != scrollknob_dragged draw_next_frame(cmdx);

        screen.scrollbar_hitbox_hovered  = scrollbar_hovered;
        screen.scrollknob_hitbox_hovered = scrollknob_hovered;
        screen.scrollknob_dragged        = scrollknob_dragged;

        
        //
        // Update the visual data for the scrollbar
        //

        scrollbar_visual_indent:  s32 = 2; // The non-rendered indent on both sided (left + right) of the scrollbar
        scrollknob_visual_indent: s32 = 2;
        if screen.scrollbar_hitbox_hovered || screen.scrollknob_dragged   scrollbar_visual_indent = 4;

        screen.scrollbar_visual_rectangle = { screen.scrollbar_hitbox_rectangle[0] + scrollbar_visual_indent, screen.scrollbar_hitbox_rectangle[1], screen.scrollbar_hitbox_rectangle[2] - scrollbar_visual_indent, screen.scrollbar_hitbox_rectangle[3] };

        screen.scrollknob_visual_rectangle = { screen.scrollknob_hitbox_rectangle[0] + scrollknob_visual_indent, screen.scrollknob_hitbox_rectangle[1], screen.scrollbar_hitbox_rectangle[2] - scrollknob_visual_indent, screen.scrollknob_hitbox_rectangle[3] };

        if screen.scrollknob_dragged
            screen.scrollknob_visual_color = cmdx.active_theme.colors[Color_Index.Accent];
        else
            screen.scrollknob_visual_color = cmdx.active_theme.colors[Color_Index.Default];

        screen.scrollbar_visual_color = cmdx.active_theme.colors[Color_Index.Scrollbar];

        
        //
        // Update the text input's cursor rendering data
        //
        text_until_cursor := get_string_view_until_cursor_from_text_input(*screen.text_input);
        text_until_cursor_width, text_until_cursor_height := query_text_size(*cmdx.font, text_until_cursor);
        cursor_alpha_previous := screen.text_input.cursor_alpha;
        set_text_input_target_position(*screen.text_input, xx text_until_cursor_width);
        update_text_input_rendering_data(*screen.text_input);
        if cursor_alpha_previous != screen.text_input.cursor_alpha    draw_next_frame(cmdx); // If the cursor changed it's blinking state, then we need to render the next frame for a smooth user experience. The cursor does not change if no input happened for a few seconds.
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
            draw_cmdx_screen(cmdx, *it.data);
        }

        // Render the ui on top of the actual terminal stuff
        if cmdx.draw_ui {
            draw_ui(*cmdx.ui, cmdx.window.frame_time);
            flush_font_buffer(*cmdx.renderer); // Flush all remaining ui texta
        }

        // Finish the screen, sleep until the next one
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



/* --- SCREEN API --- */

create_screen :: (cmdx: *CmdX) -> *CmdX_Screen {
    // Actually create the new screen, set the proper allocators for arrays and so forth
    screen := linked_list_push(*cmdx.screens);
    screen.auto_complete_options.allocator = *cmdx.global_allocator;
    screen.history.allocator        = *cmdx.global_allocator;
    screen.backlog_colors.allocator = *cmdx.global_allocator;
    screen.backlog_lines.allocator  = *cmdx.global_allocator;
    screen.virtual_lines.allocator  = *cmdx.global_allocator;
    screen.current_directory        = copy_string(*cmdx.global_allocator, cmdx.startup_directory);
    screen.text_input.active        = true;
    screen.backlog_size             = cmdx.backlog_size;
    screen.backlog                  = allocate(*cmdx.global_allocator, screen.backlog_size);
    screen.history_size             = cmdx.history_size;
    screen.index                    = cmdx.screens.count - 1;

    // Set up the backlog for this screen
    clear_backlog(cmdx, screen);

    // Readjust the screen rectangles with the new screen
    adjust_screen_rectangles(cmdx);

    return screen;
}

close_screen :: (cmdx: *CmdX, screen: *CmdX_Screen) {
    // Deallocate all the data that was allocated for this screen when it was created
    deallocate(*cmdx.global_allocator, screen.backlog);
    deallocate_string(*cmdx.global_allocator, *screen.current_directory);

    active_screen_index := screen.index % (cmdx.screens.count - 1); // Figure out the index of the new active screen

    // Remove the screen from the linked list
    linked_list_remove_pointer(*cmdx.screens, screen);

    cmdx.active_screen = linked_list_get(*cmdx.screens, active_screen_index);

    // Readjust the screen rectangles of the remaining screens
    adjust_screen_indices(cmdx);
    adjust_screen_rectangles(cmdx);
}

activate_screen :: (cmdx: *CmdX, screen: *CmdX_Screen) {
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



/* --- SETUP CODE --- */

draw_next_frame :: (cmdx: *CmdX) {
    cmdx.draw_frame = true;
}

get_window_style_and_range_check_window_position_and_size :: (cmdx: *CmdX) -> Window_Style_Flags {
    // Calculate the window style flags
    window_style: Window_Style_Flags;
    if cmdx.window.maximized window_style |= .Maximized;
    if cmdx.disabled_title_bar    window_style |= .Hide_Title_Bar;
    else window_style |= .Default;
    return window_style;
}

welcome_screen :: (cmdx: *CmdX, screen: *CmdX_Screen, run_tree: string) {
    config_location := concatenate_strings(*cmdx.frame_allocator, run_tree, CONFIG_FILE_NAME);

    set_themed_color(screen, .Accent);
    add_line(cmdx, screen, "    Welcome to cmdX.");
    set_themed_color(screen, .Default);
    add_line(cmdx, screen, "Use the :help command as a starting point.");
    add_formatted_line(cmdx, screen, "The config file can be found under %.", config_location);
    new_line(cmdx, screen); // Insert a new line for more visual clarity
}

get_prefix_string :: (screen: *CmdX_Screen, allocator: *Allocator) -> string {
    string_builder: String_Builder = ---;
    create_string_builder(*string_builder, allocator);
    if !screen.child_process_running    append_string(*string_builder, screen.current_directory);
    append_string(*string_builder, "> ");
    return finish_string_builder(*string_builder);
}

create_theme :: (cmdx: *CmdX, name: string, default: Color, cursor: Color, accent: Color, background: Color, scrollbar: Color) -> *Theme {
    theme := array_push(*cmdx.themes);
    theme.name = name;
    theme.colors[Color_Index.Default]    = default;
    theme.colors[Color_Index.Cursor]     = cursor;
    theme.colors[Color_Index.Accent]     = accent;
    theme.colors[Color_Index.Background] = background;
    theme.colors[Color_Index.Scrollbar]  = scrollbar;
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

update_active_process_name :: (cmdx: *CmdX, screen: *CmdX_Screen, process_name: string) {
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

    cmdx.startup_directory = copy_string(*cmdx.global_allocator, get_working_directory()); // @@Leak: get_working_directory() allocates on the Default_Allocator.

    // Register all commands
    register_all_commands(*cmdx);

    // Set the working directory of this program to where to executable file is, so that the data
    // folder can always be accessed.
    run_tree := get_module_path();
    defer deallocate_string(Default_Allocator, *run_tree);
    set_working_directory(run_tree);
    enable_high_resolution_time(); // Enable high resolution sleeping to keep a steady frame rate

    // Set up all the required config properties, and read the config file if it exists
    create_s64_property(*cmdx.config,    "backlog-size",      *cmdx.backlog_size);
    create_s64_property(*cmdx.config,    "history-size",      *cmdx.history_size);
    create_s64_property(*cmdx.config,    "scroll-speed",      *cmdx.scroll_speed);
    create_string_property(*cmdx.config, "theme",             *cmdx.active_theme_name);
    create_string_property(*cmdx.config, "font-name",         *cmdx.font_path);
    create_s64_property(*cmdx.config,    "font-size",         *cmdx.font_size);
    create_bool_property(*cmdx.config,   "window-borderless", *cmdx.disabled_title_bar);
    create_s32_property(*cmdx.config,    "window-x",          *cmdx.window.xposition);
    create_s32_property(*cmdx.config,    "window-y",          *cmdx.window.yposition);
    create_u32_property(*cmdx.config,    "window-width",      *cmdx.window.width);
    create_u32_property(*cmdx.config,    "window-height",     *cmdx.window.height);
    create_bool_property(*cmdx.config,   "window-maximized",  *cmdx.window.maximized);
    create_f32_property(*cmdx.config,    "window-fps",        *cmdx.requested_fps);
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
    create_theme(*cmdx, "blue",    .{ 186, 196, 214, 255 }, .{ 248, 173,  52, 255 }, .{ 248, 173,  52, 255 }, .{  21,  33,  42, 255 }, .{ 100, 100, 100, 255 });
    create_theme(*cmdx, "dark",    .{ 255, 255, 255, 255 }, .{ 255, 255, 255, 255 }, .{ 248, 173,  52, 255 }, .{   0,   0,   0, 255 }, .{ 100, 100, 100, 255 });
    create_theme(*cmdx, "gruvbox", .{ 230, 214, 174, 255 }, .{ 230, 214, 174, 255 }, .{ 250, 189,  47, 255 }, .{  40,  40,  40, 255 }, .{ 100, 100, 100, 255 });
    create_theme(*cmdx, "light",   .{  10,  10,  10, 255 }, .{  30,  30,  30, 255 }, .{  51,  94, 168, 255 }, .{ 255, 255, 255, 255 }, .{ 200, 200, 200, 255 });
    create_theme(*cmdx, "monokai", .{ 202, 202, 202, 255 }, .{ 231, 231, 231, 255 }, .{ 141, 208,   6, 255 }, .{  39,  40,  34, 255 }, .{ 100, 100, 100, 255 });
    create_theme(*cmdx, "autumn",  .{ 209, 184, 151, 255 }, .{ 255, 160, 122, 255 }, .{ 255, 127,  36, 255 }, .{   6,  36,  40, 255 }, .{  19, 115, 130, 255 });
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
// @Incomplete: When hovering the scroll bar and then quickly leaving the screen area, the frame doesn't get redrawn, and so the scroll bar is still visually hovered
// @Incomplete: enable_auto_scroll is broken

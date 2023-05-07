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
    memory_arena: Memory_Arena;
    memory_pool: Memory_Pool;
    allocator: Allocator;
    
    window: Window;
    renderer: Renderer;

    text_input: Text_Input;
    backlog: [..]string;

    active_theme: *Theme;
    themes: [..]Theme;
}

add_string_to_backlog :: (cmdx: *CmdX, message: string) {
    if !message.count return;

    array_add(*cmdx.backlog, copy_string(message, *cmdx.allocator));
}

add_buffer_to_backlog :: (cmdx: *CmdX, buffer: []s8, count: u32) {
    if !count return;

    array_add(*cmdx.backlog, make_string(buffer, count, *cmdx.allocator));
}

create_theme :: (cmdx: *CmdX, name: string, font_path: string, font_color: Color, background_color: Color) -> *Theme {
    theme := array_push(*cmdx.themes);
    theme.name = name;
    theme.font_color = font_color;
    theme.background_color = background_color;
    load_font(*theme.font, font_path, 15, xx create_gl_texture_2d, null);
    return theme;
}

main :: () -> s32 {
    // Prepare the module
    run_tree := get_module_path();
    defer free_string(run_tree, *Default_Allocator);
    set_working_directory(run_tree);
    enable_high_resolution_time();

    // Set up CmdX
    cmdx: CmdX;
    create_memory_arena(*cmdx.memory_arena, 4 * GIGABYTES);
    create_memory_pool(*cmdx.memory_pool, *cmdx.memory_arena);
    cmdx.allocator         = memory_pool_allocator(*cmdx.memory_pool);
    cmdx.backlog.allocator = *cmdx.allocator;
    cmdx.text_input.active = true;
    
    // Create the window and the renderer
    create_window(*cmdx.window, "cmdX", 1280, 720, WINDOW_DONT_CARE, WINDOW_DONT_CARE, false);
    create_gl_context(*cmdx.window, 3, 3);
    create_renderer(*cmdx.renderer);
    cmdx.active_theme = create_theme(*cmdx, "light", COURIER_NEW, .{ 10, 10, 10, 255 }, .{ 255, 255, 255, 255 });

    while !cmdx.window.should_close {
        frame_start := get_hardware_time();

        // Prepare the next frame
        update_window(*cmdx.window);
        prepare_renderer(*cmdx.renderer, cmdx.active_theme, *cmdx.window);        
        
        // Update the terminal input
        for i := 0; i < cmdx.window.text_input_event_count; ++i   handle_text_input_event(*cmdx.text_input, cmdx.window.text_input_events[i]);
        
        if cmdx.text_input.entered {
            // The user has entered a string, add that to the backlog, clear the input and actually run
            // the command.
            feedback_string := concatenate_strings("> ", get_string_view_from_text_input(*cmdx.text_input), *cmdx.allocator);
            add_string_to_backlog(*cmdx, feedback_string);
            clear_text_input(*cmdx.text_input);
            activate_text_input(*cmdx.text_input);
        }

        // Draw all the text in the terminal
        draw_text(*cmdx.renderer, cmdx.active_theme, ">", 5, cmdx.window.height - 10);
        draw_text_input(*cmdx.renderer, cmdx.active_theme, *cmdx.text_input, 20, cmdx.window.height - 10);
        draw_backlog(*cmdx.renderer, cmdx.active_theme, *cmdx.backlog, 5, cmdx.window.height - 10 - cmdx.active_theme.font.line_height);

        // Finish the frame, sleep until the next one
        swap_gl_buffers(*cmdx.window);
        dump_gl_errors("Frame");

        frame_end := get_hardware_time();
        active_frame_time := convert_hardware_time(frame_end - frame_start, .Milliseconds);
        if active_frame_time < EXPECTED_FRAME_TIME_MILLISECONDS {
            time_to_sleep: f32 = EXPECTED_FRAME_TIME_MILLISECONDS - active_frame_time;
            Sleep(xx floorf(time_to_sleep) - 1);
        }
    }

    // Cleanup
    destroy_renderer(*cmdx.renderer);
    destroy_gl_context(*cmdx.window);
    destroy_window(*cmdx.window);
    return 0;
}

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
SELECTED_FONT   :: COURIER_NEW;

// --- Timing
EXPECTED_FPS: f32 : 60;
EXPECTED_FRAME_TIME_MILLISECONDS: f32 : 1000 / EXPECTED_FPS;

// --- Global variables
font: Font;
window: Window;
backlog: [..]string;

// --- Styling
Theme :: struct {
    font_color: Color;
    background_color: Color;
}

Dark_Theme  := Theme.{ .{255, 255, 255, 255},
                       .{  0,   0,   0, 255} };
Light_Theme := Theme.{ .{  0,   0,   0, 255},
                       .{255, 255, 255, 255} };
Active_Theme: *Theme;


draw_backlog :: (x: s32, y: s32) {
    index: s64 = backlog.count - 1;
    while y > 0 && index >= 0 {
        log := array_get(*backlog, index);
        draw_text(~log, x, y);
        y -= font.line_height;
        --index;
    }
}

add_message_to_backlog :: (message: string) {
    if message.count    array_add(*backlog, message);
}

main :: () -> s32 {
    // Prepare the module
    run_tree := get_module_path();
    defer free_string(run_tree);
    set_working_directory(run_tree);
    enable_high_resolution_time();

    // Create the window and the renderer
    create_window(*window, "cmdX", 1280, 720, WINDOW_DONT_CARE, WINDOW_DONT_CARE, false);
    create_gl_context(*window, 3, 3);
    create_renderer();
    load_font(*font, SELECTED_FONT, 15, xx create_gl_texture_2d, null);

    Active_Theme = *Dark_Theme;
    
    text_input: Text_Input;
    text_input.active = true;

    // Spam the backlog for now so that there is some text to see
    for i := 0; i < 64; ++i    add_message_to_backlog("Hello Sailor");
    
    while !window.should_close {
        frame_start := get_hardware_time();

        // Prepare the next frame
        update_window(*window);
        prepare_renderer();        

        // Check for pressed hotkeys
        if window.key_held[Key_Code.Control] && window.key_pressed[Key_Code.T] {
            if Active_Theme == *Dark_Theme Active_Theme = *Light_Theme;
            else Active_Theme = *Dark_Theme;
        }
        
        // Update the terminal input
        for i := 0; i < window.text_input_event_count; ++i   handle_text_input_event(*text_input, window.text_input_events[i]);
        
        if text_input.entered {
            input := get_string_from_text_input(*text_input);
            add_message_to_backlog(input);
            
            clear_text_input(*text_input);
            activate_text_input(*text_input);
        }

        // Draw all the text in the terminal
        draw_text(">", 5, window.height - 10);
        draw_text_input(*text_input, 20, window.height - 10);
        draw_backlog(20, window.height - 10 - font.line_height);

        // Finish the frame, sleep until the next one
        swap_gl_buffers(*window);

        frame_end := get_hardware_time();
        active_frame_time := convert_hardware_time(frame_end - frame_start, .Milliseconds);
        if active_frame_time < EXPECTED_FRAME_TIME_MILLISECONDS {
            time_to_sleep: f32 = EXPECTED_FRAME_TIME_MILLISECONDS - active_frame_time;
            Sleep(xx floorf(time_to_sleep) - 1);
        }
    }

    // Cleanup
    destroy_renderer();
    destroy_gl_context(*window);
    destroy_window(*window);
    return 0;
}

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

EXPECTED_FPS: f32 : 60;
EXPECTED_FRAME_TIME_MILLISECONDS: f32 : 1000 / EXPECTED_FPS;

font: Font;
window: Window;
backlog: [..]string;

draw_backlog :: (x: s32, y: s32) {
    index: s64 = backlog.count - 1;
    while y > 0 && index >= 0 {
        log := array_get(*backlog, index);
        draw_text(~log, x, y);
        y -= font.line_height;
        --index;
    }
}

main :: () -> s32 {
    run_tree := get_module_path();
    defer free_string(run_tree);
    set_working_directory(run_tree);
    enable_high_resolution_time();
    
    create_window(*window, "cmdX", 1280, 720, WINDOW_DONT_CARE, WINDOW_DONT_CARE, false);
    create_gl_context(*window, 3, 3);
    create_renderer();
    load_font(*font, 20, xx create_gl_texture_2d, null);

    text_input: Text_Input;
    text_input.active = true;

    while !window.should_close {
        frame_start := get_hardware_time();
        
        update_window(*window);
        prepare_renderer();

        glClearColor(0.2, 0.2, 0.2, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        
        for i := 0; i < window.text_input_event_count; ++i   handle_text_input_event(*text_input, window.text_input_events[i]);

        if text_input.entered {
            input := get_string_from_text_input(*text_input);
            if input.count {
                array_add(*backlog, input);
            }

            clear_text_input(*text_input);
            activate_text_input(*text_input);
        }
        
        draw_text(">", 5, window.height - 10);
        draw_text_input(*text_input, 20, window.height - 10);
        draw_backlog(20, window.height - 10 - font.line_height);
        
        swap_gl_buffers(*window);

        frame_end := get_hardware_time();
        active_frame_time := convert_hardware_time(frame_end - frame_start, .Milliseconds);
        if active_frame_time < EXPECTED_FRAME_TIME_MILLISECONDS {
            time_to_sleep: f32 = EXPECTED_FRAME_TIME_MILLISECONDS - active_frame_time;
            Sleep(xx floorf(time_to_sleep) - 1);
        }
    }

    destroy_renderer();
    destroy_gl_context(*window);
    destroy_window(*window);
    return 0;
}

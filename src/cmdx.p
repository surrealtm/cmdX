#load "basic.p";
#load "window.p";
#load "font.p";
#load "software_renderer.p";
#load "text_input.p";

font: Font;
window: Window;
framebuffer: Software_Render_Target;
texture_catalog: Software_Texture_Catalog;

draw_text :: (text: string, x: u32, y: u32) {
    render_tinted_text_with_font(*font, text, x, y, .Left, 255, 255, 255, xx render_tinted_textured_quad, xx *framebuffer);
}

draw_text_input :: (input: *Text_Input, x: u32, y: u32) {
    // Query the complete text to render
    text := get_string_from_text_input(input);
    glyph_width, glyph_height := query_glyph_size(*font, 'F');
    if input.cursor != input.count   glyph_width = 2; // If the cursor is in between characters, make it smaller so that it does not obscur any characters

    // Query the text until the cursor for rendering alignment
    text_until_cursor := get_string_until_cursor_from_text_input(input);
    text_until_cursor_width, text_until_cursor_height := calculate_text_size(*font, text_until_cursor);
    
    // Update the internal text input rendering state
    set_text_input_target_position(input, xx text_until_cursor_width);
    update_text_input_rendering_data(input);

    // Render the actual text
    draw_text(text, x, y);
    
    if input.active {
        // Render the cursor if the text input is active
        render_colored_quad(*framebuffer, x + xx input.cursor_position_interpolation, y - glyph_height * 2 - font.descender / 2, glyph_width, glyph_height * 2, 255, 255, 255, xx (input.cursor_alpha * 255));
    } else if text.count == 0 {
        // Render the tool tip if the text input is not active, and the no text is currently in the buffer
        draw_text(input.tool_tip, x, y);
    }
}

main :: () -> s32 {
    create_window(*window, "cmdX", 1280, 720, WINDOW_DONT_CARE, WINDOW_DONT_CARE, false);
    allocate_software_render_target(*framebuffer, window.width, window.height, .BGRA);
    load_font(*font, 20, xx allocate_software_texture, xx *texture_catalog);

    text_input: Text_Input;
    text_input.active = true;
    
    while !window.should_close {
        update_window(*window);
        if window.resized   resize_software_render_target(*framebuffer, window.width, window.height);

        clear_software_render_target(*framebuffer, 20, 60, 100, 255);

        for i := 0; i < window.text_input_event_count; ++i   handle_text_input_event(*text_input, window.text_input_events[i]);
        draw_text(">", 5, window.height - 10);
        draw_text_input(*text_input, 20, window.height - 10);
        
        blit_pixels_to_window(*window, framebuffer.pixels, framebuffer.width, framebuffer.height);
        
        Sleep(16);
    }

    destroy_software_texture_catalog(*texture_catalog);
    destroy_software_render_target(*framebuffer);
    destroy_window(*window);
    return 0;
}

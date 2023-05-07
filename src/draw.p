Color :: struct {
    r: u16;
    g: u16;
    b: u16;
    a: u16;
}

Renderer :: struct {
    font_shader: Shader;
    quad_shader: Shader;
    quad_vertex_buffer: Vertex_Buffer;

    projection_matrix: m4f;
}

renderer: Renderer;

create_renderer :: () {
    create_shader_from_file(*renderer.font_shader, "data/font_shader.glsl");
    create_shader_from_file(*renderer.quad_shader, "data/quad_shader.glsl");

    quad_vertices: [12]f32 = { 0, 0,   0, 1,   1, 1,   0, 0,   1, 1,   1, 0 };
    create_vertex_buffer(*renderer.quad_vertex_buffer);
    add_vertex_data(*renderer.quad_vertex_buffer, quad_vertices, quad_vertices.count, 2);
}

destroy_renderer :: () {
    destroy_shader(*renderer.font_shader);
    destroy_shader(*renderer.quad_shader);
    destroy_vertex_buffer(*renderer.quad_vertex_buffer);
}

prepare_renderer :: () {
    renderer.projection_matrix = make_orthographic_projection_matrix(xx window.width, xx window.height, 1);

    glClearColor(xx Active_Theme.background_color.r / 255.0,
                 xx Active_Theme.background_color.g / 255.0,
                 xx Active_Theme.background_color.b / 255.0,
                 xx Active_Theme.background_color.a / 255.0);
    glClear(GL_COLOR_BUFFER_BIT);
    glViewport(0, 0, window.width, window.height);
}

draw_single_glyph :: (window: *Window, x: s32, y: s32, w: u32, h: u32, texture: u64, r: u8, g: u8, b: u8) {
    position := v2f.{ xx (x - window.width / 2), xx (y - window.height / 2) };
    scale := v2f.{ xx w, xx h };

    glBindTexture(GL_TEXTURE_2D, texture);
    set_shader_uniform_v2f(*renderer.font_shader, "u_position", position);
    set_shader_uniform_v2f(*renderer.font_shader, "u_scale", scale);
    set_shader_uniform_v4f(*renderer.font_shader, "u_foreground", v4f.{ xx r / 255.0, xx g / 255.0, xx b / 255.0, 1 });
    draw_vertex_buffer(*renderer.quad_vertex_buffer);
}

draw_text :: (text: string, x: s32, y: s32) {
    set_blending(.Normal);
    set_shader(*renderer.font_shader);
    set_vertex_buffer(*renderer.quad_vertex_buffer);
    set_shader_uniform_m4f(*renderer.font_shader, "u_projection", renderer.projection_matrix);
    set_shader_uniform_v4f(*renderer.font_shader, "u_background", v4f.{ xx Active_Theme.background_color.r / 255.0,
                                                                        xx Active_Theme.background_color.g / 255.0,
                                                                        xx Active_Theme.background_color.b / 255.0,
                                                                        xx Active_Theme.background_color.a / 255.0 });
    
    render_tinted_text_with_font(*font, text, x, y, .Left, Active_Theme.font_color.r, Active_Theme.font_color.b, Active_Theme.font_color.b, xx draw_single_glyph, xx *window);
}

draw_quad :: (x: s32, y: s32, w: u32, h: u32, color: Color) {
    position := v2f.{ xx (x - window.width / 2), xx (y - window.height / 2) };
    scale := v2f.{ xx w, xx h };

    set_blending(.Normal);
    set_shader(*renderer.quad_shader);
    set_shader_uniform_v2f(*renderer.quad_shader, "u_scale", scale);
    set_shader_uniform_v2f(*renderer.quad_shader, "u_position", position);
    set_shader_uniform_v4f(*renderer.quad_shader, "u_color", v4f.{ xx color.r / 255.0, xx color.g / 255.0, xx color.b / 255.0, xx color.a / 255.0 });
    set_shader_uniform_m4f(*renderer.quad_shader, "u_projection", renderer.projection_matrix);
    set_vertex_buffer(*renderer.quad_vertex_buffer);
    draw_vertex_buffer(*renderer.quad_vertex_buffer);
}

draw_text_input :: (input: *Text_Input, x: s32, y: s32) {
    // Query the complete text to render
    text := get_string_from_text_input(input);

    cursor_width: u32 = 8;
    cursor_height: u32 = font.line_height;
    if input.cursor != input.count   cursor_width = 2; // If the cursor is in between characters, make it smaller so that it does not obscur any characters

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
        cursor_color := Color.{ Active_Theme.font_color.r, Active_Theme.font_color.g, Active_Theme.font_color.b, xx (input.cursor_alpha * 255) };
        draw_quad(x + xx input.cursor_interpolated_position, y - font.ascender, cursor_width, cursor_height, cursor_color);
    } else if text.count == 0 {
        // Render the tool tip if the text input is not active, and the no text is currently in the buffer
        draw_text(input.tool_tip, x, y);
    }
}

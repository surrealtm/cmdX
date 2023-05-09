Color :: struct {
    r: u8;
    g: u8;
    b: u8;
    a: u8;
}

Renderer :: struct {
    font_shader: Shader;
    quad_shader: Shader;
    quad_vertex_buffer: Vertex_Buffer;

    width: u32;
    height: u32;
    projection_matrix: m4f;
}

create_renderer :: (renderer: *Renderer) {
    create_shader_from_file(*renderer.font_shader, "data/font_shader.glsl");
    create_shader_from_file(*renderer.quad_shader, "data/quad_shader.glsl");

    quad_vertices: [12]f32 = { 0, 0,   0, 1,   1, 1,   0, 0,   1, 1,   1, 0 };
    create_vertex_buffer(*renderer.quad_vertex_buffer);
    add_vertex_data(*renderer.quad_vertex_buffer, quad_vertices, quad_vertices.count, 2);
}

destroy_renderer :: (renderer: *Renderer) {
    destroy_shader(*renderer.font_shader);
    destroy_shader(*renderer.quad_shader);
    destroy_vertex_buffer(*renderer.quad_vertex_buffer);
}

prepare_renderer :: (renderer: *Renderer, theme: *Theme, window: *Window) {
    renderer.width  = window.width;
    renderer.height = window.height;
    renderer.projection_matrix = make_orthographic_projection_matrix(xx renderer.width, xx renderer.height, 1);
    glViewport(0, 0, renderer.width, renderer.height);
    
    glClearColor(xx theme.background_color.r / 255.0,
                 xx theme.background_color.g / 255.0,
                 xx theme.background_color.b / 255.0,
                 xx theme.background_color.a / 255.0);
    glClear(GL_COLOR_BUFFER_BIT);
}

draw_single_glyph :: (renderer: *Renderer, x: s32, y: s32, w: u32, h: u32, texture: u64, r: u8, g: u8, b: u8) {
    position := v2f.{ xx x - xx renderer.width / 2, xx y - xx renderer.height / 2 };
    scale := v2f.{ xx w, xx h };

    glBindTexture(GL_TEXTURE_2D, texture);
    set_shader_uniform_v2f(*renderer.font_shader, "u_position", position);
    set_shader_uniform_v2f(*renderer.font_shader, "u_scale", scale);
    set_shader_uniform_v4f(*renderer.font_shader, "u_foreground", v4f.{ xx r / 255.0, xx g / 255.0, xx b / 255.0, 1 });
    draw_vertex_buffer(*renderer.quad_vertex_buffer);
}

draw_text :: (renderer: *Renderer, theme: *Theme, text: string, x: s32, y: s32, color: Color) {
    set_blending(.Normal);
    set_shader(*renderer.font_shader);
    set_vertex_buffer(*renderer.quad_vertex_buffer);
    set_shader_uniform_m4f(*renderer.font_shader, "u_projection", renderer.projection_matrix);
    set_shader_uniform_v4f(*renderer.font_shader, "u_background", v4f.{ xx theme.background_color.r / 255.0,
                                                                        xx theme.background_color.g / 255.0,
                                                                        xx theme.background_color.b / 255.0,
                                                                        xx theme.background_color.a / 255.0 });
    
    render_tinted_text_with_font(*theme.font, text, x, y, .Left, color.r, color.g, color.b, xx draw_single_glyph, xx renderer);
}

draw_quad :: (renderer: *Renderer, x: s32, y: s32, w: u32, h: u32, color: Color) {
    position := v2f.{ xx x - xx renderer.width / 2, xx y - xx renderer.height / 2 };
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

draw_text_input :: (renderer: *Renderer, theme: *Theme, input: *Text_Input, prefix_string: string, x: s32, y: s32) {
    input_string := get_string_view_from_text_input(input);
        
    // Update the internal text input rendering state
    text_until_cursor := get_string_view_until_cursor_from_text_input(input);
    text_until_cursor_width, text_until_cursor_height := calculate_text_size(*theme.font, text_until_cursor);
    set_text_input_target_position(input, xx text_until_cursor_width);
    update_text_input_rendering_data(input);

    // Render the input string
    draw_text(renderer, theme, prefix_string, x, y, theme.accent_color);
    x += calculate_text_width(*theme.font, prefix_string);
    draw_text(renderer, theme, input_string, x, y, theme.font_color);

    if input.active {
        // Calculate the cursor size
        cursor_width: u32 = calculate_text_width(*theme.font, "M");
        cursor_height: u32 = theme.font.line_height;
        if input.cursor != input.count   cursor_width = 2; // If the cursor is in between characters, make it smaller so that it does not obscur any characters

        // Render the cursor if the text input is active
        cursor_color := Color.{ theme.cursor_color.r, theme.cursor_color.g, theme.cursor_color.b, xx (input.cursor_alpha * 255) };
        draw_quad(renderer, x + xx input.cursor_interpolated_position, y - theme.font.ascender, cursor_width, cursor_height, cursor_color);
    }
}

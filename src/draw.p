GLYPH_BATCH_COUNT :: 4096;
GLYPH_BUFFER_SIZE :: GLYPH_BATCH_COUNT * 6 * 2; // 6 Vertices per glyph a 2 dimensions

Color :: struct {
    r: u8;
    g: u8;
    b: u8;
    a: u8;
}

compare_colors :: (lhs: Color, rhs: Color) -> bool {
    return lhs.r == rhs.r && lhs.g == rhs.g && lhs.b == rhs.b;
}

Renderer :: struct {
    font_shader: Shader;
    font_vertex_buffer: Vertex_Buffer;
    font_vertices: *f32;
    font_uvs: *f32;
    font_glyph_count: u32;
    foreground_color: Color;
    background_color: Color;
    font_texture_handle: u64;
    
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
    
    create_vertex_buffer(*renderer.font_vertex_buffer);
    allocate_vertex_data(*renderer.font_vertex_buffer, GLYPH_BUFFER_SIZE, 2);
    allocate_vertex_data(*renderer.font_vertex_buffer, GLYPH_BUFFER_SIZE, 2);
    
    renderer.font_vertices = xx allocate(Default_Allocator, GLYPH_BUFFER_SIZE * size_of(f32));
    renderer.font_uvs = xx allocate(Default_Allocator, GLYPH_BUFFER_SIZE * size_of(f32));
}

destroy_renderer :: (renderer: *Renderer) {
    destroy_shader(*renderer.font_shader);
    destroy_shader(*renderer.quad_shader);
    destroy_vertex_buffer(*renderer.quad_vertex_buffer);
    destroy_vertex_buffer(*renderer.font_vertex_buffer);
    
    deallocate(Default_Allocator, xx renderer.font_vertices);
    deallocate(Default_Allocator, xx renderer.font_uvs);
}

prepare_renderer :: (renderer: *Renderer, theme: *Theme, window: *Window) {
    renderer.width  = window.width;
    renderer.height = window.height;
    renderer.projection_matrix   = make_orthographic_projection_matrix(xx renderer.width, xx renderer.height, 1);
    renderer.background_color    = theme.background_color;
    renderer.font_texture_handle = theme.font.texture.handle;

    glViewport(0, 0, renderer.width, renderer.height);
    
    glClearColor(xx theme.background_color.r / 255.0,
                 xx theme.background_color.g / 255.0,
                 xx theme.background_color.b / 255.0,
                 xx theme.background_color.a / 255.0);
    glClear(GL_COLOR_BUFFER_BIT);
}

flush_font_buffer :: (renderer: *Renderer) {
    set_shader(*renderer.font_shader);
    set_shader_uniform_m4f(*renderer.font_shader, "u_projection", renderer.projection_matrix);
    set_shader_uniform_v4f(*renderer.font_shader, "u_background", v4f.{ xx renderer.background_color.r / 255.0,
                               xx renderer.background_color.g / 255.0,
                               xx renderer.background_color.b / 255.0,
                               xx renderer.background_color.a / 255.0 });
    set_shader_uniform_v4f(*renderer.font_shader, "u_foreground", v4f.{ xx renderer.foreground_color.r / 255.0,
                               xx renderer.foreground_color.g / 255.0,
                               xx renderer.foreground_color.b / 255.0,
                               xx renderer.foreground_color.a / 255.0 });
    
    glBindTexture(GL_TEXTURE_2D, renderer.font_texture_handle);
    
    set_vertex_buffer(*renderer.font_vertex_buffer);
    update_vertex_data(*renderer.font_vertex_buffer, 0, renderer.font_vertices, renderer.font_glyph_count * 12);
    update_vertex_data(*renderer.font_vertex_buffer, 1, renderer.font_uvs, renderer.font_glyph_count * 12);
    draw_vertex_buffer(*renderer.font_vertex_buffer);
    
    renderer.font_glyph_count = 0;
}

draw_single_glyph :: (renderer: *Renderer, x: s32, y: s32, w: u32, h: u32, uv_x: f32, uv_y: f32, uv_w: f32, uv_h: f32) {
    if renderer.font_glyph_count == GLYPH_BATCH_COUNT flush_font_buffer(renderer);
    
    position := v2f.{ xx x - xx renderer.width / 2, xx y - xx renderer.height / 2 };
    size     := v2f.{ xx w, xx h };
    
    buffer_offset := renderer.font_glyph_count * 12;
    renderer.font_vertices[buffer_offset + 0] = position.x;
    renderer.font_vertices[buffer_offset + 1] = position.y;
    
    renderer.font_vertices[buffer_offset + 2] = position.x;
    renderer.font_vertices[buffer_offset + 3] = position.y + size.y;
    
    renderer.font_vertices[buffer_offset + 4] = position.x + size.x;
    renderer.font_vertices[buffer_offset + 5] = position.y + size.y;
    
    renderer.font_vertices[buffer_offset + 6] = position.x;
    renderer.font_vertices[buffer_offset + 7] = position.y;
    
    renderer.font_vertices[buffer_offset + 8] = position.x + size.x;
    renderer.font_vertices[buffer_offset + 9] = position.y + size.y;
    
    renderer.font_vertices[buffer_offset + 10] = position.x + size.x;
    renderer.font_vertices[buffer_offset + 11] = position.y;
    
    renderer.font_uvs[buffer_offset + 0] = uv_x;
    renderer.font_uvs[buffer_offset + 1] = uv_y;
    
    renderer.font_uvs[buffer_offset + 2] = uv_x;
    renderer.font_uvs[buffer_offset + 3] = uv_y + uv_h;
    
    renderer.font_uvs[buffer_offset + 4] = uv_x + uv_w;
    renderer.font_uvs[buffer_offset + 5] = uv_y + uv_h;
    
    renderer.font_uvs[buffer_offset + 6] = uv_x;
    renderer.font_uvs[buffer_offset + 7] = uv_y;
    
    renderer.font_uvs[buffer_offset + 8] = uv_x + uv_w;
    renderer.font_uvs[buffer_offset + 9] = uv_y + uv_h;
    
    renderer.font_uvs[buffer_offset + 10] = uv_x + uv_w;
    renderer.font_uvs[buffer_offset + 11] = uv_y;
    
    ++renderer.font_glyph_count;
}

draw_text :: (renderer: *Renderer, theme: *Theme, text: string, x: s32, y: s32, color: Color) {
    if renderer.foreground_color.r != color.r || renderer.foreground_color.g != color.g || renderer.foreground_color.b != color.b || renderer.foreground_color.a != color.a   flush_font_buffer(renderer); // Since the font buffer only supports a constant color, it needs to be flushed with the previous color to allow for the new color afterwards
    
    renderer.foreground_color = color;
    render_text_with_font(*theme.font, text, x, y, .Left, xx draw_single_glyph, xx renderer);
}

draw_quad :: (renderer: *Renderer, x: s32, y: s32, w: u32, h: u32, color: Color) {
    position := v2f.{ xx x - xx renderer.width / 2, xx y - xx renderer.height / 2 };
    scale := v2f.{ xx w, xx h };
    
    if color.a != 255 set_blending(.Normal);
    
    set_shader(*renderer.quad_shader);
    set_shader_uniform_v2f(*renderer.quad_shader, "u_scale", scale);
    set_shader_uniform_v2f(*renderer.quad_shader, "u_position", position);
    set_shader_uniform_v4f(*renderer.quad_shader, "u_color", v4f.{ xx color.r / 255.0, xx color.g / 255.0, xx color.b / 255.0, xx color.a / 255.0 });
    set_shader_uniform_m4f(*renderer.quad_shader, "u_projection", renderer.projection_matrix);
    set_vertex_buffer(*renderer.quad_vertex_buffer);
    draw_vertex_buffer(*renderer.quad_vertex_buffer);
    
    if color.a != 255 set_blending(.None);
}

draw_outlined_quad :: (renderer: *Renderer, x: s32, y: s32, w: u32, h: u32, border: u32, color: Color) {
    draw_quad(renderer, x, y, w, border, color);
    draw_quad(renderer, x, y, border, h, color);
    draw_quad(renderer, x, y + h - border, w, border, color);
    draw_quad(renderer, x + w - border, y, border, h, color);
}

draw_text_input :: (renderer: *Renderer, theme: *Theme, input: *Text_Input, prefix_string: string, x: s32, y: s32) {
    // Gather the actually input string
    input_string := get_string_view_from_text_input(input);
    prefix_string_width := query_text_width(*theme.font, prefix_string);
    
    // Update the internal text input rendering state
    text_until_cursor := get_string_view_until_cursor_from_text_input(input);
    text_until_cursor_width, text_until_cursor_height := query_text_size(*theme.font, text_until_cursor);
    set_text_input_target_position(input, xx text_until_cursor_width);
    update_text_input_rendering_data(input);
    
    // Render the input string
    draw_text(renderer, theme, input_string, x + prefix_string_width, y, theme.font_color);
    
    // Render the string prefix
    draw_text(renderer, theme, prefix_string, x, y, theme.accent_color);
    
    // Flush all text before rendering the cursor to make sure the cursor always gets rendered on top of the font
    flush_font_buffer(renderer);
    
    // Calculate the cursor size
    cursor_width:  u32 = query_text_width(*theme.font, "M");
    cursor_height: u32 = theme.font.line_height;
    if input.cursor != input.count   cursor_width = 2; // If the cursor is in between characters, make it smaller so that it does not obscur any characters
    
    // Render the cursor if the text input is active
    cursor_color := Color.{ theme.cursor_color.r, theme.cursor_color.g, theme.cursor_color.b, xx (input.cursor_alpha * 255) };
    
    if !input.active {
        // If the text input is not active, render an outlined quad as the cursor
        draw_outlined_quad(renderer, x + prefix_string_width + xx input.cursor_interpolated_position, y - theme.font.ascender, cursor_width, cursor_height, 1, cursor_color);
    } else
        // If the text input is active, render a filled quad
        draw_quad(renderer, x + prefix_string_width + xx input.cursor_interpolated_position, y - theme.font.ascender, cursor_width, cursor_height, cursor_color);
}

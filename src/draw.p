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

    renderer.font_glyph_count = 0;
    renderer.width  = 0;
    renderer.height = 0;
}

destroy_renderer :: (renderer: *Renderer) {
    destroy_shader(*renderer.font_shader);
    destroy_shader(*renderer.quad_shader);
    destroy_vertex_buffer(*renderer.quad_vertex_buffer);
    destroy_vertex_buffer(*renderer.font_vertex_buffer);
    
    deallocate(Default_Allocator, xx renderer.font_vertices);
    deallocate(Default_Allocator, xx renderer.font_uvs);
}

prepare_renderer :: (renderer: *Renderer, theme: *Theme, font: *Font, window: *Window) {
    renderer.width  = window.width;
    renderer.height = window.height;
    renderer.projection_matrix = make_orthographic_projection_matrix(xx renderer.width / 2, xx renderer.height / -2, -1, 1); // The coordinate space for this application is a bit different than for games, here we want positive y to mean downwards...

    glViewport(0, 0, renderer.width, renderer.height);
    
    glClearColor(xx theme.colors[Color_Index.Background].r / 255.0,
                 xx theme.colors[Color_Index.Background].g / 255.0,
                 xx theme.colors[Color_Index.Background].b / 255.0,
                 xx theme.colors[Color_Index.Background].a / 255.0);
    glClear(GL_COLOR_BUFFER_BIT);
}

set_foreground_color :: (renderer: *Renderer, color: Color) {
    if !compare_colors(renderer.foreground_color, color) flush_font_buffer(renderer);
    renderer.foreground_color = color;
}

set_background_color :: (renderer: *Renderer, color: Color) {
    if !compare_colors(renderer.background_color, color) flush_font_buffer(renderer);
    renderer.background_color = color;
}

flush_font_buffer :: (renderer: *Renderer) {
    if renderer.font_glyph_count == 0 return;

    set_shader(*renderer.font_shader);
    set_shader_uniform_m4f(*renderer.font_shader, "u_projection", renderer.projection_matrix);
    set_shader_uniform_v4f(*renderer.font_shader, "u_background", v4f.{
        xx renderer.background_color.r / 255.0,
        xx renderer.background_color.g / 255.0,
        xx renderer.background_color.b / 255.0,
        xx renderer.background_color.a / 255.0 });
    set_shader_uniform_v4f(*renderer.font_shader, "u_foreground", v4f.{
        xx renderer.foreground_color.r / 255.0,
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

draw_single_glyph :: (renderer: *Renderer, x: s32, y: s32, w: u32, h: u32, uv_x: f32, uv_y: f32, uv_w: f32, uv_h: f32, texture_handle: s64) {
    if renderer.font_glyph_count == GLYPH_BATCH_COUNT || texture_handle != renderer.font_texture_handle flush_font_buffer(renderer);

    renderer.font_texture_handle = texture_handle;
    
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

draw_text :: (renderer: *Renderer, font: *Font, text: string, x: s32, y: s32, foreground_color: Color, background_color: Color) {
    if !compare_colors(renderer.foreground_color, foreground_color) || !compare_colors(renderer.background_color, background_color) flush_font_buffer(renderer); // Since the font buffer only supports a constant color, it needs to be flushed with the previous color to allow for the new color afterwards
    
    renderer.foreground_color = foreground_color;
    renderer.background_color = background_color;
    render_text_with_font(font, text, x, y, .Left, xx draw_single_glyph, xx renderer);
}

draw_quad :: (renderer: *Renderer, x0: s32, y0: s32, x1: s32, y1: s32, color: Color) {
    position := v2f.{ xx x0 - xx renderer.width / 2, xx y0 - xx renderer.height / 2 };
    scale := v2f.{ xx (x1 - x0), xx (y1 - y0) };
    
    if color.a != 255    set_blending(.Default);
    
    set_shader(*renderer.quad_shader);
    set_shader_uniform_v2f(*renderer.quad_shader, "u_scale", scale);
    set_shader_uniform_v2f(*renderer.quad_shader, "u_position", position);
    set_shader_uniform_v4f(*renderer.quad_shader, "u_color", v4f.{ xx color.r / 255.0, xx color.g / 255.0, xx color.b / 255.0, xx color.a / 255.0 });
    set_shader_uniform_m4f(*renderer.quad_shader, "u_projection", renderer.projection_matrix);
    set_vertex_buffer(*renderer.quad_vertex_buffer);
    draw_vertex_buffer(*renderer.quad_vertex_buffer);
    
    if color.a != 255 set_blending(.None);
}

draw_outlined_quad :: (renderer: *Renderer, x0: s32, y0: s32, x1: s32, y1: s32, border: u32, color: Color) {
    draw_quad(renderer, x0, y0, x1, y0 + border, color); // Top edge
    draw_quad(renderer, x0, y0, x0 + border, y1, color); // Left edge
    draw_quad(renderer, x0, y1 - border, x1, y1, color); // Bottom edge
    draw_quad(renderer, x1 - border, y0, x1, y1, color); // Right edge
}

draw_rectangle :: (renderer: *Renderer, corners: [4]s32, color: Color) {
    draw_quad(renderer, corners[0], corners[1], corners[2], corners[3], color);
}

draw_text_input :: (renderer: *Renderer, theme: *Theme, font: *Font, input: *Text_Input, prefix_string: string, x: s32, y: s32) {
    // Gather the actually input string
    input_string := get_string_view_from_text_input(input);
    prefix_string_width := query_text_width(font, prefix_string);    

    if input.selection_start != -1 {
        // There is currently an active selection. Render the selection background with a specific color
        // under the location where the selected text will be rendered later.
        selection_color := Color.{ 73, 149, 236, 255 };

        text_until_selection := substring_view(input.buffer, 0, input.selection_start);
        selection_text       := substring_view(input.buffer, input.selection_start, input.selection_end);
        text_after_selection := substring_view(input.buffer, input.selection_end, input.count);
        
        // Draw the actual selection background.
        selection_offset: s32 = query_text_width(font, text_until_selection); // @Cleanup apply kerning from the first char included in the selection to the last char before the selection
        selection_width:  s32 = query_text_width(font, selection_text);
        selection_start_x := x + prefix_string_width + selection_offset;
        selection_start_y := y - font.ascender;
        draw_quad(renderer, selection_start_x, selection_start_y, selection_start_x + selection_width, selection_start_y + font.line_height, selection_color);

        // Since the background color for the selected part of the input is different, we need to split the
        // text rendering in three parts and set the cursor accordingly.
        draw_text(renderer, font, text_until_selection, x + prefix_string_width, y, theme.colors[Color_Index.Default], theme.colors[Color_Index.Background]);
        draw_text(renderer, font, selection_text, x + prefix_string_width + selection_offset, y, theme.colors[Color_Index.Default], selection_color);
        draw_text(renderer, font, text_after_selection, x + prefix_string_width + selection_offset + selection_width, y, theme.colors[Color_Index.Default], theme.colors[Color_Index.Background]);
    } else
        // Render the complete input string without any selection
        draw_text(renderer, font, input_string, x + prefix_string_width, y, theme.colors[Color_Index.Default], theme.colors[Color_Index.Background]);
    
    // Render the string prefix
    draw_text(renderer, font, prefix_string, x, y, theme.colors[Color_Index.Accent], theme.colors[Color_Index.Background]);
    
    // Flush all text before rendering the cursor to make sure the cursor always gets rendered on top of the font
    flush_font_buffer(renderer);
    
    // Calculate the cursor size
    cursor_width:  s32 = query_text_width(font, "M");
    cursor_height: s32 = font.line_height;
    if input.cursor != input.count   cursor_width = 2; // If the cursor is in between characters, make it smaller so that it does not obscur any characters
    
    // Render the cursor if the text input is active
    cursor_color_raw := theme.colors[Color_Index.Cursor];
    cursor_color_blended := Color.{ cursor_color_raw.r, cursor_color_raw.g, cursor_color_raw.b, xx (input.cursor_alpha * 255) };

    cursor_x := x + prefix_string_width + xx input.cursor_interpolated_position;
    cursor_y := y - font.ascender;
    
    if !input.active {
        // If the text input is not active, render an outlined quad as the cursor
        draw_outlined_quad(renderer, cursor_x, cursor_y, cursor_x + cursor_width, cursor_y + cursor_height, 1, cursor_color_blended);
    } else
        // If the text input is active, render a filled quad
        draw_quad(renderer, cursor_x, cursor_y, cursor_x + cursor_width, cursor_y + cursor_height, cursor_color_blended);
}


/* Helper Procedures */


damp :: (from: f64, to: f64, lambda: f64, delta: f64) -> f64 {
    lerp := 1 - exp(-lambda * delta);    
    return to * lerp + from * (1 - lerp);
}


/* UI Callbacks */

convert_ui_color :: (ui: UI_Color) -> Color {
    return .{ ui.r, ui.g, ui.b, ui.a };
}

ui_draw_text :: (cmdx: *CmdX, text: string, position: UI_Vector2, foreground_color: UI_Color, background_color: UI_Color) {
    draw_text(*cmdx.renderer, *cmdx.font, text, xx position.x, xx position.y, convert_ui_color(foreground_color), convert_ui_color(background_color));
    flush_font_buffer(*cmdx.renderer); // Since the UI heavily relies upon scissors, rendering batches of text might not work correctly and cull some previous texts. For that reason, simply flush after every draw call.
}

ui_draw_quad :: (cmdx: *CmdX, color: UI_Color, rounding: f32, top_left: UI_Vector2, size: UI_Vector2) {
    draw_quad(*cmdx.renderer, xx top_left.x, xx top_left.y, xx (top_left.x + size.x), xx (top_left.y + size.y), convert_ui_color(color));
}

ui_set_scissors :: (cmdx: *CmdX, top_left: UI_Vector2, size: UI_Vector2) {
    set_scissors(xx top_left.x, xx top_left.y, xx size.x, xx size.y, cmdx.window.height);
}

ui_reset_scissors :: (cmdx: *CmdX) {
    disable_scissors();
}

ui_query_label_size :: (cmdx: *CmdX, text: string) -> UI_Vector2 {
    width, height := query_text_size(*cmdx.font, text);
    return .{ xx width, xx height };
}

ui_query_character_size :: (cmdx: *CmdX, character: u8) -> UI_Vector2 {
    width, height := query_glyph_size(*cmdx.font, character);
    return .{ xx width, xx height };    
}

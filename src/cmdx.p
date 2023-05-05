#load "basic.p";
#load "window.p";
#load "font.p";
#load "software_renderer.p";

font: Font;
window: Window;
framebuffer: Software_Render_Target;
texture_catalog: Software_Texture_Catalog;

main :: () -> s32 {
    create_window(*window, "cmdX", 1280, 720, WINDOW_DONT_CARE, WINDOW_DONT_CARE, false);
    allocate_software_render_target(*framebuffer, window.width, window.height, .BGRA);
    load_font(*font, 20, xx allocate_software_texture, xx *texture_catalog);
    
    while !window.should_close {
        update_window(*window);
        if window.resized   resize_software_render_target(*framebuffer, window.width, window.height);

        clear_software_render_target(*framebuffer, 20, 60, 100, 255);

        render_tinted_text_with_font(*font, "> Hello cmdX", 5, window.height - 5, .Left, 255, 255, 255, xx render_tinted_textured_quad, xx *framebuffer);

        blit_pixels_to_window(*window, framebuffer.pixels, framebuffer.width, framebuffer.height);
        
        Sleep(16);
    }

    destroy_software_texture_catalog(*texture_catalog);
    destroy_software_render_target(*framebuffer);
    destroy_window(*window);
    return 0;
}

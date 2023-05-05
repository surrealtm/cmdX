#load "basic.p";
#load "window.p";
#load "ui.p";

main :: () -> s32 {
    window: Window;
    create_window(*window, "cmdX", 1280, 720, WINDOW_DONT_CARE, WINDOW_DONT_CARE, false);

    while !window.should_close {
        update_window(*window);

        Sleep(16);
    }

    destroy_window(*window);
    return 0;
}

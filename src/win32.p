USE_PSEUDO_CONSOLE :: true;

// Struct copied from the windows terminal (src/wincopty/winconpty.h). The reference handle needs
// to be closed so that the communication pipes are actually broken when the child process terminates.
PseudoConsole :: struct {
    hSignal: HANDLE;
    hPtyReference: HANDLE;
    hConPtyProcess: HANDLE;
}

Win32 :: struct {
    // The pipes which are set as the std handles while the child process is running
    input_read_pipe:   HANDLE = xx INVALID_HANDLE_VALUE;
    input_write_pipe:  HANDLE = xx INVALID_HANDLE_VALUE;
    output_read_pipe:  HANDLE = xx INVALID_HANDLE_VALUE;
    output_write_pipe: HANDLE = xx INVALID_HANDLE_VALUE;
    child_closed_the_pipe: bool = false;

    // The actual pseudo console and the child handle.
    pseudo_console_handle: HPCON  = xx INVALID_HANDLE_VALUE;
    child_process_handle:  HANDLE = xx INVALID_HANDLE_VALUE;
    job_handle:            HANDLE = xx INVALID_HANDLE_VALUE;

    // Just a little helper required for closing the pseudo-console. See win32_drain_thread for details.
    drain_thread: HANDLE = xx INVALID_HANDLE_VALUE;

    previous_character_was_carriage_return: bool = false;
    time_of_last_module_name_update: s64 = 0; // Hardware time
}

// This little helper struct is used for parsing Virtual Terminal Sequences in the output read from
// the child process.
Win32_Input_Parser :: struct {
    cmdx: *CmdX;
    screen: *Screen;

    input: string;
    index: s64;

    parameters: [8]s32 = ---;
    parameter_count: u32;
}


win32_set_color_for_code :: (screen: *Screen, code: u32) {
    color: Color = ---;
    actually_change_color: bool = true;

    switch code {
        // Reset all attributes, reset foreground / background colors, reset foreground color
    case 0, 27, 39;
        set_themed_color(screen, .Default);
        actually_change_color = false;

        // Default foreground colors
    case 30; color = .{   0,   0,   0, 255 };
    case 31; color = .{ 255,   0,   0, 255 };
    case 32; color = .{   0, 255,   0, 255 };
    case 33; color = .{ 255, 255,   0, 255 };
    case 34; color = .{   0,   0, 255, 255 };
    case 35; color = .{ 255,   0, 255, 255 };
    case 36; color = .{   0, 255, 255, 255 };
    case 37; color = .{ 255, 255, 255, 255 };

        // Bright/Bold foreground colors
    case 90; color = .{  20,  20,  20, 255 };
    case 91; color = .{ 255,  20,  20, 255 };
    case 92; color = .{  20, 255,  20, 255 };
    case 93; color = .{ 255, 255,  20, 255 };
    case 94; color = .{  20,  20, 255, 255 };
    case 95; color = .{ 255,  20, 255, 255 };
    case 96; color = .{  20, 255, 255, 255 };
    case 97; color = .{ 255, 255, 255, 255 };

        // If the foreground color did not change (or we do not support that operation), don't do anything
    case; actually_change_color = false;
    }

    if actually_change_color set_true_color(screen, color);
}

win32_get_input_parser_parameter :: (parser: *Win32_Input_Parser, index: s64, default: s64) -> s64 {
    if index >= parser.parameter_count return default;
    return parser.parameters[index];
}

win32_maybe_process_carriage_return :: (parser: *Win32_Input_Parser) {
    if parser.index + 1 < parser.input.count && parser.input[parser.index] == 0x1b && (parser.input[parser.index + 1] == 0x5b || parser.input[parser.index + 1] == 0x5d) return; // If this is a special escape sequence, then ignore any carriage return thing. Sometimes windows put the \r before, and the corresponding \n after the escape sequence. Smh.

    if parser.input[parser.index] != '\n' && parser.screen.win32.previous_character_was_carriage_return {
        // If there was an \r character before this one, then effectively restart the line.
        set_cursor_position_to_beginning_of_line(parser.screen);
    }

    parser.screen.win32.previous_character_was_carriage_return = false;
}

win32_process_input_string :: (cmdx: *CmdX, screen: *Screen, input: string) {
    parser: Win32_Input_Parser = ---;
    parser.cmdx  = cmdx;
    parser.screen = screen;
    parser.input = input;
    parser.index = 0;

    while parser.index < parser.input.count {
        win32_maybe_process_carriage_return(*parser);

        if parser.index + 1 < parser.input.count && parser.input[parser.index] == 0x1b && parser.input[parser.index + 1] == 0x5b { // 0x1b is 'ESCAPE',0x5b is '['
            // Parse an escape sequence. An escape sequence is a number [0,n] of parameters,
            // seperated by semicolons, followed by the actual command string.
            parser.index += 2;
            parser.parameter_count = 0;

            while is_digit_character(parser.input[parser.index]) && parser.parameter_count < parser.parameters.count {
                // Parse a single integer parameter from the the input string.
                parameter_end, ignored := search_string_for_character_types(parser.input, ^.Digit, parser.index);
                value, valid := string_to_int(substring_view(parser.input, parser.index, parameter_end));
                parser.parameters[parser.parameter_count] = value;
                ++parser.parameter_count;
                parser.index = parameter_end;

                if parser.input[parser.index] == ';' ++parser.index; // Skip over a potential parameter seperator
            }

            command_end: s64 = ---;

            if parser.input[parser.index] == '?' {
                // If a question mark is the first character to read, it is followed by a numeric value and one
                // final character code.
                ignored: bool = ---;
                command_end, ignored = search_string_for_character_types(parser.input, ^.Digit, parser.index + 1);
                command_end += 1; // Include the actual character in the command name
            } else if parser.input[parser.index] == ' ' {
                // If the first character is a space, it will be followed by a 'q' and be used to define
                // the cursor shape.
                command_end = parser.index + 2;
            } else
                // Default command type; just one character.
                command_end = parser.index + 1;

            command := substring_view(parser.input, parser.index, command_end);
            parser.index = command_end;

            if compare_strings(command, "H") {
                // Position the cursor. If the cursor gets advanced by this, insert new-lines or spaces. If the
                // cursor reverts inside the current line, delete the part to the right of the line. We currently
                // do not support going backwards in the Y direction.
                y := win32_get_input_parser_parameter(*parser, 0, 1) - 1;
                x := win32_get_input_parser_parameter(*parser, 1, 1) - 1;

                vertical_offset := y - screen.viewport_height;
                cmdx_assert(screen, vertical_offset >= 0, "Invalid Cursor Position"); // For now, we do not support editing previous lines.
                for i := 0; i < vertical_offset; ++i   next_line(cmdx, screen);

                horizontal_offset := x - get_cursor_position_in_line(screen);

                if horizontal_offset > 0 {
                    // If the cursor moves to the right of the current cursor position, then
                    // just append spaces to the current text.
                    for i := 0; i < horizontal_offset; ++i add_character(cmdx, screen, ' ');
                } else if horizontal_offset < 0
                set_cursor_position_in_line(screen, x);
            } else if compare_strings(command, "C") {
                // Move the cursor to the right. Apparently this also produces white spaces while
                // moving the cursor, and unfortunately the C runtime makes use of this feature...
                count := win32_get_input_parser_parameter(*parser, 0, 1);
                for i := 0; i < count; ++i    add_character(cmdx, screen, ' ');
            } else if compare_strings(command, "m") {
                // Foreground color update
                color_code := win32_get_input_parser_parameter(*parser, 0, 0);
                win32_set_color_for_code(screen, color_code);
            } else {
                //print("Unhandled command: %\n", command);
            }
        } else if parser.index + 1 < parser.input.count && parser.input[parser.index] == 0x1b && parser.input[parser.index + 1] == 0x5d {
            // Window title, skip until the string terminator, which is marked as either
            // as 'ESCAPE' ']'  (0x1b, 0x5c), or as 'BEL' (0x7)
            parser.index += 2;
            while (parser.input[parser.index - 1] != 0x1b || parser.input[parser.index] != 0x5c) && parser.input[parser.index] != 0x7 {
                ++parser.index;
            }

            ++parser.index; // Skip over the final character which was the terminator
        } else if parser.input[parser.index] == '\r' {
            // Remember this character for later. If the next character is the \n one, then a new line will
            // be added. In that case, this character can effectively be ignored. If it is some other character,
            // then the line will be restarted. Since the \r character only makes sense in context with the
            // next character, and the next character may not be part of this string (if the child cut the buffer
            // after this character).
            screen.win32.previous_character_was_carriage_return = true;
            ++parser.index;
        } else if parser.input[parser.index] == '\n' {
            // Normal single new line character, not sure if that actually ever happens...
            next_line(cmdx, screen);
            ++parser.index;
        } else if parser.input[parser.index] == '\t' {
            // If the child outputted tabs, translate them to spaces for better consistency.
            for i := 0; i < 4; ++i add_character(cmdx, screen, ' ');
            ++parser.index;
        } else {
            add_character(cmdx, screen, parser.input[parser.index]);
            ++parser.index;
        }
    }
}

win32_read_from_child_process :: (cmdx: *CmdX, screen: *Screen) {
    if screen.win32.child_closed_the_pipe return;

    total_bytes_available: u32 = ---;

    if !PeekNamedPipe(screen.win32.output_read_pipe, null, 0, null, *total_bytes_available, null) {
        // If the pipe on the child side has been closed, PeekNamedPipe will fail. At this point, the
        // console connection should be terminated.
        screen.win32.child_closed_the_pipe = true;
        return;
    }

    if total_bytes_available == 0 return;

    input_buffer := allocate(*cmdx.frame_allocator, total_bytes_available);

    bytes_read: u32 = ---;

    if !ReadFile(screen.win32.output_read_pipe, input_buffer, total_bytes_available, *bytes_read, null) {
        // If this read fails, the child closed the pipe. This case should probably be covered by
        // the return value of PeekNamedPipe, but safe is safe.
        screen.win32.child_closed_the_pipe = true;
        return;
    }

    // There are 'total_bytes_available' to be read in the pipe. Since this is a byte
    // oriented pipe, The read input may not be aligned to the actual lines, but that
    // is handled fine by the input parser.
    string := string_view(xx input_buffer, bytes_read);
    win32_process_input_string(cmdx, screen, string);
}

win32_write_to_child_process :: (cmdx: *CmdX, screen: *Screen, data: string) {
    // Append a new line character to the data so that the child process recognizes a complete line was
    // input from the terminal, since the actual new line character obviously does not get added to the
    // text input.
    complete_buffer: *s8 = xx allocate(*cmdx.frame_allocator, data.count + 2);
    copy_memory(xx complete_buffer, xx data.data, data.count);
    complete_buffer[data.count + 0] = '\r';
    complete_buffer[data.count + 1] = '\n';

    // Write the actual line to the pipe
    if !WriteFile(screen.win32.input_write_pipe, xx complete_buffer, data.count + 1, null, null) {
        error_string := win32_last_error_to_string();
        add_formatted_line(cmdx, screen, "Failed to write to child process (Error: %).", error_string);
        win32_free_last_error_string(*error_string);
        screen.win32.child_closed_the_pipe = true;
        return;
    }

    // Flush the buffer so that the data is actually written into the pipe, and not just the internal
    // process buffer.
    FlushFileBuffers(screen.win32.input_write_pipe);
}

// This is another artifact showing the utter beauty of Win32. According to the docs (which does match the
// empirical experience), ClosePseudoConsole does not return until all data in the output pipe has been
// drained. Failing to do so will result in an infinite loop inside ClosePseudoConsole. This can happen if
// the child process outputs stuff in an endless for-loop.
// To fight this, when the pseudo console gets closed a new thread gets spawned that continously drains
// the output pipe until all cleanup has happened.
// Obviously spawning a thread to detach from the application is absolutely terrible, but this is the only
// solution that I have found...
//    - vmat 06.07.23
win32_drain_thread :: (screen: *Screen) -> u32 {
    input_buffer: [512]s8 = ---;

    while screen.child_process_running {
        if !ReadFile(screen.win32.output_read_pipe, input_buffer, input_buffer.count, null, null)
        // When ClosePseudoConsole has terminated, this pipe should be broken, at which point we are done.
        break;
    }

    return 0;
}

win32_cleanup :: (cmdx: *CmdX, screen: *Screen) {
    // Close the input pipe from us to the child process
    CloseHandle(screen.win32.input_write_pipe);

#if USE_PSEUDO_CONSOLE {
    // See the comment above win32_drain_thread for details on this fuckery.
    screen.win32.drain_thread = CreateThread(null, 0, win32_drain_thread, screen, 0, null);

    // Close the pseudo console. The pseudo console will only close when there is no more data to be read.
    ClosePseudoConsole(screen.win32.pseudo_console_handle);
    screen.win32.pseudo_console_handle = xx INVALID_HANDLE_VALUE;
}

    // After the data has been flushed, close the read pipe
    CloseHandle(screen.win32.output_read_pipe);

    screen.win32.input_write_pipe = xx INVALID_HANDLE_VALUE;
    screen.win32.output_read_pipe = xx INVALID_HANDLE_VALUE;

#if USE_PSEUDO_CONSOLE {
    // Close the drain thread handle, which should have terminated at this point due to a broken pipe.
    CloseHandle(screen.win32.drain_thread);
    screen.win32.drain_thread = xx INVALID_HANDLE_VALUE;
}

    // Close the job object
    CloseHandle(screen.win32.job_handle);
    screen.win32.job_handle = xx INVALID_HANDLE_VALUE;

    // Close the child process handles
    CloseHandle(screen.win32.child_process_handle);
    screen.win32.child_process_handle = xx INVALID_HANDLE_VALUE;

    // Set the internal state to be child-less
    screen.child_process_running = false;
    update_active_process_name(cmdx, screen, "");
}

win32_spawn_process_for_command :: (cmdx: *CmdX, command_string: string) -> bool {
    // Remember the currently active screen, as this command will be attached to that screen, even if the active
    // screen changes. We cannot directly use a pointer here, since that pointer might be invalidated if the
    // user creates new screens.

    screen := cmdx.active_screen;
    screen.win32 = .{}; // Reset the internal win32 state

    pipe_attributes: SECURITY_ATTRIBUTES;
    pipe_attributes.nLength = size_of(SECURITY_ATTRIBUTES);
    pipe_attributes.bInheritHandle = !USE_PSEUDO_CONSOLE;

    // Create a pipe to write input from this console to the child process
    if !CreatePipe(*screen.win32.input_read_pipe, *screen.win32.input_write_pipe, *pipe_attributes, 0) {
        add_formatted_line(cmdx, screen, "Failed to create an input pipe for the child process (Error: %).", GetLastError());
        win32_cleanup(cmdx, screen);
        return false;
    }

    // Create a pipe to read the output of the child process
    if !CreatePipe(*screen.win32.output_read_pipe, *screen.win32.output_write_pipe, *pipe_attributes, 0) {
        add_formatted_line(cmdx, screen, "Failed to create an output pipe for the child process (Error: %).", GetLastError());
        win32_cleanup(cmdx, screen);
        return false;
    }

#if USE_PSEUDO_CONSOLE {
    // Create the actual pseudo console, using the pipe handles that were just created.
    // Since the pseudo console apparently has no way of actually disabling the automatic
    // line wrapping, the size of this buffer is set to some ridiculous value, so that
    // essentially no line wrapping happens...
    console_size: COORD = ---;
    console_size.X = 1024;
    console_size.Y = 1000;
    error_code := CreatePseudoConsole(console_size, screen.win32.input_read_pipe, screen.win32.output_write_pipe, 0, *screen.win32.pseudo_console_handle);
    if error_code != S_OK {
        add_formatted_line(cmdx, screen, "Failed to create pseudo console for the child process (Error: %).", win32_hresult_to_string(error_code));
        win32_cleanup(cmdx, screen);
        return false;
    }
} #else {
    // If we are not using the pseudo console, then the child process must be allowed to actually inherit the
    // pipes which they should use for communication. Since the pipes were created without a security attribute,
    // they are not inheritable by default.
    if !SetHandleInformation(screen.win32.input_write_pipe, HANDLE_FLAG_INHERIT, 0) {
        error_string := win32_last_error_to_string();
        add_formatted_line(cmdx, screen, "Failed to set the input pipe as non-inheritable (Error: %).", error_string);
        win32_free_last_error_string(*error_string);
        win32_cleanup(cmdx, screen);
        return false;
    }

    if !SetHandleInformation(screen.win32.output_read_pipe, HANDLE_FLAG_INHERIT, 0) {
        error_string := win32_last_error_to_string();
        add_formatted_line(cmdx, screen, "Failed to set the output pipe as non-inheritable (Error: %).", error_string);
        win32_free_last_error_string(*error_string);
        win32_cleanup(cmdx, screen);
        return false;
    }
}

    // Before the actual child process can be launched, a job object needs to be created. This is done to ensure
    // that all child processes of the process we just launched also get terminated on a Ctrl+C event. Once
    // again, windows strikes with its perfect api without any flaws or inconviences, whatsoever.
    screen.win32.job_handle = CreateJobObjectA(null, null);
    job_info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION;
    job_info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(screen.win32.job_handle, 9, xx *job_info, size_of(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)); // 9 = JobObjectExtendedLimitInformation

    // Create the startup info for the child process.
    extended_startup_info: STARTUPINFOEX;
    extended_startup_info.StartupInfo.cb = size_of(STARTUPINFOEX);

#if USE_PSEUDO_CONSOLE {
    // Close the child side handles which are not needed anymore, since the pseudo-console now owns them.
    CloseHandle(screen.win32.input_read_pipe);
    CloseHandle(screen.win32.output_write_pipe);
    screen.win32.input_read_pipe   = xx INVALID_HANDLE_VALUE;
    screen.win32.output_write_pipe = xx INVALID_HANDLE_VALUE;

    // Create the attribute list. The attribute list is used to pass the actual console handle to the child process.
    attribute_list_count: u64 = 1;
    attribute_list_size: u64 = ---;
    InitializeProcThreadAttributeList(null, attribute_list_count, 0, *attribute_list_size);
    extended_startup_info.lpAttributeList = xx allocate(*cmdx.frame_allocator, attribute_list_size);

    if !InitializeProcThreadAttributeList(extended_startup_info.lpAttributeList, attribute_list_count, 0, *attribute_list_size) {
        add_formatted_line(cmdx, screen, "Failed to initialize the attribute list for the child process (Error: %).", GetLastError());
        win32_cleanup(cmdx, screen);
        return false;
    }

    if !UpdateProcThreadAttribute(extended_startup_info.lpAttributeList, 0, 0x20016, screen.win32.pseudo_console_handle, size_of(HPCON), null, null) { // 0x20016 = PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
        add_formatted_line(cmdx, screen, "Failed to set the pseudo console handle for the child process (Error: %).", GetLastError());
        win32_cleanup(cmdx, screen);
        return false;
    }
} #else {
    extended_startup_info.StartupInfo.dwFlags    = STARTF_USESTDHANDLES;
    extended_startup_info.StartupInfo.hStdInput  = screen.win32.input_read_pipe;
    extended_startup_info.StartupInfo.hStdOutput = screen.win32.output_write_pipe;
    extended_startup_info.StartupInfo.hStdError  = screen.win32.output_write_pipe;
}

    // The working directory of CmdX is NOT the 'current' directory (since CmdX needs to be relative to it's data
    // folder). However, when launching a process, Win32 takes the current directory as first possible path,
    // therefore we need to quickly change the working directory when doing that.
    c_current_directory := to_cstring(*cmdx.frame_allocator, screen.current_directory);
    c_command_string    := to_cstring(*cmdx.frame_allocator, command_string);

    // For some god-forsaken reason the working directory must be reset before the hPtyReference handle gets
    // closed, or else opening files won't work??? Thats why we cannot use defer here, and instead must do
    // this absolute tragedy... I do not even fucking know what the hell microsoft...
    //    - vmat 01.07.23
    previous_working_directory := get_working_directory();
    set_working_directory(screen.current_directory);

    creation_flags := EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED;
#if !USE_PSEUDO_CONSOLE creation_flags |= CREATE_NO_WINDOW; // If no pseudo console is used, then windows does not think there is a console attached to the subprocess and try to create a new console for it. Prevent that.

    // Launch the process with the attached information. The child process will inherit the current
    // std handles if it wants a console connection.
    process: PROCESS_INFORMATION;
    if !CreateProcessA(null, c_command_string, null, null, !USE_PSEUDO_CONSOLE, creation_flags, null, c_current_directory, *extended_startup_info.StartupInfo, *process) {
        error_string := win32_last_error_to_string();
        add_formatted_line(cmdx, screen, "Unknown command. Try :help to see a list of all available commands (Error: '%').", error_string);
        win32_free_last_error_string(*error_string);

#if USE_PSEUDO_CONSOLE        DeleteProcThreadAttributeList(extended_startup_info.lpAttributeList);
        
        set_working_directory(previous_working_directory);
        deallocate_string(Default_Allocator, *previous_working_directory);
        win32_cleanup(cmdx, screen);
        close_viewport(cmdx, screen);
        return false;
    }

    // Reset the working directory.
    set_working_directory(previous_working_directory);
    deallocate_string(Default_Allocator, *previous_working_directory);

#if USE_PSEUDO_CONSOLE {
    // Delete the proc thread attribute, since that is no longer needed after the process has been spawned
    DeleteProcThreadAttributeList(extended_startup_info.lpAttributeList);
}

    // Attach the launched process to our created job, so that all child processes of this process will also be
    // terminated. After that has been done, resume the thread to actually start the child process.
    AssignProcessToJobObject(screen.win32.job_handle, process.hProcess);
    ResumeThread(process.hThread);
    CloseHandle(process.hThread); // The thread handle is no longer needed

#if USE_PSEUDO_CONSOLE {
    // Close this handle here, so that the pseudo console automatically closes when the child
    // process terminates. This is a bit sketchy, since there does not seem to be an api for it,
    // but that is what the windows terminal does
    // (in src/cascadia/terminalconnection/contpyconnection.cpp), and it works, so yeah...
    pseudo_console: *PseudoConsole = cast(*PseudoConsole) screen.win32.pseudo_console_handle;
    if !CloseHandle(pseudo_console.hPtyReference) {
        error_string := win32_last_error_to_string();
        add_formatted_line(cmdx, screen, "Failed to close pseudo console reference handle (Error: %).", error_string);
        win32_free_last_error_string(*error_string);
    }

} #else {
    // Close the child side handles now, since the child has inherited and copied them.
    CloseHandle(screen.win32.input_read_pipe);
    CloseHandle(screen.win32.output_write_pipe);
    screen.win32.input_read_pipe   = xx INVALID_HANDLE_VALUE;
    screen.win32.output_write_pipe = xx INVALID_HANDLE_VALUE;
}

    // Prepare the cmdx internal state
    screen.child_process_running       = true;
    screen.win32.child_closed_the_pipe = false;
    screen.win32.child_process_handle  = process.hProcess;
    return true;
}

win32_detach_spawned_process :: (cmdx: *CmdX, screen: *Screen) {
    // Once the object has closed the pipes, Ctrl+C is no longer required to work. Therefore, reset
    // the job information. This is done to ensure that processes who have detached themselves from
    // us (which are not console applications) are not actually terminated here (they would be if the
    // flag is still set, and the handle to the job gets closed...)
    job_info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION;
    job_info.BasicLimitInformation.LimitFlags = 0;
    SetInformationJobObject(screen.win32.job_handle, 9, xx *job_info, size_of(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)); // 9 = JobObjectExtendedLimitInformation

    win32_cleanup(cmdx, screen);
    close_viewport(cmdx, screen);
}

win32_terminate_child_process :: (cmdx: *CmdX, screen: *Screen) {
    // If the user forcefully wants to terminate a process by using Ctrl+C, then do not just close the
    // connection, actually shut the process down.
    TerminateProcess(screen.win32.child_process_handle, 0);
    win32_cleanup(cmdx, screen);
    close_viewport(cmdx, screen);
}

win32_update_spawned_process :: (cmdx: *CmdX, screen: *Screen) -> bool {
    // If the spanwed process has closed the pipes, then it disconnected from this terminal and should
    // no longer be updated. If cmdx was terminated itself, then the connection should also be closed.
    if screen.win32.child_closed_the_pipe || cmdx.window.should_close return false;

    // Check if any data is available to be read in the pipe
    win32_read_from_child_process(cmdx, screen);

    current_time := get_hardware_time();

    if convert_hardware_time(current_time - screen.win32.time_of_last_module_name_update, .Milliseconds) > 500 {
        // Get the current process name and display that in the window title. Only check every once in a while
        // to prevent a lot of sys calls and / or unnecessary allocations.
        process_name: [MAX_PATH]u8 = ---;
        process_name_length := K32GetModuleBaseNameA(screen.win32.child_process_handle, null, process_name, MAX_PATH);
        update_active_process_name(cmdx, screen, string_view(process_name, process_name_length)); // @Cleanup only do this if the given screen is actually the active one
        screen.win32.time_of_last_module_name_update = current_time;
    }

    return true;
}

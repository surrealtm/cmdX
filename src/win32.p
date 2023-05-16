// Struct copied from the windows terminal (src/wincopty/winconpty.h). The reference handle needs
// to be closed so that the communication pipes are actually broken when the child process terminates.
PseudoConsole :: struct {
    hSignal: HANDLE;
    hPtyReference: HANDLE;
    hConPtyProcess: HANDLE;
}

Win32 :: struct {
    // The pipes which are set as the std handles while the child process is running
    input_read_pipe:   HANDLE;
    input_write_pipe:  HANDLE;
    output_read_pipe:  HANDLE;
    output_write_pipe: HANDLE;
    child_closed_the_pipe: bool;
    
    // The actual pseudo console and the child handle.
    pseudo_console_handle: HPCON;
    child_process_handle: HANDLE;
}

// This little helper struct is used for parsing Virtual Terminal Sequences in the output read from
// the child process.
Win32_Input_Parser :: struct {
    cmdx: *CmdX;
    
    input: string;
    index: s64;
    
    parameters: [8]u32;
    parameter_count: u32;
}

win32_get_color_for_code :: (cmdx: *CmdX, code: u32) -> Color {
    color: Color = ---;
    
    switch code {
        // Reset all attributes, reset foreground / background colors, reset foreground color
        case 0, 27, 39; color = cmdx.active_theme.font_color;
        
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
        
        // Reset to the default if no valid code mapping could be found
        case; color = cmdx.active_theme.font_color;
    }
    
    return color;
}

win32_find_sequence_command_end :: (parser: *Win32_Input_Parser) -> s64 {
    end := parser.index + 1;
    
    if parser.input[parser.index] == '?' {
        // If a question mark is the first character to read, it is followed by a numeric and one
        // final character code.
        end = search_string_for_character_types(parser.input, ^.Digit, parser.index + 1) + 1;
    } else if parser.input[parser.index] == ' ' {
        // If the first character is a space, it will be followed by a 'q' and be used to define
        // the cursor shape.
        end = parser.index + 2;
    }
    
    return end;
}

win32_get_input_parser_parameter :: (parser: *Win32_Input_Parser, index: s64, default: u32) -> u32 {
    if index >= parser.parameter_count return default;
    return parser.parameters[index];
}

win32_process_input_string :: (cmdx: *CmdX, input: string) {
    parser: Win32_Input_Parser = ---;
    parser.cmdx  = cmdx;
    parser.input = input;
    parser.index = 0;
    
    while parser.index < parser.input.count {
        if parser.input[parser.index] == 0x1b && parser.input[parser.index + 1] == 0x5b { // 0x1b is 'ESCAPE',0x5b is '['
            // Parse an escape sequence. An escape sequence is a number [0,n] of parameters,
            // seperated by semicolons, followed by the actual command string.
            parser.index += 2;
            parser.parameter_count = 0;
            
            while is_digit_character(parser.input[parser.index]) && parser.parameter_count < parser.parameters.count {
                parameter_end := search_string_for_character_types(parser.input, ^.Digit, parser.index);
                value, valid := string_to_int(substring(parser.input, parser.index, parameter_end));
                parser.parameters[parser.parameter_count] = value;
                ++parser.parameter_count;
                parser.index = parameter_end;
                
                if parser.input[parser.index] == ';' ++parser.index; // Skip over a potential parameter seperator
            }
            
            command_end := win32_find_sequence_command_end(*parser); // For now, only ever read one character. There are some sequences which have more than one character
            command := substring(parser.input, parser.index, command_end);
            parser.index = command_end;
            
            if compare_strings(command, "H") {
                // Position the cursor. We can only really advance the cursor forward, so make sure
                // that it only gets moved forward, either vertically (by inserting new lines), or
                // horizontally (by inserting spaces).
                y := win32_get_input_parser_parameter(*parser, 0, 1);
                x := win32_get_input_parser_parameter(*parser, 1, 1);
                
                // The horizontal offset is the defined X position minus the amount of characters 
                // in the current line (- 1, since X,Y are starting off at one, but the backlog starts
                // of at 0).
                horizontal_offset := x - (cmdx.backlog_end - cmdx.backlog_line_start) - 1;
                vertical_offset   := y - cmdx.viewport_height - 1;
                
                assert(vertical_offset > 0 || (vertical_offset == 0 && horizontal_offset >= 0), "Invalid Cursor Position");
                
                for i := 0; i < vertical_offset; ++i   new_line(cmdx);
                for i := 0; i < horizontal_offset; ++i add_character(cmdx, ' ');
            } else if compare_strings(command, "C") {
                // Move the cursor to the right. Apparently this also produces white spaces while
                // moving the cursor, and unfortunately the C runtime makes use of this feature...
                count := win32_get_input_parser_parameter(*parser, 0, 1);
                for i := 0; i < count; ++i    add_character(cmdx, ' ');
            } else if compare_strings(command, "m") {
                color_code := win32_get_input_parser_parameter(*parser, 0, 0);
                color := win32_get_color_for_code(cmdx, color_code);
                set_color(cmdx, color);
            } else {
                //print("Unhandled command: %\n", command);
            }
        } else if parser.input[parser.index] == 0x1b && parser.input[parser.index + 1] == 0x5d {
            // Window title, skip until the string terminator, which is marked as either
            // as 'ESCAPE' ']'  (0x1b, 0x5c), or as 'BEL' (0x7)
            parser.index += 2;
            while (parser.input[parser.index - 1] != 0x1b || parser.input[parser.index] != 0x5c) && parser.input[parser.index] != 0x7 {
                ++parser.index;
            }
            
            ++parser.index; // Skip over the final character which was the terminator
        } else if parser.input[parser.index] == '\r' {
            if parser.index < parser.input.count - 1 && parser.input[parser.index + 1] == '\n' {
                // If the next character is the actual new line character, then this acts just
                // as a normal new line...
                new_line(cmdx);
                parser.index += 2;
            } else {
                // If the next character is not the actual new line character, then just reset
                // the cursor to the beginning of the line. I do not understand why the C runtime
                // actually does this, but for some god forsaken reason I have to deal with it.
                reset_cursor(cmdx);
                ++parser.index;
            }
        } else if parser.input[parser.index] == '\n' {
            // Normal single new line character, not sure if that actually ever happens...
            new_line(cmdx);
            ++parser.index;
        } else if parser.input[parser.index] == '\t' {
            // If the child outputted tabs, translate them to spaces for better consistency.
            for i := 0; i < 4; ++i add_character(cmdx, ' ');
            ++parser.index;
        } else {
            // If this was just a normal character, skip it.
            add_character(cmdx, parser.input[parser.index]);
            ++parser.index;
        }
    }
}

win32_read_from_child_process :: (cmdx: *CmdX) {
    if cmdx.win32.child_closed_the_pipe return;
    
    total_bytes_available: u32 = ---;
    
    if !PeekNamedPipe(cmdx.win32.output_read_pipe, null, 0, null, *total_bytes_available, null) {
        // If the pipe on the child side has been closed, PeekNamedPipe will fail. At this point, the 
        // console connection should be terminated.
        cmdx.win32.child_closed_the_pipe = true;
        return;
    }
    
    if total_bytes_available == 0 return;
    
    input_buffer := allocate(*cmdx.frame_allocator, total_bytes_available);
    bytes_read: u32 = ---;
    
    if ReadFile(cmdx.win32.output_read_pipe, xx input_buffer, total_bytes_available, *bytes_read, null) {
        // There are 'total_bytes_available' to be read in the pipe. Since this is a byte 
        // oriented pipe, more than a single line may be read. However, since the client 
        // implementation (probably) only ever flushes after a new-line, the read buffer should 
        // always end on a new-line.
        string := string_view(xx input_buffer, bytes_read);
        win32_process_input_string(cmdx, string);
    } else
        // If this read fails, the child closed the pipe. This case should probably be covered by 
        // the return value of PeekNamedPipe, but safe is safe.
        cmdx.win32.child_closed_the_pipe = true;
}

win32_write_to_child_process :: (cmdx: *CmdX, data: string) {
    // Append a new line character to the data so that the child process recognizes a complete line was
    // input from the terminal, since the actual new line character obviously does not get added to the
    // text input.
    complete_buffer: *s8 = xx allocate(*cmdx.frame_allocator, data.count + 1);
    copy_memory(xx complete_buffer, xx data.data, data.count);
    complete_buffer[data.count] = 10;
    
    // Write the actual line to the pipe
    if !WriteFile(cmdx.win32.input_write_pipe, xx complete_buffer, data.count + 1, null, null) {
        print("Failed to write to child process :(\n");
        cmdx.win32.child_closed_the_pipe = true;
    }
    
    // Flush the buffer so that the data is actually written into the pipe, and not just the internal 
    // process buffer.
    FlushFileBuffers(cmdx.win32.input_write_pipe);
}

win32_terminate_child_process :: (cmdx: *CmdX) {
    TerminateProcess(cmdx.win32.child_process_handle, 0);
}

win32_spawn_process_for_command :: (cmdx: *CmdX, command_string: string) {
    // Save the actual working directory of cmdX to restore it later
    working_directory := get_working_directory();
    set_working_directory(cmdx.current_directory);
    
    // Set up c strings for file paths
    c_command_string := to_cstring(command_string, *cmdx.frame_allocator);
    c_current_directory := to_cstring(cmdx.current_directory, *cmdx.frame_allocator);
    
    // Create a pipe to read the output of the child process
    if !CreatePipe(*cmdx.win32.output_read_pipe, *cmdx.win32.output_write_pipe, null, 0) {
        add_formatted_line(cmdx, "Failed to create an output pipe for the child process (Error: %).", GetLastError());
    }
    
    // Create a pipe to write input from this console to the child process
    if !CreatePipe(*cmdx.win32.input_read_pipe, *cmdx.win32.input_write_pipe, null, 0) {
        add_formatted_line(cmdx, "Failed to create an input pipe for the child process (Error: %).", GetLastError()); 
    }
    
    // Create the actual pseudo console, using the pipe handles that were just created.
    // Since the pseudo console apparently has no way of actually disabling the automatic
    // line wrapping, the size of this buffer is set to some ridiculous value, so that
    // essentially no line wrapping happens...
    console_size: COORD;
    console_size.X = 512;
    console_size.Y = 512;
    error_code:= CreatePseudoConsole(console_size, cmdx.win32.input_read_pipe, cmdx.win32.output_write_pipe, 6, *cmdx.win32.pseudo_console_handle);
    if error_code!= S_OK {
        add_formatted_line(cmdx, "Failed to create pseudo console for the child process (Error: %).", win32_hresult_to_string(error_code));
    }
    
    pseudo_console: *PseudoConsole = cast(*PseudoConsole) cmdx.win32.pseudo_console_handle;
    
    // Close the child side handles which are not needed anymore
    CloseHandle(cmdx.win32.input_read_pipe);
    CloseHandle(cmdx.win32.output_write_pipe);
    cmdx.win32.input_read_pipe   = INVALID_HANDLE_VALUE;
    cmdx.win32.output_write_pipe = INVALID_HANDLE_VALUE;
    
    // Create the startup info for the child process.
    extended_startup_info: STARTUPINFOEX;
    extended_startup_info.StartupInfo.cb = size_of(STARTUPINFOEX);
    
    // Create the attribute list
    attribute_list_count: u64 = 1;
    attribute_list_size: u64 = ---;
    InitializeProcThreadAttributeList(null, attribute_list_count, 0, *attribute_list_size);
    extended_startup_info.lpAttributeList = xx allocate(*cmdx.frame_allocator, attribute_list_size);
    
    if !InitializeProcThreadAttributeList(extended_startup_info.lpAttributeList, attribute_list_count, 0, *attribute_list_size) {
        add_formatted_line(cmdx, "Failed to initialize the attribute list for the child process (Error: %).", GetLastError());
        return;
    }
    
    if !UpdateProcThreadAttribute(extended_startup_info.lpAttributeList, 0, 0x20016, cmdx.win32.pseudo_console_handle,
                                  size_of(HPCON), null, null) { // 0x20016 = PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
        add_formatted_line(cmdx, "Failed to set the pseudo console handle for the child process (Error: %).", GetLastError());
        return;
    }
    
    // Launch the process with the attached information. The child process will inherit the current 
    // std handles if it wants a console connection.
    process: PROCESS_INFORMATION;
    if !CreateProcessA(null, c_command_string, null, null, false, EXTENDED_STARTUPINFO_PRESENT, null, c_current_directory, *extended_startup_info.StartupInfo, *process) {
        add_formatted_line(cmdx, "Unknown command. Try :help to see a list of all available commands (Error: %).", GetLastError());
        cmdx.child_process_running = false;
        set_working_directory(working_directory);
        return;
    }
    
    // Close this handle here, so that the pseudo console automatically closes when the child
    // process terminates. This is a bit sketchy, since there does not seem to be an api for it,
    // but that is what the windows terminal does
    // (in src/cascadia/terminalconnection/contpyconnection.cpp), and it works, so yeah...
    CloseHandle(pseudo_console.hPtyReference);
    
    // Close the child end pipes from this side, since they have been duplicated and the parent does 
    // not need the handles.
    DeleteProcThreadAttributeList(extended_startup_info.lpAttributeList);
    
    // Prepare the cmdx internal state
    cmdx.child_process_running       = true;
    cmdx.win32.child_closed_the_pipe = false;
    cmdx.win32.child_process_handle  = process.hProcess;
    
    // Wait for the child process to close his side of the pipes, so that we know the console
    // connection can be terminated.
    while !cmdx.win32.child_closed_the_pipe && !cmdx.window.should_close {
        // Check if any data is available to be read in the pipe
        win32_read_from_child_process(cmdx);
        
        // Render a single frame while waiting for the process to terminate
        one_cmdx_frame(cmdx);
        
        // Get the current process name and display that in the window title
        process_name: [MAX_PATH]s8 = ---;
        process_name_length := K32GetModuleBaseNameA(process.hProcess, null, process_name, MAX_PATH);
        update_active_process_name(cmdx, make_string(process_name, process_name_length, *cmdx.global_allocator));
    }
    
    // Do one final read from the child process
    win32_read_from_child_process(cmdx);
    
    // Close all the parent side handles for the pipe ends, after the child process has terminated.
    CloseHandle(cmdx.win32.input_write_pipe);
    CloseHandle(cmdx.win32.output_read_pipe);
    cmdx.win32.input_write_pipe = INVALID_HANDLE_VALUE;
    cmdx.win32.output_read_pipe = INVALID_HANDLE_VALUE;
    
    // Close the actual pseudo console
    ClosePseudoConsole(cmdx.win32.pseudo_console_handle);
    
    // Close the process handles
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    cmdx.win32.child_process_handle = INVALID_HANDLE_VALUE;
    
    // Reset the cmdx status
    cmdx.child_process_running = false;
    update_active_process_name(cmdx, "");
    set_working_directory(working_directory);
}

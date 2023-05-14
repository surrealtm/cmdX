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
    
    pseudo_console_handle: HPCON;
    child_process_handle: HANDLE;
    
    incomplete_line: string; // If the last call to ReadFile() did end on a new-line character, the beginning of that line is saved until the next call to ReadFile(), so that the complete line can then be processed as one and sent to the backlog
}

win32_process_raw_line :: (cmdx: *CmdX, line: string) {
    // For now, simply forward the complete string to the output. Later on,
    // we want to parse the different virtual terminal sequences here, and
    // act upon them accordingly.
    cmdx_add_string(cmdx, line);
}

win32_read_from_child_process :: (cmdx: *CmdX) {
    if cmdx.win32.child_closed_the_pipe return;
    
    total_bytes_available: u32 = ---;
    
    if !PeekNamedPipe(cmdx.win32.output_read_pipe, null, 0, null, *total_bytes_available, null) {
        // If the pipe on the child side has been closed, PeekNamedPipe will fail. At this point, the console
        // connection should be terminated.
        cmdx.win32.child_closed_the_pipe = true;
        return;
    }
    
    if total_bytes_available == 0 return;
    
    input_buffer := allocate(*cmdx.frame_allocator, total_bytes_available);
    bytes_read: u32 = ---;
    
    if ReadFile(cmdx.win32.output_read_pipe, xx input_buffer, total_bytes_available, *bytes_read, null) {
        // There are 'total_bytes_available' to be read in the pipe. Since this is a byte oriented pipe, more than
        // a single line may be read. However, since the client implementation (probably) only ever flushes after
        // a new-line, the read buffer should always end on a new-line.
        string := string_view(xx input_buffer, bytes_read);
        line_break := search_string(string, 10);
        while line_break != -1 {
            line := substring(string, 0, line_break);
            
            if cmdx.win32.incomplete_line.count {
                line = concatenate_strings(cmdx.win32.incomplete_line, line, *cmdx.frame_allocator);
                free_string(cmdx.win32.incomplete_line, *cmdx.global_allocator);
                cmdx.win32.incomplete_line = "";
            }
            
            win32_process_raw_line(cmdx, line);
            
            string = substring(string, line_break + 1, string.count);
            line_break = search_string(string, 10);
        }
        
        if string.count
            cmdx.win32.incomplete_line = concatenate_strings(cmdx.win32.incomplete_line, string, *cmdx.global_allocator);
    } else
        // If this read fails, the child closed the pipe. This case should probably be covered by the return value
        // of PeekNamedPipe, but safe is safe.
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
    
    // Flush the buffer so that the data is actually written into the pipe, and not just the internal process
    // buffer.
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
        cmdx_print_string(cmdx, "Failed to create an output pipe for the child process (Error: %).", GetLastError());
    }
    
    // Create a pipe to write input from this console to the child process
    if !CreatePipe(*cmdx.win32.input_read_pipe, *cmdx.win32.input_write_pipe, null, 0) {
        cmdx_print_string(cmdx, "Failed to create an input pipe for the child process (Error: %).", GetLastError()); 
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
        cmdx_print_string(cmdx, "Failed to create pseudo console for the child process (Error: %).", win32_hresult_to_string(error_code));
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
        cmdx_print_string(cmdx, "Failed to initialize the attribute list for the child process (Error: %).", GetLastError());
        return;
    }
    
    if !UpdateProcThreadAttribute(extended_startup_info.lpAttributeList, 0, 0x20016, cmdx.win32.pseudo_console_handle,
                                  size_of(HPCON), null, null) { // 0x20016 = PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
        cmdx_print_string(cmdx, "Failed to set the pseudo console handle for the child process (Error: %).", GetLastError());
        return;
    }
    
    // Launch the process with the attached information. The child process will inherit the current 
    // std handles if it wants a console connection.
    process: PROCESS_INFORMATION;
    if !CreateProcessA(null, c_command_string, null, null, false, EXTENDED_STARTUPINFO_PRESENT, null, c_current_directory, *extended_startup_info.StartupInfo, *process) {
        cmdx_print_string(cmdx, "Unknown command. Try :help to see a list of all available commands (Error: %).", GetLastError());
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
    cmdx.win32.incomplete_line       = copy_string("", *cmdx.global_allocator);
    
    // Wait for the child process to close his side of the pipes, so that we know the console
    // connection can be terminated.
    while !cmdx.win32.child_closed_the_pipe && !cmdx.window.should_close {
        // Check if any data is available to be read in the pipe
        win32_read_from_child_process(cmdx);
        
        // Render a single frame while waiting for the process to terminate
        single_cmdx_frame(cmdx);
        
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

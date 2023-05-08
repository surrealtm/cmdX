PIPE_BUFFER_SIZE :: 1024;

PIPE_NAME: cstring : "\\\\.\\Pipe\\cmdx";

Win32_Pipes :: struct {
    // The pipes which are set as the std handles while the child process is running
    input_read_pipe: HANDLE;
    input_write_pipe: HANDLE;
    output_read_pipe: HANDLE;
    output_write_pipe: HANDLE;
    child_closed_the_pipe: bool;

    // The actual std handles for cmdx, restored after the child process has shut down again
    my_output_handle: HANDLE;
    my_error_handle: HANDLE;
    my_input_handle: HANDLE;
}

create_win32_pipes :: (cmdx: *CmdX) {
    cmdx.win32_pipes.child_closed_the_pipe = false;

    security_attributes: SECURITY_ATTRIBUTES;
    security_attributes.nLength = size_of(SECURITY_ATTRIBUTES);
    security_attributes.bInheritHandle = true;
    security_attributes.lpSecurityDescriptor = null; 

    // Create a pipe to read the output of the child process
    if !CreatePipe(*cmdx.win32_pipes.output_read_pipe, *cmdx.win32_pipes.output_write_pipe, *security_attributes, 0) {
        cmdx_print(cmdx, "Failed to create an output pipe for the child process (Error: %).", GetLastError());
    }

    // Do not inherit my side of the pipe
    if !SetHandleInformation(cmdx.win32_pipes.output_read_pipe, HANDLE_FLAG_INHERIT, 0) {
        cmdx_print(cmdx, "Failed to set the output pipe handle information for the child process (Error: %).", GetLastError());
    }

    // Create a pipe to write input from this console to the child process
    if !CreatePipe(*cmdx.win32_pipes.input_read_pipe, *cmdx.win32_pipes.input_write_pipe, *security_attributes, 0) {
        cmdx_print(cmdx, "Failed to create an input pipe for the child process (Error: %).", GetLastError()); 
    }

    // Do not inherit my side of the pipe
    if !SetHandleInformation(cmdx.win32_pipes.input_write_pipe, HANDLE_FLAG_INHERIT, 0) {
        cmdx_print(cmdx, "Failed to set the input pipe handle information for the child process (Error: %).", GetLastError());
    }

    cmdx.win32_pipes.my_output_handle = GetStdHandle(STD_OUTPUT_HANDLE);
    cmdx.win32_pipes.my_error_handle  = GetStdHandle(STD_ERROR_HANDLE);
    cmdx.win32_pipes.my_input_handle  = GetStdHandle(STD_INPUT_HANDLE);
    
    SetStdHandle(STD_OUTPUT_HANDLE, cmdx.win32_pipes.output_write_pipe);
    SetStdHandle(STD_ERROR_HANDLE, cmdx.win32_pipes.output_write_pipe);
    SetStdHandle(STD_INPUT_HANDLE, cmdx.win32_pipes.input_read_pipe);
}

destroy_child_side_win32_pipes :: (cmdx: *CmdX) {
    CloseHandle(cmdx.win32_pipes.input_read_pipe);
    CloseHandle(cmdx.win32_pipes.output_write_pipe);
    cmdx.win32_pipes.input_read_pipe   = INVALID_HANDLE_VALUE;
    cmdx.win32_pipes.output_write_pipe = INVALID_HANDLE_VALUE;
}

destroy_parent_side_win32_pipes :: (cmdx: *CmdX) {
    CloseHandle(cmdx.win32_pipes.input_write_pipe);
    CloseHandle(cmdx.win32_pipes.output_read_pipe);
    cmdx.win32_pipes.input_write_pipe = INVALID_HANDLE_VALUE;
    cmdx.win32_pipes.output_read_pipe = INVALID_HANDLE_VALUE;

    SetStdHandle(STD_OUTPUT_HANDLE, cmdx.win32_pipes.my_output_handle);
    SetStdHandle(STD_ERROR_HANDLE, cmdx.win32_pipes.my_error_handle);
    SetStdHandle(STD_INPUT_HANDLE, cmdx.win32_pipes.my_input_handle);
}

try_reading_from_child_process :: (cmdx: *CmdX) {
    if cmdx.win32_pipes.child_closed_the_pipe return;
    
    total_bytes_available: u32 = ---;
    
    if !PeekNamedPipe(cmdx.win32_pipes.output_read_pipe, null, 0, null, *total_bytes_available, null) {
        // If the pipe on the child side has been closed, PeekNamedPipe will fail. At this point, the console
        // connection should be terminated.
        cmdx.win32_pipes.child_closed_the_pipe = true;
        return;
    }
        
    if total_bytes_available == 0 return;

    input_buffer := allocate(*cmdx.frame_allocator, total_bytes_available);
    bytes_read: u32 = ---;

    if ReadFile(cmdx.win32_pipes.output_read_pipe, xx input_buffer, total_bytes_available, *bytes_read, null) {
        // There are 'total_bytes_available' to be read in the pipe. Since this is a byte oriented pipe, more than
        // a single line may be read. However, since the client implementation (probably) only ever flushes after
        // a new-line, the read buffer should always end on a new-line.
        string := string_view(xx input_buffer, bytes_read);
        line_break := search_string(string, 10);
        while line_break != -1 {
            line := substring(string, 0, line_break);
            if line[line.count - 1] == 13   --line.count; // Cut the \r character
            
            add_string_to_backlog(cmdx, line);
            string = substring(string, line_break + 1, string.count);
            line_break = search_string(string, 10);
        }

        assert(string.count == 0, "String read from child process did not end with a new_line (as expected).");
    } else
        // If this read fails, the child closed the pipe. This case should probably be covered by the return value
        // of PeekNamedPipe, but safe is safe.
        cmdx.win32_pipes.child_closed_the_pipe = true;
}

try_writing_to_child_process :: (cmdx: *CmdX, data: string) {
    // Write the actual line to the pipe
    if !WriteFile(cmdx.win32_pipes.input_write_pipe, xx data.data, data.count, null, null) {
        print("Failed to write to child process :(\n");
        cmdx.win32_pipes.child_closed_the_pipe = true;
    }

    new_line := "\n";
    
    // Append a new line to the pipe, since the user has finished his line of input
    if !WriteFile(cmdx.win32_pipes.input_write_pipe, xx new_line.data, new_line.count, null, null) {
        print("Failed to write to child process :(\n");
        cmdx.win32_pipes.child_closed_the_pipe = true;
    }
    
    // Flush the buffer so that the data is actually written into the pipe, and not just the internal process buffer.
    FlushFileBuffers(cmdx.win32_pipes.input_write_pipe);
}

try_spawn_process_for_command :: (cmdx: *CmdX, command_name: string) {
    // Create a new pipe for this child process
    create_win32_pipes(cmdx);

    // Set up c strings for file paths
    c_command_name := to_cstring(command_name, *cmdx.frame_allocator);
    c_current_directory := to_cstring(cmdx.current_directory, *cmdx.frame_allocator);
    
    // Spawn the actual process
    startup_info: STARTUPINFO;
    startup_info.cb = size_of(STARTUPINFO);

    process: PROCESS_INFORMATION;

    // Actually create the process. If the process requests a console, it will take the std handles of this process here,
    // which are set to be the pipes.
    result := CreateProcessA(null, c_command_name, null, null, false, 0, null, c_current_directory, *startup_info, *process);
    if !result {
        cmdx_print(cmdx, "Unknown command. Try :help to see a list of all available commands.");
        return;
    }

    // Close the child end pipes from this side, since they have been duplicated and the parent does not
    // need the handles.
    destroy_child_side_win32_pipes(cmdx);
    
    // Wait for the child process to terminate
    while !cmdx.win32_pipes.child_closed_the_pipe && !cmdx.window.should_close { // 0 is WAIT_OBJECT_0
        // Check if any data is available to be read in the pipe
        try_reading_from_child_process(cmdx);
        
        // Render a single frame while waiting for the process to terminate
        single_cmdx_frame(cmdx);

        // Handle potential input from the terminal to the child process
        if cmdx.text_input.entered {
            // The user has entered a string, add that to the backlog, clear the input and actually run
            // the command.
            input_string := get_string_view_from_text_input(*cmdx.text_input);
            clear_text_input(*cmdx.text_input);
            activate_text_input(*cmdx.text_input);

            try_writing_to_child_process(cmdx, input_string);
        }
        
        // Get the current process name and display that in the window title
        if cmdx.current_child_process_name.count   free_string(cmdx.current_child_process_name, *cmdx.global_allocator);

        process_name: [MAX_PATH]s8 = ---;
        process_name_length := K32GetModuleBaseNameA(process.hProcess, null, process_name, MAX_PATH);
        cmdx.current_child_process_name = make_string(process_name, process_name_length, *cmdx.global_allocator);
        update_window_name(cmdx);
    }
    
    // Do one final read from the child process
    try_reading_from_child_process(cmdx);

    // Close all handles
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    destroy_parent_side_win32_pipes(cmdx);
    
    // Clear the current process name
    free_string(cmdx.current_child_process_name, *cmdx.global_allocator);
    cmdx.current_child_process_name = "";
    update_window_name(cmdx);
}

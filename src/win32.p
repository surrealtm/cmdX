PIPE_BUFFER_SIZE :: 1024;

PIPE_NAME: cstring : "\\\\.\\Pipe\\cmdx";

Win32_Pipes :: struct {
    child_pipe_input_read: HANDLE;
    child_pipe_input_write: HANDLE;
    child_pipe_output_read: HANDLE;
    child_pipe_output_write: HANDLE;
    child_closed_the_pipe: bool;
}

create_win32_pipes :: (cmdx: *CmdX, pipes: *Win32_Pipes) {
    pipes.child_closed_the_pipe = false;

    security_attributes: SECURITY_ATTRIBUTES;
    security_attributes.nLength = size_of(SECURITY_ATTRIBUTES);
    security_attributes.bInheritHandle = true;
    security_attributes.lpSecurityDescriptor = null; 

    if !CreatePipe(*pipes.child_pipe_output_read, *pipes.child_pipe_output_write, *security_attributes, 0) {
        cmdx_print(cmdx, "Failed to create an output pipe for the child process (Error: %).", GetLastError());
    }
    
    if !SetHandleInformation(pipes.child_pipe_output_read, HANDLE_FLAG_INHERIT, 0) {
        cmdx_print(cmdx, "Failed to set the output pipe handle information for the child process (Error: %).", GetLastError());
    }

    if !CreatePipe(*pipes.child_pipe_input_read, *pipes.child_pipe_input_write, *security_attributes, 0) {
        cmdx_print(cmdx, "Failed to create an input pipe for the child process (Error: %).", GetLastError()); 
    }

    if !SetHandleInformation(pipes.child_pipe_input_write, HANDLE_FLAG_INHERIT, 0) {
        cmdx_print(cmdx, "Failed to set the input pipe handle information for the child process (Error: %).", GetLastError());
    }
}

destroy_incoming_win32_pipes :: (pipes: *Win32_Pipes) {
    CloseHandle(pipes.child_pipe_input_read);
    CloseHandle(pipes.child_pipe_output_write);
    pipes.child_pipe_input_read   = INVALID_HANDLE_VALUE;
    pipes.child_pipe_output_write = INVALID_HANDLE_VALUE;
}

destroy_win32_pipes :: (pipes: *Win32_Pipes) {
    destroy_incoming_win32_pipes(pipes);
    CloseHandle(pipes.child_pipe_input_write);
    CloseHandle(pipes.child_pipe_output_read);
    pipes.child_pipe_input_write = INVALID_HANDLE_VALUE;
    pipes.child_pipe_output_read = INVALID_HANDLE_VALUE;
}

try_reading_from_child_process :: (cmdx: *CmdX) {
    if cmdx.win32_pipes.child_closed_the_pipe return;

    total_bytes_available: u32 = ---;
    
    if !PeekNamedPipe(cmdx.win32_pipes.child_pipe_output_read, null, 0, null, *total_bytes_available, null) {
        cmdx.win32_pipes.child_closed_the_pipe = true;
        return;
    }
        
    if total_bytes_available == 0 return;

    input_buffer := allocate(*cmdx.frame_allocator, total_bytes_available);
    bytes_read: u32 = ---;

    if ReadFile(cmdx.win32_pipes.child_pipe_output_read, xx input_buffer, total_bytes_available, *bytes_read, null) {
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
        cmdx.win32_pipes.child_closed_the_pipe = true;
}

try_spawn_process_for_command :: (cmdx: *CmdX, command_name: string) {
    // Prepare the platform pipes
    create_win32_pipes(cmdx, *cmdx.win32_pipes);
    
    // Set up c strings for file paths
    c_command_name := to_cstring(command_name, *cmdx.frame_allocator);
    c_current_directory := to_cstring(cmdx.current_directory, *cmdx.frame_allocator);

    // Spawn the actual process
    startup_info: STARTUPINFO;
    startup_info.cb         = size_of(STARTUPINFO);
    startup_info.dwFlags    = STARTF_USESTDHANDLES;
    startup_info.hStdInput  = cmdx.win32_pipes.child_pipe_input_read;
    startup_info.hStdOutput = cmdx.win32_pipes.child_pipe_output_write;
    startup_info.hStdError  = cmdx.win32_pipes.child_pipe_output_write;

    process: PROCESS_INFORMATION;
    
    result := CreateProcessA(null, c_command_name, null, null, true, 0, null, c_current_directory, *startup_info, *process);
    if !result {
        cmdx_print(cmdx, "Unknown command. Try :help to see a list of all available commands.");
        return;
    }

    destroy_incoming_win32_pipes(*cmdx.win32_pipes);
    
    // Wait for the child process to terminate
    while WaitForSingleObject(process.hProcess, 0) != 0 && !cmdx.win32_pipes.child_closed_the_pipe && !cmdx.window.should_close { // 0 is WAIT_OBJECT_0
        // Check if any data is available to be read in the pipe
        try_reading_from_child_process(cmdx);
        
        // Render a single frame while waiting for the process to terminate
        single_cmdx_frame(cmdx);
        
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

    destroy_win32_pipes(*cmdx.win32_pipes);
    
    // Clear the current process name
    free_string(cmdx.current_child_process_name, *cmdx.global_allocator);
    cmdx.current_child_process_name = "";
    update_window_name(cmdx);
}

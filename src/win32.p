PIPE_BUFFER_SIZE :: 1024;

PIPE_NAME: cstring : "\\\\.\\Pipe\\cmdx";

Win32 :: struct {
    child_pipe_output_read: HANDLE;
    child_pipe_output_write: HANDLE;
    child_pipe_output_overlapped: OVERLAPPED;
}

create_win32 :: (cmdx: *CmdX) {
    // Create the pipes for communication between this terminal and the child process

    /*
    cmdx.platform_data.child_pipe_output_read = CreateNamedPipeA(PIPE_NAME,
                                                                 PIPE_ACCESS_INBOUND | GENERIC_READ,
                                                                 PIPE_TYPE_BYTE | PIPE_WAIT,
                                                                 1,
                                                                 PIPE_BUFFER_SIZE,
                                                                 PIPE_BUFFER_SIZE,
                                                                 0,
                                                                 null);

    if cmdx.platform_data.child_pipe_output_read == INVALID_HANDLE_VALUE {
        cmdx_print(cmdx, "Failed to create a named pipe for the child process (Error: %).", GetLastError());
        return;
    }

    cmdx.platform_data.child_pipe_output_write = CreateFileA(PIPE_NAME,
                                                             GENERIC_WRITE,
                                                             0,
                                                             null,
                                                             OPEN_EXISTING,
                                                             0,
                                                             null);

    if cmdx.platform_data.child_pipe_output_write == INVALID_HANDLE_VALUE {
        cmdx_print(cmdx, "Failed to create a file for the named pipe for the child process (Error: %).", GetLastError());
        CloseHandle(cmdx.platform_data.child_pipe_output_read);
        cmdx.platform_data.child_pipe_output_read = INVALID_HANDLE_VALUE;
    }
*/

    security_attributes: SECURITY_ATTRIBUTES;
    security_attributes.nLength = size_of(SECURITY_ATTRIBUTES);
    security_attributes.bInheritHandle = true;
    security_attributes.lpSecurityDescriptor = null; 

    if !CreatePipe(*cmdx.platform_data.child_pipe_output_read, *cmdx.platform_data.child_pipe_output_write, *security_attributes, 0) {
        cmdx_print(cmdx, "Failed to create a pipe for the child process (Error: %).", GetLastError());
    }
    
    if !SetHandleInformation(cmdx.platform_data.child_pipe_output_read, HANDLE_FLAG_INHERIT, 0) {
        cmdx_print(cmdx, "Failed to set the pipe handle information for the child process (Error: %).", GetLastError());
    }
}

destroy_win32 :: (cmdx: *CmdX) {
    CloseHandle(cmdx.platform_data.child_pipe_output_write);
    CloseHandle(cmdx.platform_data.child_pipe_output_read);
    cmdx.platform_data.child_pipe_output_write = INVALID_HANDLE_VALUE;    
    cmdx.platform_data.child_pipe_output_read  = INVALID_HANDLE_VALUE;
}

try_reading_from_child_process :: (cmdx: *CmdX) {
    total_bytes_available: u32 = ---;
    
    if PeekNamedPipe(cmdx.platform_data.child_pipe_output_read, null, 0, null, *total_bytes_available, null) && total_bytes_available > 0 {
        input_buffer := allocate(*cmdx.frame_allocator, total_bytes_available);
        bytes_read: u32 = ---;

        if ReadFile(cmdx.platform_data.child_pipe_output_read, xx input_buffer, total_bytes_available, *bytes_read, null) {
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
        }
    }
}

try_spawn_process_for_command :: (cmdx: *CmdX, command_name: string) {
    // Set up c strings for file paths
    c_command_name := to_cstring(command_name, *cmdx.frame_allocator);
    c_current_directory := to_cstring(cmdx.current_directory, *cmdx.frame_allocator);

    // Spawn the actual process
    startup_info: STARTUPINFO;
    startup_info.cb         = size_of(STARTUPINFO);
    startup_info.dwFlags    = STARTF_USESTDHANDLES;
    startup_info.hStdInput  = GetStdHandle(STD_INPUT_HANDLE);
    startup_info.hStdOutput = cmdx.platform_data.child_pipe_output_write;
    startup_info.hStdError  = cmdx.platform_data.child_pipe_output_write;

    process: PROCESS_INFORMATION;
    
    result := CreateProcessA(null, c_command_name, null, null, true, 0, null, c_current_directory, *startup_info, *process);
    if !result {
        cmdx_print(cmdx, "Unknown command. Try :help to see a list of all available commands.");
        return;
    }
        
    // Wait for the child process to terminate
    while WaitForSingleObject(process.hProcess, 0) != 0 && !cmdx.window.should_close { // 0 is WAIT_OBJECT_0
        // Check if any data is available to be read in the pipe
        try_reading_from_child_process(cmdx);
        
        // Render a single frame while waiting for the process to terminate
        single_cmdx_frame(cmdx);
        
        // Get the current process name and display that in the window title
        free_string(cmdx.current_child_process_name, *cmdx.global_allocator);

        process_name: [MAX_PATH]s8 = ---;
        process_name_length := K32GetModuleBaseNameA(process.hProcess, null, process_name, MAX_PATH);
        cmdx.current_child_process_name = make_string(process_name, process_name_length, *cmdx.global_allocator);
        update_window_name(cmdx);
    }

    // Do one final read from the child process
    try_reading_from_child_process(cmdx);
    
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
}

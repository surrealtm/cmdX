Win32 :: struct {
    // The pipes which are set as the std handles while the child process is running
    input_read_pipe:   HANDLE;
    input_write_pipe:  HANDLE;
    output_read_pipe:  HANDLE;
    output_write_pipe: HANDLE;
    child_closed_the_pipe: bool;
    
    // The actual std handles for cmdx, restored after the child process has shut down again
    my_output_handle: HANDLE;
    my_error_handle:  HANDLE;
    my_input_handle:  HANDLE;
    
    child_process_handle: HANDLE;
}

create_win32_pipes :: (cmdx: *CmdX) {
    cmdx.win32.child_closed_the_pipe = false;
    
    security_attributes: SECURITY_ATTRIBUTES;
    security_attributes.nLength = size_of(SECURITY_ATTRIBUTES);
    security_attributes.bInheritHandle = true;
    security_attributes.lpSecurityDescriptor = null; 
    
    // Create a pipe to read the output of the child process
    if !CreatePipe(*cmdx.win32.output_read_pipe, *cmdx.win32.output_write_pipe, *security_attributes, 0) {
        cmdx_print_string(cmdx, "Failed to create an output pipe for the child process (Error: %).", GetLastError());
    }
    
    // Do not inherit my side of the pipe
    if !SetHandleInformation(cmdx.win32.output_read_pipe, HANDLE_FLAG_INHERIT, 0) {
        cmdx_print_string(cmdx, "Failed to set the output pipe handle information for the child process (Error: %).", GetLastError());
    }
    
    // Create a pipe to write input from this console to the child process
    if !CreatePipe(*cmdx.win32.input_read_pipe, *cmdx.win32.input_write_pipe, *security_attributes, 0) {
        cmdx_print_string(cmdx, "Failed to create an input pipe for the child process (Error: %).", GetLastError()); 
    }
    
    // Do not inherit my side of the pipe
    if !SetHandleInformation(cmdx.win32.input_write_pipe, HANDLE_FLAG_INHERIT, 0) {
        cmdx_print_string(cmdx, "Failed to set the input pipe handle information for the child process (Error: %).", GetLastError());
    }
    
    // Save the std handles for cmdx itself, so they can be restored alter
    cmdx.win32.my_output_handle = GetStdHandle(STD_OUTPUT_HANDLE);
    cmdx.win32.my_error_handle  = GetStdHandle(STD_ERROR_HANDLE);
    cmdx.win32.my_input_handle  = GetStdHandle(STD_INPUT_HANDLE);
    
    // Set the actual std handles to be forwarded to the pseudo console, so that the child
    // process inherits and uses these.
    SetStdHandle(STD_OUTPUT_HANDLE, cmdx.win32.output_write_pipe);
    SetStdHandle(STD_ERROR_HANDLE, cmdx.win32.output_write_pipe);
    SetStdHandle(STD_INPUT_HANDLE, cmdx.win32.input_read_pipe);
}

destroy_child_side_win32_pipes :: (cmdx: *CmdX) {
    CloseHandle(cmdx.win32.input_read_pipe);
    CloseHandle(cmdx.win32.output_write_pipe);

    cmdx.win32.input_read_pipe   = INVALID_HANDLE_VALUE;
    cmdx.win32.output_write_pipe = INVALID_HANDLE_VALUE;

    // Reset the std handles to the previous handles which cmdx was launched with, so that
    // the normal print() behaviour is restored.
    SetStdHandle(STD_OUTPUT_HANDLE, cmdx.win32.my_output_handle);
    SetStdHandle(STD_ERROR_HANDLE, cmdx.win32.my_error_handle);
    SetStdHandle(STD_INPUT_HANDLE, cmdx.win32.my_input_handle);
}

destroy_parent_side_win32_pipes :: (cmdx: *CmdX) {
    CloseHandle(cmdx.win32.input_write_pipe);
    CloseHandle(cmdx.win32.output_read_pipe);
    
    cmdx.win32.input_write_pipe = INVALID_HANDLE_VALUE;
    cmdx.win32.output_read_pipe = INVALID_HANDLE_VALUE;
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
            if line[line.count - 1] == 13   --line.count; // Cut the \r character
            
            cmdx_add_string(cmdx, line);
            string = substring(string, line_break + 1, string.count);
            line_break = search_string(string, 10);
        }
        
        //assert(string.count == 0, "String read from child process did not end with a new_line (as expected).");
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
    // Create a new pipe for this child process
    create_win32_pipes(cmdx);
    
    // Save the actual working directory of cmdX to restore it later
    working_directory := get_working_directory();
    set_working_directory(cmdx.current_directory);
    
    // Set up c strings for file paths
    c_command_string := to_cstring(command_string, *cmdx.frame_allocator);
    c_current_directory := to_cstring(cmdx.current_directory, *cmdx.frame_allocator);
    
    // Create the startup info for the child process.
    extended_startup_info: STARTUPINFOEX;
    extended_startup_info.StartupInfo.cb = size_of(STARTUPINFOEX);

    // Launch the process with the attached information. The child process will inherit the current std handles,
    // if it wants a console connection.
    process: PROCESS_INFORMATION;
    result := CreateProcessA(null, c_command_string, null, null, false, EXTENDED_STARTUPINFO_PRESENT, null, c_current_directory, *extended_startup_info.StartupInfo, *process);
    if !result {
        cmdx_print_string(cmdx, "Unknown command. Try :help to see a list of all available commands (Error: %).", GetLastError());
        cmdx.child_process_running = false;
        destroy_child_side_win32_pipes(cmdx);
        destroy_parent_side_win32_pipes(cmdx);
        set_working_directory(working_directory);
        return;
    }
    
    cmdx.child_process_running = true;
    cmdx.win32.child_process_handle = process.hProcess;

    // Close the child end pipes from this side, since they have been duplicated and the parent does not
    // need the handles.
    DeleteProcThreadAttributeList(extended_startup_info.lpAttributeList);
    destroy_child_side_win32_pipes(cmdx);
    
    // Wait for the child process to terminate
    while !cmdx.win32.child_closed_the_pipe && !cmdx.window.should_close { // 0 is WAIT_OBJECT_0
        // Check if any data is available to be read in the pipe
        win32_read_from_child_process(cmdx);
        
        // Render a single frame while waiting for the process to terminate
        single_cmdx_frame(cmdx);
        
        // Get the current process name and display that in the window title
        if cmdx.child_process_name.count   free_string(cmdx.child_process_name, *cmdx.global_allocator);
        process_name: [MAX_PATH]s8 = ---;
        process_name_length := K32GetModuleBaseNameA(process.hProcess, null, process_name, MAX_PATH);
        cmdx.child_process_name = make_string(process_name, process_name_length, *cmdx.global_allocator);
        update_window_name(cmdx);
    }
    
    // Do one final read from the child process
    win32_read_from_child_process(cmdx);
    
    // Close all handles
    destroy_parent_side_win32_pipes(cmdx);
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    cmdx.win32.child_process_handle = INVALID_HANDLE_VALUE;
    cmdx.child_process_running = false;
    
    // Clear the current process name
    free_string(cmdx.child_process_name, *cmdx.global_allocator);
    cmdx.child_process_name = "";
    update_window_name(cmdx);
    set_working_directory(working_directory);
}

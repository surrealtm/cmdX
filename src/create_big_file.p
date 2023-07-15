#load "basic.p";

CHARACTER_START := 32;
CHARACTER_COUNT := 125 - 32;

create_big_file :: (cmdx: *CmdX, file_path: string, file_size: u64) {
    absolute_path := get_path_relative_to_cd(cmdx, file_path);
    
    cstring := to_cstring(absolute_path, Default_Allocator);
    defer free_cstring(cstring, Default_Allocator);
    
    file_handle := CreateFileA(cstring, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0, null);
    
    buffer: [8129]u8;
    written := 0;
    
    while written < file_size {
        commit := min(buffer.count, file_size - written);
        
        // Fill the commit with random characters.
        for i := 0; i < commit; ++i
            buffer[i] = get_random_integer() % CHARACTER_COUNT + CHARACTER_START;
        
        // Make sure there are line breaks in regular intervals so that the output is somewhat plausible.
        for i := 0; i < commit; i += 128   buffer[i] = '\n';
        
        WriteFile(file_handle, buffer, commit, null, null);
        written += commit;
    }
    
    CloseHandle(file_handle);
}

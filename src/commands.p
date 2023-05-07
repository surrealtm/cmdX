// A command handler takes in the actual name of the command, as well as all the arguments parsed from the input.
// If the command has been parsed successfully (no syntax errors), the handler returns true. If the handler
// returns false, the custom help message for the command will be displayed.
Command_Handler :: (*CmdX, string, [..]string) -> bool;

Command_Argument :: struct {
    name: string;
    type: s64;
}

Command :: struct {
    name: string;
    handler: Command_Handler;
    arguments: [..]Command_Argument;
}


/* --- Handling of commands --- */

print_command_syntax :: (cmdx: *CmdX, command: *Command) {
    cmdx_print(cmdx, " > %", command.name);
}

handle_input_string :: (cmdx: *CmdX, input: string) {
    command_name := input;
    command_arguments: [..]string;

    success := false;
    
    for i := 0; i < cmdx.commands.count; ++i {
        command := array_get(*cmdx.commands, i);
        if compare_strings(command.name, command_name) {
            command.handler(cmdx, command_name, command_arguments);
            success = true;
            break;
        }
    }

    if !success {
        cmdx_print(cmdx, "Unknown command. Try :help to see a list of all available commands.");
    }
}


/* --- Actual builtin command behaviour --- */

help :: (cmdx: *CmdX) {
    cmdx_print(cmdx, "=== HELP ===");

    for i := 0; i < cmdx.commands.count; ++i {
        command := array_get(*cmdx.commands, i);
        print_command_syntax(cmdx, command);
    }
    
    cmdx_print(cmdx, "=== HELP ===");
}

ls :: (cmdx: *CmdX) {
    cmdx_print(cmdx, "Contents of folder '%':", cmdx.current_directory);

    files: [..]string;
    files.allocator = *cmdx.frame_allocator;
    get_files_in_folder(cmdx.current_directory, *files);

    for i := 0; i < files.count; ++i {
        file_name := array_get_value(*files, i);
        cmdx_print(cmdx, " > %", file_name);
    }
}

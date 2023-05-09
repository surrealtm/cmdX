// A command handler takes in the actual name of the command, as well as all the arguments parsed from the input.
// If the command has been parsed successfully (no syntax errors), the handler returns true. If the handler
// returns false, the custom help message for the command will be displayed.
Command_Handler :: (*CmdX, [..]string);

Command_Argument_Type :: enum {
    String;
}

Command_Argument :: struct {
    name: string;
    type: Command_Argument_Type;
}

Command :: struct {
    name: string;
    handler: Command_Handler;
    arguments: [..]Command_Argument;
}


/* --- Command Handling --- */

command_argument_type_to_string :: (type: Command_Argument_Type) -> string {
    result: string = ---;

    switch type {
    case .String; result = "String";
    case; result = "Unknown Type";
    }

    return result;
}

is_valid_command_argument_value :: (type: Command_Argument_Type, value: string) -> bool {
    return true;
}

dispatch_command :: (cmdx: *CmdX, command: *Command, argument_values: [..]string) -> bool {
    if argument_values.count != command.arguments.count {
        cmdx_print(cmdx, "Invalid number of arguments: The command '%' expected '%' arguments, but got '%' arguments. See syntax:", command.name, command.arguments.count, argument_values.count);
        return false;
    }

    for i := 0; i < command.arguments.count; ++i {
        argument := array_get(*command.arguments, i);
        argument_value := array_get_value(*argument_values, i);
        if !is_valid_command_argument_value(argument.type, argument_value) {
            cmdx_print(cmdx, "Invalid argument type: The command '%' expected argument '%' to be of type '%'. See syntax:", command.name, i, command_argument_type_to_string(argument.type));
            return false;
        }
    }

    command.handler(cmdx, argument_values);
    return true;
}


/* Input splitting */

print_command_syntax :: (cmdx: *CmdX, command: *Command) {
    print_buffer: Print_Buffer = ---;
    print_buffer.size = 0;
    print_buffer.output_handle = 0;

    internal_print(*print_buffer, " > %", command.name);

    for i := 0; i < command.arguments.count; ++i {
        argument := array_get(*command.arguments, i);
        internal_print(*print_buffer, " %: %", argument.name, command_argument_type_to_string(argument.type));
        if i + 1 < command.arguments.count internal_print(*print_buffer, ",");
    }

    string := string_view(print_buffer.buffer, print_buffer.size);
    add_string_to_backlog(cmdx, string);
}

get_next_word_in_input :: (input: string, start: *u32, end: *u32) {
    // Eat empty characters before the word
    while ~start < input.count && input[~start] == ' '    ~start += 1;

    if ~start == input.count {
        // There was no more word in the input string
        ~start = input.count;
        ~end = input.count;
        return;
    }
    
    // Get the length of the word
    ~end = search_string_from(input, ' ', ~start);
    if ~end == -1    ~end = input.count;
}

handle_input_string :: (cmdx: *CmdX, input: string) {    
    // Parse the actual command name
    word_start, word_end: u32 = 0;
    get_next_word_in_input(input, *word_start, *word_end);
    command_name := substring(input, word_start, word_end);
    word_start = word_end;
    
    command_arguments: [..]string;
    command_arguments.allocator = *cmdx.frame_allocator;

    // Parse all the arguments
    get_next_word_in_input(input, *word_start, *word_end);
    while word_start < input.count {
        argument := substring(input, word_start, word_end);
        array_add(*command_arguments, argument);

        word_start = word_end;
        get_next_word_in_input(input, *word_start, *word_end);
    }

    command_found := false;

    // Search for a built-in command with that name, if one is found, run it.
    for i := 0; i < cmdx.commands.count; ++i {
        command := array_get(*cmdx.commands, i);
        if compare_strings(command.name, command_name) {
            if !dispatch_command(cmdx, command, command_arguments) print_command_syntax(cmdx, command);
            command_found = true;
            break;
        }
    }

    if !command_found {
        // Join all the different arguments back together to make a command that can be supplied into the
        // process creation. This may seem redundant, but this allows for custom argument management, instead
        // of just passing the raw string along.
        string_builder: String_Builder;
        create_string_builder(*string_builder, *cmdx.frame_memory_arena);
        append_string(*string_builder, command_name);

        for i := 0; i < command_arguments.count; ++i {
            argument := array_get_value(*command_arguments, i);
            append_string(*string_builder, " ");
            append_string(*string_builder, argument);
        }

        command_string := finish_string_builder(*string_builder);
        
        try_spawn_process_for_command(cmdx, command_string);
    }
}


/* Builtin command behaviour */

help :: (cmdx: *CmdX) {
    cmdx_print(cmdx, "=== HELP ===");

    for i := 0; i < cmdx.commands.count; ++i {
        command := array_get(*cmdx.commands, i);
        print_command_syntax(cmdx, command);
    }
    
    cmdx_print(cmdx, "=== HELP ===");
}

theme :: (cmdx: *CmdX, theme_name: string) {
    for i := 0; i < cmdx.themes.count; ++i {
        t := array_get(*cmdx.themes, i);
        if compare_strings(t.name, theme_name) {
            cmdx.active_theme = t;
            return;
        }
    }

    cmdx_print(cmdx, "No loaded theme named '%' could be found.", theme_name);
}

theme_lister :: (cmdx: *CmdX) {
    cmdx_print(cmdx, "List of available themes:");

    for i := 0; i < cmdx.themes.count; ++i {
        theme := array_get(*cmdx.themes, i);
        cmdx_print(cmdx, " > %", theme.name);
        if theme == cmdx.active_theme    append_string_to_backlog(cmdx, "   * Active");
    }
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

cd :: (cmdx: *CmdX, new_directory: string) {
    cwd := concatenate_strings(cmdx.current_directory, "\\", *cmdx.frame_allocator);   
    concat := concatenate_strings(cwd, new_directory, *cmdx.frame_allocator);
    if folder_exists(concat) {
        free_string(cmdx.current_directory, *cmdx.global_allocator);
        cmdx.current_directory = get_absolute_path(concat, *cmdx.global_allocator); // Remove any redundency in the path (e.g. parent/../parent)
        update_window_name(cmdx);
    } else {
        cmdx_print(cmdx, "Cannot change directory: The folder '%' does not exists.", concat);
    }
}

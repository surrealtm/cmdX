// A command handler takes in the actual name of the command, as well as all the arguments parsed from
// the input. If the command has been parsed successfully (no syntax errors), the handler returns true. 
// If the handler returns false, the custom help message for the command will be displayed.
Command_Handler :: (*CmdX, *[..]string);

Command_Argument_Type :: enum {
    String;
    Integer;
    Key_Code;
}

Command_Argument :: struct {
    name: string;
    type: Command_Argument_Type;
    is_optional_argument: bool;
    default_value: string;
}

Command :: struct {
    name: string;
    aliases: [..]string;
    description: string;
    handler: Command_Handler;
    arguments: [..]Command_Argument;
    contains_optional_argument: bool;
}


/* --- Command Handling --- */

get_path_relative_to_cd :: (cmdx: *CmdX, file_path: string) -> string {
    // If the path appendation is empty, then just take the current directory
    if file_path.count == 0    return cmdx.current_directory;

    // If the path supplied ends on a slash, it is effectively the same as without the slash, so just ignore it.
    while file_path[file_path.count - 1] == '/' || file_path[file_path.count - 1] == '\\' file_path.count -= 1;
    
    // If the path is already absolute, then do not apply the relative working directory
    cstring := to_cstring(file_path, *cmdx.frame_allocator);
    if !PathIsRelativeA(cstring) {
        return get_absolute_path(file_path, *cmdx.frame_allocator); 
    }
        
    // Concatenate the relative path with the current directory of cmdx.
    builder: String_Builder = ---;
    create_string_builder(*builder, *cmdx.frame_memory_arena);
    append_string(*builder, cmdx.current_directory);
    append_string(*builder, "\\");
    append_string(*builder, file_path);
    concatenation := finish_string_builder(*builder);

    // Remove any redundency in the path (e.g. parent/../)
    new_path := get_absolute_path(concatenation, *cmdx.frame_allocator);
    return new_path;
}

print_command_syntax :: (cmdx: *CmdX, command: *Command) {
    print_buffer: Print_Buffer = ---;
    print_buffer.size = 0;
    print_buffer.output_handle = 0;
    
    bprint(*print_buffer, " > %", command.name);
    
    builder: String_Builder;
    create_string_builder(*builder, *cmdx.frame_memory_arena);
    append_format(*builder, " > %", command.name);
    
    for i := 0; i < command.arguments.count; ++i {
        argument := array_get(*command.arguments, i);

        append_string(*builder, "    ");

        if argument.is_optional_argument   append_string(*builder, "<");
        
        append_format(*builder, "'%': %", argument.name, command_argument_type_to_string(argument.type));

        if argument.is_optional_argument   append_string(*builder, ">");

        if i + 1 < command.arguments.count append_string(*builder, ",");
    }
    
    append_format(*builder, "      // %", command.description);
    add_line(cmdx, finish_string_builder(*builder));
}

command_argument_type_to_string :: (type: Command_Argument_Type) -> string {
    result: string = ---;
    
    switch type {
    case .String; result = "String";
    case .Integer; result = "Integer";
    case .Key_Code; result = "Key";
    case; result = "Unknown Type";
    }
    
    return result;
}

is_valid_command_argument_value :: (type: Command_Argument_Type, value: string) -> bool {
    valid := false;
    
    switch type {
    case .String; valid = true;
        
    case .Integer;
        valid = true;
        for i := 0; i < value.count; ++i {
            valid &= is_digit_character(value[i]);
        }

    case .Key_Code;
        key_code := parse_key_code(value);
        valid = key_code != .None;
    }
    
    return valid;
}

get_string_argument :: (argument_values: *[..]string, index: u32) -> string {
    return array_get_value(argument_values, index);
}

get_int_argument :: (argument_values: *[..]string, index: u32) -> s64 {
    string := array_get_value(argument_values, index);
    int, valid := string_to_int(string);
    return int;
}

get_key_code_argument :: (argument_values: *[..]string, index: u32) -> Key_Code {
    string := array_get_value(argument_values, index);
    key_code := parse_key_code(string);
    return key_code;
}

dispatch_command :: (cmdx: *CmdX, command: *Command, argument_values: [..]string) -> bool {
    if argument_values.count == command.arguments.count - 1 && command.contains_optional_argument {
        // If the command has an optional argument, and it seems like that argument is currently missing
        // from the array, then try to add the default value to the argument array.

        // Find the optional argument, in case it is not the last one (which is technically not enforced...)
        argument: *Command_Argument = null;
        argument_index := 0;
        
        for i := 0; i < command.arguments.count; ++i {
            arg := array_get(*command.arguments, i);
            if arg.is_optional_argument {
                argument = arg;
                argument_index = i;
                break;
            }
        }

        assert(argument != null, "Could not find the optional argument for a command."); // contains_optional_argument should only ever be set if an optional argument is created...

        if argument_index == argument_values.count {
            array_add(*argument_values, argument.default_value);
        } else
            array_add_at(*argument_values, argument_index, argument.default_value);
    }
    
    if argument_values.count != command.arguments.count {
        add_formatted_line(cmdx, "Invalid number of arguments: The command '%' expected '%' arguments, but got '%' arguments. See syntax:", command.name, command.arguments.count, argument_values.count);
        return false;
    }
    
    for i := 0; i < command.arguments.count; ++i {
        argument := array_get(*command.arguments, i);
        argument_value := array_get_value(*argument_values, i);
        if !is_valid_command_argument_value(argument.type, argument_value) {
            add_formatted_line(cmdx, "Invalid argument type: The command '%' expected argument '%' to be of type '%'. See syntax:", command.name, i, command_argument_type_to_string(argument.type));
            return false;
        }
    }
    
    command.handler(cmdx, *argument_values);
    return true;
}

find_command_by_name :: (cmdx: *CmdX, name: string) -> *Command {
    command: *Command = null;

    for i := 0; i < cmdx.commands.count; ++i {
        cmd := array_get(*cmdx.commands, i);

        if compare_command_name(cmd, name) {
            command = cmd;
            break;
        }
    }
    
    return command;
}


/* --- Input splitting --- */

get_next_word_in_input :: (input: *string) -> string {
    // Eat empty characters before the word
    argument_start: u32 = 0;
    while argument_start < input.count && input.data[argument_start] == ' '    argument_start += 1;
    
    if argument_start == input.count {
        // There was no more word in the input string, set the start and end pointer to an invalid state
        ~input = "";
        return "";
    }
    
    argument: string = ---;
    
    // Read the input string until the end of the word.
    if input.data[argument_start] == '"' {
        // If the start of this word is a quotation mark, then the word end is marked by the next
        // quotation mark. Spaces are ignored in this case.
        argument_end, found_quote := search_string_from(~input, '"', argument_start + 1);
        if !found_quote {
            // While this is technically invalid syntax, we'll allow it for now. If no closing quote is found, just
            // assume that the argument is the rest of the input string.
            argument = substring_view(~input, argument_start, input.count);
            ~input = "";
        } else {
            // Exclude the actual quote characters from the output string
            argument = substring_view(~input, argument_start + 1, argument_end);
            ~input = substring_view(~input, argument_end + 1, input.count);
        }
    } else {
        // The word goes until the next encountered space character.
        argument_end, found_space := search_string_from(~input, ' ', argument_start);
        if !found_space    argument_end = input.count;
        argument = substring_view(~input, argument_start, argument_end);
        ~input = substring_view(~input, argument_end, input.count);
    }
    
    return argument;
}

compare_command_name :: (cmd: *Command, name: string) -> bool {
    if compare_strings(cmd.name, name) return true;
    
    for i := 0; i < cmd.aliases.count; ++i {
        alias := array_get_value(*cmd.aliases, i);
        if compare_strings(alias, name) return true;
    }
    
    return false;
}

handle_input_string :: (cmdx: *CmdX, input: string) {
    // Prepare the viewport for the next command, no matter what actually happens
    prepare_viewport(cmdx);
    
    // Parse the actual command name
    command_name := get_next_word_in_input(*input);
    
    command_arguments: [..]string;
    command_arguments.allocator = *cmdx.frame_allocator;
    
    // Parse all the arguments
    while input.count {
        argument := get_next_word_in_input(*input);
        if argument.count array_add(*command_arguments, argument);
    }
    
    command_found := false;
    
    // Search for a built-in command with that name, if one is found, run it.
    for i := 0; i < cmdx.commands.count; ++i {
        command := array_get(*cmdx.commands, i);
        if compare_command_name(command, command_name) {
            if !dispatch_command(cmdx, command, command_arguments) print_command_syntax(cmdx, command);
            command_found = true;
            close_viewport(cmdx);
            break;
        }
    }
    
    if !command_found {
        // Join all the different arguments back together to make a command that can be supplied into 
        // the process creation. This may seem redundant, but this allows for custom argument 
        // management, instead of just passing the raw string along.
        string_builder: String_Builder;
        create_string_builder(*string_builder, *cmdx.frame_memory_arena);
        append_string(*string_builder, command_name);
        
        for i := 0; i < command_arguments.count; ++i {
            argument := array_get_value(*command_arguments, i);
            // Compiler does not support \" yet, so this thing has to happen here :(
            append_character(*string_builder, ' ');
            append_character(*string_builder, '"');
            append_string(*string_builder, argument);
            append_character(*string_builder, '"');
        }
        
        command_string := finish_string_builder(*string_builder);
        
        if !win32_spawn_process_for_command(cmdx, command_string) close_viewport(cmdx); // If the spawning failed (e.g. command not found), then the viewport needs to be closed
    }    
}


/* Builtin command behaviour */

help :: (cmdx: *CmdX, command_name: string) {
    if command_name.count == 0 {
        // Default argument, list all commands
        add_line(cmdx, "=== HELP ===");
        
        for i := 0; i < cmdx.commands.count; ++i {
            command := array_get(*cmdx.commands, i);
            print_command_syntax(cmdx, command);
        }
        
        add_line(cmdx, "=== HELP ===");
    } else {
        // A specific command was specified, display that syntax.
        command := find_command_by_name(cmdx, command_name);
        if command {
            print_command_syntax(cmdx, command);
        } else {
            add_formatted_line(cmdx, "No command could be found under the name '%'.", command_name);
        }
    }
}

quit :: (cmdx: *CmdX) {
    cmdx.window.should_close = true;
}

clear :: (cmdx: *CmdX) {
    clear_backlog(cmdx);
}

theme :: (cmdx: *CmdX, theme_name: string) {
    cmdx.active_theme_name = copy_string(theme_name, Default_Allocator);
    update_active_theme_pointer(cmdx);
}

theme_lister :: (cmdx: *CmdX) {
    add_line(cmdx, "List of available themes:");
    
    for i := 0; i < cmdx.themes.count; ++i {
        theme := array_get(*cmdx.themes, i);
        add_formatted_text(cmdx, " > %", theme.name);
        if theme == cmdx.active_theme    add_text(cmdx, "   * Active");
        new_line(cmdx);
    }
}

font_size :: (cmdx: *CmdX, size: u32) {
    cmdx.font_size = size;
    update_font(cmdx);
}

font_name :: (cmdx: *CmdX, path: string) {
    free_string(cmdx.font_path, cmdx.config.allocator);
    cmdx.font_path = copy_string(path, cmdx.config.allocator);
    update_font(cmdx);
}

debug_print_allocator :: (cmdx: *CmdX, name: string, allocator: *Allocator) {
    working_set_size, working_set_unit := convert_to_biggest_memory_unit(allocator.stats.working_set);
    peak_working_set_size, peak_working_set_unit := convert_to_biggest_memory_unit(allocator.stats.peak_working_set);
    add_formatted_line(cmdx, "% : %*% working_set,    %*% peak_working_set,   % total allocations, % alive allocations.", name, format_int(working_set_size, false, 3, .Decimal, false), memory_unit_string(working_set_unit), format_int(peak_working_set_size, false, 3, .Decimal, false), memory_unit_string(peak_working_set_unit), allocator.stats.allocations, allocator.stats.allocations - allocator.stats.deallocations);
}

debug :: (cmdx: *CmdX) {
    static_size, static_size_unit := convert_to_biggest_memory_unit(size_of(CmdX));
    add_formatted_line(cmdx, "Static memory usage: %*%", static_size, memory_unit_string(static_size_unit));

    debug_print_allocator(cmdx, "Heap  ", *Heap_Allocator);
    debug_print_allocator(cmdx, "Global", *cmdx.global_allocator);
    debug_print_allocator(cmdx, "Frame ", *cmdx.frame_allocator);

    debug_print(cmdx);
}

config :: (cmdx: *CmdX) {
    add_line(cmdx, "Properties:");

    for i := 0; i < cmdx.config.properties.count; ++i {
        property := array_get(*cmdx.config.properties, i);
        add_formatted_text(cmdx, "    %: % = ", property.name, property_type_to_string(property.type));

        switch property.type {
        case .String; add_formatted_line(cmdx, "\"%\"", ~property.value._string);
        case .Bool; add_formatted_line(cmdx, "%", ~property.value._bool);
        case .S64; add_formatted_line(cmdx, "%", ~property.value._s64);
        case .U32; add_formatted_line(cmdx, "%", ~property.value._u32);
        }
    }

    new_line(cmdx);
    add_line(cmdx, "Actions:");
    
    for i := 0; i < cmdx.config.actions.count; ++i {
        action := array_get(*cmdx.config.actions, i);
        add_formatted_text(cmdx, "    %: % = ", key_code_to_string(action.trigger), action_type_to_string(action.type));

        switch action.type {
        case .Macro; add_formatted_line(cmdx, "\"%\"", action.data.macro_text);
        }
    }
}

add_macro :: (cmdx: *CmdX, trigger: Key_Code, text: string) {
    if find_action_with_trigger(cmdx, trigger) != null {
        add_formatted_line(cmdx, "An action bound to trigger '%' already exists.", key_code_to_string(trigger));
        return;
    }

    action        := array_push(*cmdx.config.actions);
    action.trigger = trigger;
    action.type    = .Macro;
    action.data.macro_text = copy_string(text, cmdx.config.allocator);
}

remove_macro :: (cmdx: *CmdX, trigger: Key_Code) {
    removed_something := remove_action_by_trigger(cmdx, trigger);

    if !removed_something {
        add_formatted_line(cmdx, "No action bound to trigger '%' exists.", key_code_to_string(trigger));
        return;
    }
}

ls :: (cmdx: *CmdX, directory: string) {
    complete_directory := cmdx.current_directory;

    if directory.count {
        complete_directory = get_path_relative_to_cd(cmdx, directory);
    }
    
    add_formatted_line(cmdx, "Contents of folder '%':", complete_directory);
    
    files := get_files_in_folder(complete_directory, *cmdx.frame_allocator);
    
    for i := 0; i < files.count; ++i {
        file_name := array_get_value(*files, i);
        add_formatted_line(cmdx, " > %", file_name);
    }
}

cat :: (cmdx: *CmdX, file_path: string) {
    absolute_path := get_path_relative_to_cd(cmdx, file_path);

    file_contents, file_found := read_file(absolute_path);
    original_file_contents := file_contents;
    defer free_file_data(original_file_contents);
    
    if !file_found {
        error_string := win32_last_error_to_string();
        add_formatted_line(cmdx, "Cannot cat file '%': %", absolute_path, error_string);
        win32_free_last_error_string(*error_string);
        return;
    }

    while file_contents.count {
        line := get_first_line(*file_contents);
        add_line(cmdx, line);
    }
}

cd :: (cmdx: *CmdX, folder_path: string) {
    absolute_path := get_path_relative_to_cd(cmdx, folder_path);

    if folder_exists(absolute_path) {
        free_string(cmdx.current_directory, *cmdx.global_allocator);
        cmdx.current_directory = copy_string(absolute_path, *cmdx.global_allocator); // The new directory must survive the frame
        update_window_name(cmdx);
    } else {
        error_string := win32_last_error_to_string();
        add_formatted_line(cmdx, "Cannot change to directory '%': %", absolute_path, error_string);
        win32_free_last_error_string(*error_string);
    }
}
    
create_file :: (cmdx: *CmdX, file_path: string) {
    absolute_path := get_path_relative_to_cd(cmdx, file_path);
    
    if !write_file(absolute_path, "", false) {
        error_string := win32_last_error_to_string();
        add_formatted_line(cmdx, "Cannot create file '%': %", absolute_path, error_string);
        win32_free_last_error_string(*error_string);
    }
}

remove_file :: (cmdx: *CmdX, file_path: string) {
    absolute_path := get_path_relative_to_cd(cmdx, file_path);
    
    if !delete_file(absolute_path) && !delete_folder(absolute_path) {
        error_string := win32_last_error_to_string();
        add_formatted_line(cmdx, "Cannot remove file or directory '%': %", absolute_path, error_string);
        win32_free_last_error_string(*error_string);
    }
}

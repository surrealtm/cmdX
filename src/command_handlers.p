help_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    command_name := get_string_argument(*argument_values, 0);
    help(cmdx, command_name);
}

quit_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    quit(cmdx);
}

clear_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    clear(cmdx);
}

theme_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    theme_name := get_string_argument(*argument_values, 0);
    theme(cmdx, theme_name);
}

theme_lister_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    theme_lister(cmdx);
}

font_size_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    size := get_int_argument(*argument_values, 0);
    font_size(cmdx, size);
}

debug_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    debug(cmdx);
}

config_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    config(cmdx);
}

add_macro_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    trigger := get_key_code_argument(*argument_values, 0);
    text := get_string_argument(*argument_values, 1);
    add_macro(cmdx, trigger, text);
}

remove_macro_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    trigger := get_key_code_argument(*argument_values, 0);
    remove_macro(cmdx, trigger);
}

ls_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    ls(cmdx);
}

cd_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    new_directory := get_string_argument(*argument_values, 0);
    cd(cmdx, new_directory);
}

delete_file_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    file_path := get_string_argument(*argument_values, 0);
    delete_file(file_path);
}


register_command :: (cmdx: *CmdX, name: string, description: string, handler: Command_Handler) -> *Command{
    cmd := array_push(*cmdx.commands);
    cmd.name = name;
    cmd.handler = handler;
    cmd.description = description;
    cmd.aliases.allocator = *cmdx.global_allocator;
    cmd.arguments.allocator = *cmdx.global_allocator;
    return cmd;
}

register_command_argument :: (command: *Command, name: string, type: Command_Argument_Type) {
    argument := array_push(*command.arguments);
    argument.name = name;
    argument.type = type;
    argument.is_optional_argument = false;
    argument.default_value = .{};
}

register_optional_command_argument :: (command: *Command, name: string, type: Command_Argument_Type, default_value: string) {
    assert(!command.contains_optional_argument, "This command already contains an optional argument, for now only one is allowed.");

    command.contains_optional_argument = true;
    
    argument := array_push(*command.arguments);
    argument.name = name;
    argument.type = type;
    argument.is_optional_argument = true;
    argument.default_value = default_value;
}

register_command_alias :: (command: *Command, alias: string) {
    array_add(*command.aliases, alias);
}

register_all_commands :: (cmdx: *CmdX) {
    help := register_command(cmdx, ":help", "Displays help information about all available commands", help_handler);
    register_optional_command_argument(help, "command", .String, "");
    
    register_command(cmdx, ":quit", "Terminates cmdX", quit_handler);
    register_command(cmdx, ":clear", "Clears the backlog", clear_handler);

    theme := register_command(cmdx, ":theme", "Switches to the specified theme", theme_handler);
    register_command_argument(theme, "theme_name", .String);

    register_command(cmdx, ":theme-lister", "Lists all available themes", theme_lister_handler);

    font_size := register_command(cmdx, ":font-size", "Updates the current font size", font_size_handler);
    register_command_argument(font_size, "size", .Integer);

    register_command(cmdx, ":debug", "Prints debugging information like memory usage", debug_handler);
    register_command(cmdx, ":config", "Prints information about the current config", config_handler);

    add_macro := register_command(cmdx, ":add-macro", "Adds a new macro to the configuration", add_macro_handler);
    register_command_argument(add_macro, "trigger", .Key_Code);
    register_command_argument(add_macro, "text", .String);

    remove_macro := register_command(cmdx, ":remove-macro", "Removes a macro from the configuration", remove_macro_handler);
    register_command_argument(remove_macro, "trigger", .Key_Code);
    
    ls := register_command(cmdx, "ls", "Lists the contents of the current directory", ls_handler);
    register_command_alias(ls, "dir");

    cd := register_command(cmdx, "cd", "Changes the current active directory to the specified relative or absolute path", cd_handler);
    register_command_alias(cd, "change_directory");
    register_command_argument(cd, "new_directory", .String);

    df := register_command(cmdx, "delete_file", "Deletes the file specified by the relative or absolute path", delete_file_handler);
    register_command_alias(df, "rm");
    register_command_alias(df, "remove_file");
    register_command_argument(df, "file_path", .String);
}

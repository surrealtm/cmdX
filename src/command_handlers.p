help_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    help(cmdx);
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
}

register_command_alias :: (command: *Command, alias: string) {
    array_add(*command.aliases, alias);
}

register_all_commands :: (cmdx: *CmdX) {
    register_command(cmdx, ":help", "Displays this help message", help_handler);
    register_command(cmdx, ":quit", "Terminates cmdX", quit_handler);
    register_command(cmdx, ":clear", "Clears the backlog", clear_handler);

    theme := register_command(cmdx, ":theme", "Switches to the specified theme", theme_handler);
    register_command_argument(theme, "theme_name", .String);

    register_command(cmdx, ":theme-lister", "Lists all available themes", theme_lister_handler);

    font_size := register_command(cmdx, ":font-size", "Updates the current font size", font_size_handler);
    register_command_argument(font_size, "size", .Integer);

    register_command(cmdx, ":debug", "Prints debugging information like memory usage", debug_handler);

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

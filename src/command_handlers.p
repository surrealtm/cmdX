// This file is complete boilerplate code to make command execution as easy as possible.
// The reason this may seem so overhead is because it will eventually be automated, once
// the compiler supports that. Until then, we manually need to register commands and write
// their command handlers.

help_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    command_name := get_string_argument(argument_values, 0);
    help(cmdx, command_name);
}

quit_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    quit(cmdx);
}

clear_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    clear(cmdx);
}

theme_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    theme_name := get_string_argument(argument_values, 0);
    theme(cmdx, theme_name);
}

theme_lister_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    theme_lister(cmdx);
}

font_size_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    size := get_int_argument(argument_values, 0);
    font_size(cmdx, size);
}

font_name_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    path := get_string_argument(argument_values, 0);
    font_name(cmdx, path);
}

debug_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    debug(cmdx);
}

config_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    config(cmdx);
}

add_macro_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    trigger := get_key_code_argument(argument_values, 0);
    text := get_string_argument(argument_values, 1);
    add_macro(cmdx, trigger, text);
}

remove_macro_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    trigger := get_key_code_argument(argument_values, 0);
    remove_macro(cmdx, trigger);
}

split_screen_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    split_screen(cmdx);
}

close_active_screen_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    close_active_screen(cmdx);
}

ls_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    directory := get_string_argument(argument_values, 0);
    ls(cmdx, directory);
}

cd_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    new_directory := get_string_argument(argument_values, 0);
    cd(cmdx, new_directory);
}

cat_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    file_path := get_string_argument(argument_values, 0);
    cat(cmdx, file_path);
}

create_file_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    file_path := get_string_argument(argument_values, 0);
    create_file(cmdx, file_path);
}

create_big_file_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    file_path := get_string_argument(argument_values, 0);
    file_size := get_int_argument(argument_values, 1);
    create_big_file(cmdx, file_path, file_size);
}

remove_file_handler :: (cmdx: *CmdX, argument_values: *[..]string) {
    file_path := get_string_argument(argument_values, 0);
    remove_file(cmdx, file_path);
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

    font_name := register_command(cmdx, ":font", "Loads a font from the specified path", font_name_handler);
    register_command_argument(font_name, "path", .String);
    
    register_command(cmdx, ":debug", "Prints debugging information like memory usage", debug_handler);
    register_command(cmdx, ":config", "Prints information about the current config", config_handler);

    add_macro := register_command(cmdx, ":add-macro", "Adds a new macro to the configuration", add_macro_handler);
    register_command_argument(add_macro, "trigger", .Key_Code);
    register_command_argument(add_macro, "text", .String);

    remove_macro := register_command(cmdx, ":remove-macro", "Removes a macro from the configuration", remove_macro_handler);
    register_command_argument(remove_macro, "trigger", .Key_Code);

    register_command(cmdx, ":split-screen", "Creates a new screen", split_screen_handler);
    register_command(cmdx, ":close-screen", "Closes the current screen", close_active_screen_handler);
    
    ls := register_command(cmdx, "ls", "Lists the contents of the current directory", ls_handler);
    register_optional_command_argument(ls, "directory", .String, "");
    register_command_alias(ls, "dir");

    cd := register_command(cmdx, "cd", "Changes the current active directory to the specified relative or absolute path", cd_handler);
    register_command_alias(cd, "change_directory");
    register_command_argument(cd, "new_directory", .String);

    cat := register_command(cmdx, "cat", "Dumps the contents of the specified file into the backlog", cat_handler);
    register_command_argument(cat, "file_path", .String);
    
    cf := register_command(cmdx, "create_file", "Creates a new empty file at the specified relative or absolute path", create_file_handler);
    register_command_argument(cf, "file_path", .String);

    cbf := register_command(cmdx, "create_big_file", "Creates a new big file with random content for testing purposes.", create_big_file_handler);
    register_command_argument(cbf, "file_path", .String);
    register_command_argument(cbf, "file_size", .Integer);
    
    rf := register_command(cmdx, "remove_file", "Deletes the file or folder specified by the relative or absolute path", remove_file_handler);
    register_command_alias(rf, "rm");
    register_command_alias(rf, "delete_file");
    register_command_argument(rf, "file_path", .String);
}

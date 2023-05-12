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


register_command_argument :: (command: *Command, name: string, type: Command_Argument_Type) {
    argument := array_push(*command.arguments);
    argument.name = name;
    argument.type = type;
}

register_all_commands :: (cmdx: *CmdX) {
    help := array_push(*cmdx.commands);
    help.name = ":help";
    help.handler = help_handler;

    quit := array_push(*cmdx.commands);
    quit.name = ":quit";
    quit.handler = quit_handler;

    clear := array_push(*cmdx.commands);
    clear.name = ":clear";
    clear.handler = clear_handler;
    
    theme := array_push(*cmdx.commands);
    theme.name = ":theme";
    theme.handler = theme_handler;
    register_command_argument(theme, "theme_name", .String);

    theme_lister := array_push(*cmdx.commands);
    theme_lister.name = ":theme-lister";
    theme_lister.handler = theme_lister_handler;

    font_size := array_push(*cmdx.commands);
    font_size.name = ":font-size";
    font_size.handler = font_size_handler;
    register_command_argument(font_size, "size", .Integer);

    debug := array_push(*cmdx.commands);
    debug.name = ":debug";
    debug.handler = debug_handler;
    
    ls := array_push(*cmdx.commands);
    ls.name = "ls";
    ls.handler = ls_handler;

    cd := array_push(*cmdx.commands);
    cd.name = "cd";
    cd.handler = cd_handler;
    register_command_argument(cd, "new_directory", .String);
}

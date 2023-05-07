help_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    help(cmdx);
}

theme_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    theme_name := array_get_value(*argument_values, 0);
    theme(cmdx, theme_name);
}

ls_handler :: (cmdx: *CmdX, argument_values: [..]string) {
    ls(cmdx);
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

    theme := array_push(*cmdx.commands);
    theme.name = ":theme";
    theme.handler = theme_handler;
    register_command_argument(theme, "theme_name", .String);
    
    ls := array_push(*cmdx.commands);
    ls.name = "ls";
    ls.handler = ls_handler;
}

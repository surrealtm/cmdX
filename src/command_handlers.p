handle_command_help :: (cmdx: *CmdX, name: string, arguments: [..]string) -> bool {
    if arguments.count != 0 {
        return false;
    }
        
    help(cmdx);
    return true;
}

handle_command_ls :: (cmdx: *CmdX, name: string, arguments: [..]string) -> bool {
    if arguments.count != 0 {
        return false;
    }

    ls(cmdx);
    return true;
}

register_all_commands :: (cmdx: *CmdX) {
    help := array_push(*cmdx.commands);
    help.name = ":help";
    help.handler = handle_command_help;

    ls := array_push(*cmdx.commands);
    ls.name = "ls";
    ls.handler = handle_command_ls;
}

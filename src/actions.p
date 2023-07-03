Action_Type :: enum {
    Undefined;
    Macro;
}

Action_Data :: union {
    macro_text: string;
}

Action :: struct {
    type: Action_Type;
    data: Action_Data;
    trigger: Key_Code;
}


parse_key_code :: (string: string) -> Key_Code {
    result: Key_Code = .None;

    if compare_strings(string, "A") result = .A;
    else if compare_strings(string, "B") result = .B;
    else if compare_strings(string, "C") result = .C;
    else if compare_strings(string, "D") result = .D;
    else if compare_strings(string, "E") result = .E;
    else if compare_strings(string, "F") result = .F;
    else if compare_strings(string, "G") result = .G;
    else if compare_strings(string, "H") result = .H;
    else if compare_strings(string, "I") result = .I;
    else if compare_strings(string, "J") result = .J;
    else if compare_strings(string, "K") result = .K;
    else if compare_strings(string, "L") result = .L;
    else if compare_strings(string, "M") result = .M;
    else if compare_strings(string, "N") result = .N;
    else if compare_strings(string, "O") result = .O;
    else if compare_strings(string, "P") result = .P;
    else if compare_strings(string, "Q") result = .Q;
    else if compare_strings(string, "R") result = .R;
    else if compare_strings(string, "S") result = .S;
    else if compare_strings(string, "T") result = .T;
    else if compare_strings(string, "U") result = .U;
    else if compare_strings(string, "V") result = .V;
    else if compare_strings(string, "W") result = .W;
    else if compare_strings(string, "X") result = .X;
    else if compare_strings(string, "Y") result = .Y;
    else if compare_strings(string, "Z") result = .Z;
    else if compare_strings(string, "Up")        result = .Arrow_Up;
    else if compare_strings(string, "Down")      result = .Arrow_Down;
    else if compare_strings(string, "Left")      result = .Arrow_Left;
    else if compare_strings(string, "Right")     result = .Arrow_Right;
    else if compare_strings(string, "Enter")     result = .Enter;
    else if compare_strings(string, "Space")     result = .Space;
    else if compare_strings(string, "Shift")     result = .Shift;
    else if compare_strings(string, "Escape")    result = .Escape;
    else if compare_strings(string, "Menu")      result = .Menu;
    else if compare_strings(string, "Control")   result = .Control;
    else if compare_strings(string, "Backspace") result = .Backspace;
    else if compare_strings(string, "Delete")    result = .Delete;
    else if compare_strings(string, "F1")  result = .F1;
    else if compare_strings(string, "F2")  result = .F2;
    else if compare_strings(string, "F3")  result = .F3;
    else if compare_strings(string, "F4")  result = .F4;
    else if compare_strings(string, "F5")  result = .F5;
    else if compare_strings(string, "F6")  result = .F6;
    else if compare_strings(string, "F7")  result = .F7;
    else if compare_strings(string, "F8")  result = .F8;
    else if compare_strings(string, "F9")  result = .F9;
    else if compare_strings(string, "F10") result = .F10;
    else if compare_strings(string, "F11") result = .F11;
    else if compare_strings(string, "F12") result = .F12;
    
    return result;
}

key_code_to_string :: (key: Key_Code) -> string {
    result: string = ---;

    switch key {
    case .A; result = "A";
    case .B; result = "B";
    case .C; result = "C";
    case .D; result = "D";
    case .E; result = "E";
    case .F; result = "F";
    case .G; result = "G";
    case .H; result = "H";
    case .I; result = "I";
    case .J; result = "J";
    case .K; result = "K";
    case .L; result = "L";
    case .M; result = "M";
    case .N; result = "N";
    case .O; result = "O";
    case .P; result = "P";
    case .Q; result = "Q";
    case .R; result = "R";
    case .S; result = "S";
    case .T; result = "T";
    case .U; result = "U";
    case .V; result = "V";
    case .W; result = "W";
    case .X; result = "X";
    case .Y; result = "Y";
    case .Z; result = "Z";
    case .Arrow_Up;    result = "Up";
    case .Arrow_Down;  result = "Down";
    case .Arrow_Left;  result = "Left";
    case .Arrow_Right; result = "Right";
    case .Enter;       result = "Enter";
    case .Space;       result = "Space";
    case .Shift;       result = "Shift";
    case .Escape;      result = "Escape";
    case .Menu;        result = "Menu";
    case .Control;     result = "Control";
    case .Backspace;   result = "Backspace";
    case .Delete;      result = "Delete";
    case .F1;  result = "F1";
    case .F2;  result = "F2";
    case .F3;  result = "F3";
    case .F4;  result = "F4";
    case .F5;  result = "F5";
    case .F6;  result = "F6";
    case .F7;  result = "F7";
    case .F8;  result = "F8";
    case .F9;  result = "F9";
    case .F10; result = "F10";
    case .F11; result = "F11";
    case .F12; result = "F12";        
    case; result = "UnknownKeyCode";
    }
    
    return result;
}

parse_action_type :: (string: string) -> Action_Type {
    result: Action_Type = .Undefined;

    if compare_strings(string, "Macro") result = .Macro;

    return result;
}

action_type_to_string :: (type: Action_Type) -> string {
    result: string = ---;

    switch type {
    case .Macro; result = "Macro";
    case; result = "UnknownActionType";
    }
    
    return result;
}

parse_action_data :: (type: Action_Type, string: string, allocator: *Allocator) -> Action_Data {
    result: Action_Data = ---;

    if type == .Macro {
        if string[0] == '"' && string[string.count - 1] == '"' {
            result.macro_text = copy_string(substring_view(string, 1, string.count - 1), allocator);
        } else
            result.macro_text = copy_string(string, allocator);
    }
    
    return result;
}

read_action :: (cmdx: *CmdX, config: *Config, line: string, line_count: s64) {
    arguments := split_string(line, ' ', true, *cmdx.frame_allocator);

    if arguments.count != 3 {
        config_error(cmdx, "Malformed config action in line %:", line_count);
        config_error(cmdx, "  Expected exactly three arguments, in the syntax: <key> <type> <data>");
        return;
    }

    trigger_argument     := array_get_value(*arguments, 0);
    action_type_argument := array_get_value(*arguments, 1);
    action_data_argument := array_get_value(*arguments, 2);
    
    trigger := parse_key_code(trigger_argument);
    type    := parse_action_type(action_type_argument);
    data    := parse_action_data(type, action_data_argument, config.allocator);

    if trigger == .None {
        config_error(cmdx, "Malformed config action in line %: Unknown key code '%'", line_count, trigger_argument);
        return;
    }

    if type == .Undefined {
        config_error(cmdx, "Malformed config action in line %: Unknown action type '%'", line_count, action_type_argument);
        return;
    }

    action := array_push(*config.actions);
    action.trigger = trigger;
    action.type    = type;
    action.data    = data;
}

write_actions_to_file :: (list: *[..]Action, file: *Print_Buffer) {
    for i := 0; i < list.count; ++i {
        action := array_get(list, i);

        bprint(file, "% ", key_code_to_string(action.trigger));
        bprint(file, "% ", action_type_to_string(action.type));
        bprint(file, "\"%\"", action.data.macro_text);
        bprint(file, "\n");
    }
}

find_action_with_trigger :: (cmdx: *CmdX, trigger: Key_Code) -> *Action {
    result: *Action = null;
    
    for i := 0; i < cmdx.config.actions.count; ++i {
        action := array_get(*cmdx.config.actions, i);

        if action.trigger == trigger {
            result = action;
            break;
        }
    }

    return result;
}

execute_actions_with_trigger :: (cmdx: *CmdX, trigger: Key_Code) -> bool {
    action := find_action_with_trigger(cmdx, trigger);

    if !action return true;
    
    switch action.type {
    case .Macro;
        clear_text_input(*cmdx.text_input);
        set_text_input_string(*cmdx.text_input, action.data.macro_text);
    }
    
    return true;
}

remove_action_by_trigger :: (cmdx: *CmdX, trigger: Key_Code) -> bool {
    removed_something := false;

    for i := 0; i < cmdx.config.actions.count; ++i {
        action := array_get(*cmdx.config.actions, i);

        if action.trigger == trigger {
            array_remove(*cmdx.config.actions, i);
            removed_something = true;
            break;
        }
    }
    
    return removed_something;
}

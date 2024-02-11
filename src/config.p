CONFIG_FILE_NAME :: ".cmdx-config";
CONFIG_HOTLOAD_CHECK_INTERVAL: f32 : 1000; // In milliseconds

Section_Type :: enum {
    Unknown :: 0;
    General :: 1;
    Actions;
}

Property_Type :: enum {
    String;
    Bool;
    S64;
    S32;
    U32;
    F32;
}

Property_Value :: union {
    _string: *string;
    _bool:   *bool;
    _s64:    *s64;
    _s32:    *s32;
    _u32:    *u32;
    _f32:    *f32;
}

Property_Default :: union {
    _string: string;
    _bool:   bool;
    _s64:    s64;
    _s32:    s32;
    _u32:    u32;
    _f32:    f32;
}

Property :: struct {
    name: string;
    type: Property_Type;
    value: Property_Value;
    default: Property_Default; // This is used to initialize the property whenever the config is loaded, and the value is not present in the config file. Since reloading the config can happen multiple times, the default value from when the property was created needs to be remembered
}

Config :: struct {
    allocator: *Allocator = Default_Allocator;
    properties: [..]Property;
    actions: [..]Action;

    accumulate_errors: bool; // When the config file is currently being read, then all errors should be accumulated and reported together for better formatting. If some other process uses the config_error, then it should be immediately printed onto the screen.
    error_messages: [..]string;

    last_modification_check: s64; // In hardware time. Do not check the file for modification each frame, as that is unnecessary and expensive. Instead, check in regular intervals
    last_modification_time: s64; // In File Time (see File_Information). This is compared against the filesystems idea of the last modification time, and if the stored time is older, then the config gets reloaded and this time updated.
}

property_type_to_string :: (type: Property_Type) -> string {
    result: string = ---;

    switch #complete type {
    case .String; result = "String";
    case .Bool; result = "Bool";
    case .S64, .S32, .U32; result = "Integer";
    case .F32; result = "Float";
    }

    return result;
}

create_property_internal :: (config: *Config, name: string, type: Property_Type) -> *Property {
    property := array_push(*config.properties);
    property.name = name;
    property.type = type;
    return property;
}

// Strings as properties are always annoying, since they must be dynamically allocated and freed again.
// The freeing of the the string value occurs when the config is reloaded. The value is then assigned
// its default value, which is another string. The config could however also overwrite the value with
// a string from the file, which needs to be freed. Therefore, all other assignments to the properties
// value will also be freed at some point, and therefore need to be copies.
create_string_property :: (config: *Config, name: string, value: *string) {
    property := create_property_internal(config, name, .String);
    property.value._string   = value; // Set the pointer for the property value
    ~property.value._string  = copy_string(config.allocator, ~value); // Copy the string into the value, so that this string can later be freed
    property.default._string = copy_string(config.allocator, ~value);
}

create_bool_property :: (config: *Config, name: string, value: *bool) {
    property := create_property_internal(config, name, .Bool);
    property.value._bool   = value;
    property.default._bool = ~value;
}

create_s64_property :: (config: *Config, name: string, value: *s64) {
    property := create_property_internal(config, name, .S64);
    property.value._s64   = value;
    property.default._s64 = ~value;
}

create_s32_property :: (config: *Config, name: string, value: *s32) {
    property := create_property_internal(config, name, .S32);
    property.value._s32   = value;
    property.default._s32 = ~value;
}

create_u32_property :: (config: *Config, name: string, value: *u32) {
    property := create_property_internal(config, name, .U32);
    property.value._u32   = value;
    property.default._u32 = ~value;
}

create_f32_property :: (config: *Config, name: string, value: *f32) {
    property := create_property_internal(config, name, .F32);
    property.value._f32   = value;
    property.default._f32 = ~value;
}

find_property :: (config: *Config, name: string) -> *Property {
    for i := 0; i < config.properties.count; ++i {
        property := array_get(*config.properties, i);
        if compare_strings(property.name, name) return property;
    }

    return null;
}

assign_property_value_from_string :: (config: *Config, property: *Property, value_string: string) -> bool {
    valid := false;

    switch #complete property.type {
    case .String;
        ~property.value._string = copy_string(config.allocator, value_string);
        valid = true;

    case .Bool;
        result: bool = ---;
        result, valid = string_to_bool(value_string);
        if valid ~property.value._bool = result;

    case .S64;
        result: s64 = ---;
        result, valid = string_to_int(value_string);
        if valid ~property.value._s64 = result;

    case .S32;
        result: s32 = ---;
        result, valid = string_to_int(value_string);
        if valid ~property.value._s32 = result;

    case .U32;
        result: u32 = ---;
        result, valid = string_to_int(value_string);
        if valid ~property.value._u32 = result;

    case .F32;
        result: f32 = ---;
        result, valid = string_to_float(value_string);

        if valid ~property.value._f32 = result;
    }

    return valid;
}

read_property :: (cmdx: *CmdX, config: *Config, line: string, line_count: s64) {
    space, found_space := search_string(line, ' ');
    if !found_space {
        config_error(cmdx, "Malformed config property in line %:", line_count);
        config_error(cmdx, "   Expected syntax 'name value', no space found in the line.");
        return;
    }

    name  := trim_string_right(substring_view(line, 0, space));
    value := trim_string(substring_view(line, space + 1, line.count));
    if value.count > 1 && value[0] == '"' && value[value.count - 1] == '"' value = substring_view(value, 1, value.count - 1);

    if value.count == 0 {
        config_error(cmdx, "Malformed config property in line %:", line_count);
        config_error(cmdx, "   Expected syntax 'name value', no space found in the line.");
        return;
    }

    property := find_property(config, name);
    if !property {
        config_error(cmdx, "Malformed config property in line %:", line_count);
        config_error(cmdx, "   Property name '%' is unknown.", name);
        return;
    }

    valid := assign_property_value_from_string(config, property, value);

    if !valid {
        config_error(cmdx, "Malformed config property in line %:", line_count);
        config_error(cmdx, "   Property value of '%' is not valid, expected a % value.", property.name, property_type_to_string(property.type));
    }
}

read_config_file :: (cmdx: *CmdX, config: *Config, file_path: string) -> bool {
    // Set the proper allocat for both arrays
    config.properties.allocator = config.allocator;
    config.actions.allocator    = config.allocator;
    config.accumulate_errors    = true;

    file_data, found := read_file(file_path);
    if !found return false; // No config file could be found

    // Reset the default values for all properties.
    // Only do this if the config file could indeed be found, since only then the config can successfully be
    // reloaded. If the config file was deleted, then don't do anything (for now).
    for i := 0; i < config.properties.count; ++i {
        property := array_get(*config.properties, i);

        switch #complete property.type {
        case .String; ~property.value._string = copy_string(config.allocator, property.default._string);
        case .Bool;   ~property.value._bool   = property.default._bool;
        case .S64;     ~property.value._s64   = property.default._s64;
        case .S32;     ~property.value._s32   = property.default._s32;
        case .U32;     ~property.value._u32   = property.default._u32;
        case .F32;     ~property.value._f32   = property.default._f32;
        }
    }

    // Start parsing the config file
    original_file_data := file_data;
    defer free_file_content(*original_file_data);

    version_line := get_first_line(*file_data);

    line_count := 1; // Version line was already read

    current_section := Section_Type.Unknown; // Mark as "no section has been encountered yet"

    while file_data.count {
        ++line_count;

        line := get_first_line(*file_data);

        hashtag, found_hashtag := search_string(line, '#');

        if found_hashtag line = substring_view(line, 0, hashtag);

        line = trim_string(line);

        if line.count == 0 continue; // Ignore empty lines. Since the line was already cut with the #-symbol for comments, and trimmed to exclude any trailing whitespace, this will catch any line that does not actually hold some content to parse

        if line[0] == ':' && line[1] == '/' {
            // New section identifier. Try to parse the section type and move on to the next line
            identifier := substring_view(line, 2, line.count);
            if compare_strings(identifier, "general") {
                current_section = .General;
            } else if compare_strings(identifier, "actions") {
                current_section = .Actions;
            } else {
                config_error(cmdx, "Malformed section declaration in line %:", line_count);
                config_error(cmdx, "    Unknown section identifier.");
                current_section = 0;
            }

            continue;
        }

        switch #complete current_section {
        case .General; read_property(cmdx, config, line, line_count);
        case .Actions; read_action(cmdx, config, line, line_count);
        case .Unknown;
            config_error(cmdx, "Malformed config declaration in line %:", line_count);
            config_error(cmdx, "    Expected a section identifier.");
        }
    }

    // Update the last modification time for the config
    file_info, success := get_file_information(file_path);
    if success {
        config.last_modification_check = get_hardware_time();
        config.last_modification_time = file_info.last_modification_time;
    }

    return true;
}

write_config_file :: (config: *Config, file_path: string) {
    delete_file(file_path); // Delete the file to write a fresh version of the config into it

    file_printer: Print_Buffer = ---;
    create_file_printer(*file_printer, file_path);

    bprint(*file_printer, "[1] # version number, do not change\n");
    bprint(*file_printer, ":/general\n");

    for i := 0; i < config.properties.count; ++i {
        // Write property to file
        property := array_get(*config.properties, i);
        bprint(*file_printer, "% ", property.name);

        switch #complete property.type {
        case .String;  bprint(*file_printer, "\"%\"", ~property.value._string);
        case .Bool;    bprint(*file_printer, "%", ~property.value._bool);
        case .S64;     bprint(*file_printer, "%", ~property.value._s64);
        case .S32;     bprint(*file_printer, "%", ~property.value._s32);
        case .U32;     bprint(*file_printer, "%", ~property.value._u32);
        case .F32;     bprint(*file_printer, "%", ~property.value._f32);
        }

        bprint(*file_printer, "\n");
    }

    bprint(*file_printer, "\n");
    bprint(*file_printer, ":/actions\n");

    write_actions_to_file(*config.actions, *file_printer);

    close_file_printer(*file_printer);
}

check_for_config_reload :: (cmdx: *CmdX, config: *Config) {
    current_hardware_time := get_hardware_time();
    time_since_last_check: f32 = xx convert_hardware_time(current_hardware_time - config.last_modification_check, .Milliseconds);

    if time_since_last_check > CONFIG_HOTLOAD_CHECK_INTERVAL {
        file_info, success := get_file_information(CONFIG_FILE_NAME); // @@Speed: Maybe only query the time here, not the complete file information.
        config.last_modification_check = current_hardware_time;

        if success && config.last_modification_time < file_info.last_modification_time {
            // If the file has changed since the last time we read it, then reload the config.
            // This will set the last modification time for this config.
            reload_config(cmdx, false);
        }
    }
}


// Free all allocated data currently in the config file. This is done to avoid memory leaks when reloading
// the config. For now, the only allocated data are string properties.
// The property array is created once at startup with all properties and therefore should not be cleared, only
// data in their values should (since that will be overwritten).
// The action array however is created through reading the config, and should therefore be cleared
free_config_data :: (config: *Config) {
    for i := 0; i < config.properties.count; ++i {
        property := array_get(*config.properties, i);
        if property.type == .String    deallocate_string(config.allocator, property.value._string);
    }

    for i := 0; i < config.actions.count; ++i {
        action := array_get(*config.actions, i);
        free_action(action, config.allocator);
    }

    array_clear(*config.actions);
}

reload_config :: (cmdx: *CmdX, reload_command: bool) {
    // Free and reload the config
    free_config_data(*cmdx.config);
    read_config_file(cmdx, *cmdx.config, CONFIG_FILE_NAME);

    // Now that the values of the config have been updated, we need to actually apply these new values to cmdX.
    apply_config_changes(cmdx);

    flush_config_errors(cmdx, reload_command); // Now display any config errors that may have been encountered during the last parse
    draw_next_frame(cmdx);
}

apply_config_changes :: (cmdx: *CmdX) {
    update_active_theme_pointer(cmdx, cmdx.active_theme_name);
    update_font(cmdx);
    update_backlog_size(cmdx);
    update_history_size(cmdx);

    set_window_position_and_size(*cmdx.window, cmdx.window.xposition, cmdx.window.yposition, cmdx.window.width, cmdx.window.height, cmdx.window.maximized); // The config changes all the attributes of the window directly, but of course changing them does not have an immediate effect, so we need to actually tell win32 about that change
    adjust_screen_rectangles(cmdx);
}


config_error :: (cmdx: *CmdX, format: string, parameters: ..Any) {
    if !cmdx.setup || cmdx.config.accumulate_errors {
        // Since the cmdx backbuffer has not been set up at the time the config gets loaded (since the backbuffer
        // size actually depends on the config, and so on...), we can't just add messages to the backlog.
        // Instead, print them out on the console (in case cmdx actually has a console attached), and add them
        // to a list which will be printed to the actual backbuffer once it has been set up.
        size := query_required_print_buffer_size(format, ..parameters);
        string := allocate_string(Default_Allocator, size);
        mprint(string, format, ..parameters);
        array_add(*cmdx.config.error_messages, string);
    } else {
        set_true_color(cmdx.active_screen, .{ 255, 100, 100, 255 });
        add_formatted_text(cmdx, cmdx.active_screen, format, ..parameters);
        new_line(cmdx, cmdx.active_screen);
        set_themed_color(cmdx.active_screen, .Default);
    }
}

// If the config was loaded in the startup, then the welcome screen has already done a new-line which this
// takes advantage of, therefore no new-line before the errors is needed. However, we would like a new-line
// before the next text input, so do one there.
// If the config was reloaded from a command, it is the other way around. We want a new-line before (which is
// not there), but the command-handling automatically does one after the command, so we do not want one there.
flush_config_errors :: (cmdx: *CmdX, reload_command: bool) -> bool {
    cmdx.config.accumulate_errors = false;

    if !cmdx.config.error_messages.count return false;

    if reload_command new_line(cmdx, cmdx.active_screen);

    set_true_color(cmdx.active_screen, .{ 255, 100, 100, 255 });
    for i := 0; i < cmdx.config.error_messages.count; ++i {
        message := array_get_value(*cmdx.config.error_messages, i);
        add_line(cmdx, cmdx.active_screen, message);
        deallocate_string(Default_Allocator, *message);
    }

    if !reload_command new_line(cmdx, cmdx.active_screen);

    set_themed_color(cmdx.active_screen, .Default);
    array_clear(*cmdx.config.error_messages);

    return true;
}

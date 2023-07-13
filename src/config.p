Section_Type :: enum {
    Unknown;
    General;
    Actions;
}

Property_Type :: enum {
    String;
    Bool;
    S64;
    U32;
}

Property_Value :: union {
    _string:  *string;
    _bool: *bool;
    _s64: *s64;
    _u32: *u32;
}

Property :: struct {
    name: string;
    type: Property_Type;
    value: Property_Value;
}

Config :: struct {
    allocator: *Allocator = Default_Allocator;
    properties: [..]Property;
    actions: [..]Action;

    error_messages: [..]string;
}

property_type_to_string :: (type: Property_Type) -> string {
    result: string = ---;
    
    switch type {
    case .String; result = "String";
    case .Bool; result = "Bool";
    case .S64, .U32; result = "Integer";        
    case; result = "UnknownPropertyType";
    }
    
    return result;
}

create_property_internal :: (config: *Config, name: string, type: Property_Type) -> *Property {
    property := array_push(*config.properties);
    property.name = name;
    property.type = type;
    return property;
}

create_string_property :: (config: *Config, name: string, value: *string, default: string) {
    property := create_property_internal(config, name, .String);
    property.value._string = value;
    ~property.value._string = copy_string(default, config.allocator);
}

create_bool_property :: (config: *Config, name: string, value: *bool, default: bool) {
    property := create_property_internal(config, name, .Bool);
    property.value._bool = value;
    ~property.value._bool = default;
}

create_s64_property :: (config: *Config, name: string, value: *s64, default: s64) {
    property := create_property_internal(config, name, .S64);
    property.value._s64 = value;
    ~property.value._s64 = default;
}

create_u32_property :: (config: *Config, name: string, value: *u32, default: u32) {
    property := create_property_internal(config, name, .U32);
    property.value._u32 = value;
    ~property.value._u32 = default;
}

find_property :: (config: *Config, name: string) -> *Property {
    for i := 0; i < config.properties.count; ++i {
        property := array_get(*config.properties, i);
        if compare_strings(property.name, name) return property;
    }
    
    return null;
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
    
    property := find_property(config, name);
    if !property {
        config_error(cmdx, "Malformed config property in line %:", line_count);
        config_error(cmdx, "   Property name '%' is unknown.", name);
        return;
    }
    
    valid := false;
    
    switch property.type {
    case .String;
        valid = true;
        ~property.value._string = copy_string(value, config.allocator);

    case .Bool; ~property.value._bool, valid = string_to_bool(value);        
    case .S64;  ~property.value._s64, valid  = string_to_int(value);
    case .U32;  ~property.value._u32, valid  = string_to_int(value); 
    }
    
    if !valid {
        config_error(cmdx, "Malformed config property in line %:", line_count);
        config_error(cmdx, "   Property value of '%' is not valid, expected a % value.", property.name, property_type_to_string(property.type));
    }
}

read_config_file :: (cmdx: *CmdX, config: *Config, file_path: string) -> bool {
    config.properties.allocator = config.allocator;
    config.actions.allocator    = config.allocator;

    file_data, found := read_file(file_path);
    if !found return false; // No config file could be found
    
    original_file_data := file_data;
    defer free_file_data(original_file_data);
    
    version_line := get_first_line(*file_data);
    
    line_count := 1; // Version line was already read

    current_section := Section_Type.count; // Mark as "no section has been encountered yet"
    
    while file_data.count {
        ++line_count;
        
        line := get_first_line(*file_data);

        if line.count == 0 || line[0] == '#' continue; // Ignore commented-out lines

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
                current_section = .Unknown;
            }

            continue;
        }

        switch current_section {
        case .Unknown; // If an error occurred while parsing the previous section identifier, silently ignore the line
        case .General; read_property(cmdx, config, line, line_count);
        case .Actions; read_action(cmdx, config, line, line_count);
        }
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
        
        switch property.type {
        case .String;  bprint(*file_printer, ~property.value._string);
        case .Bool;    bprint(*file_printer, "%", ~property.value._bool);
        case .S64;     bprint(*file_printer, "%", ~property.value._s64);
        case .U32;     bprint(*file_printer, "%", ~property.value._u32);
        }
        
        bprint(*file_printer, "\n");
    }

    bprint(*file_printer, "\n");
    bprint(*file_printer, ":/actions\n");

    write_actions_to_file(*config.actions, *file_printer);
    
    close_file_printer(*file_printer);
}



config_error :: (cmdx: *CmdX, format: string, parameters: ..any) {
    // Since the cmdx backbuffer has not been set up at the time the config gets loaded (since the backbuffer
    // size actually depends on the config, and so on...), we can't just add messages to the backlog.
    // Instead, print them out on the console (in case cmdx actually has a console attached), and add them
    // to a list which will be printed to the actual backbuffer once it has been set up.
    size := query_required_print_buffer_size(format, ..parameters);
    string := allocate_string(size, Default_Allocator);
    mprint(string, format, ..parameters);
    print(string);
    array_add(*cmdx.config.error_messages, string);
}

flush_config_errors :: (cmdx: *CmdX) {
    if !cmdx.config.error_messages.count return;

    set_true_color(cmdx, .{ 255, 100, 100, 255 });
    for i := 0; i < cmdx.config.error_messages.count; ++i {
        message := array_get_value(*cmdx.config.error_messages, i);
        add_line(cmdx, message);
        free_string(message, Default_Allocator);
    }

    new_line(cmdx);
    set_themed_color(cmdx, .Default);
    
    array_clear(*cmdx.config.error_messages);
}

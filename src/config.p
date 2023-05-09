Property_Type :: enum {
    String;
    Integer;
}

Property_Value :: union {
    _string: string;
    _integer: s64;
}

Property :: struct {
    name: string;
    type: Property_Type;
    value: Property_Value;
}

Config :: struct {
    properties: [..]Property;
}

create_property :: (config: *Config, name: string, type: Property_Type) -> *Property {
    property := array_push(*config.properties);
    property.name = name;
    property.type = type;
    return property;
}

create_string_property :: (config: *Config, name: string, value: string) {
    property := create_property(config, name, .String);
    property.value._string = value;
}

create_integer_property :: (config: *Config, name: string, value: s64) {
    property := create_property(config, name, .Integer);
    property.value._integer = value;
}

create_default_config :: (config: *Config) {
    create_string_property(config, "theme", "light");
    create_integer_property(config, "font-size", 15);
}

read_config_file :: (cmdx: *CmdX, config: *Config, file_path: string) -> bool {
    file_data, found := read_file(file_path);
    if !found return false; // No config file could be found

    original_file_data := file_data;
    defer free_file_data(original_file_data);

    version_line := get_first_line(*file_data);

    line_count := 1; // Version line was already read
    
    while file_data.count {
        ++line_count;

        line := get_first_line(*file_data);
        if line[0] == ':' continue; // Section line, ignore for now

        space := search_string(line, ' ');
        if space == -1 {
            cmdx_print(cmdx, "Malformed config property in line %:", line_count);
            cmdx_print(cmdx, "   Expected syntax 'name value', no space found in the line.");
            continue;
        }
        
        name  := trim_string_right(substring(line, 0, space));
        value := trim_string(substring(line, space + 1, line.count));

        print("Read property: '%' = '%'\n", name, value);
    }
    
    return true;
}

write_config_file :: (config: *Config, file_path: string) {
    delete_file(file_path); // Delete the file to write a fresh version of the config into it

    file_printer: Print_Buffer = ---;
    create_file_printer(*file_printer, file_path);

    internal_print(*file_printer, "[1] # version number, do not change\n");
    internal_print(*file_printer, ":/general\n", file_path);

    for i := 0; i < config.properties.count; ++i {
        // Write property to file
        property := array_get(*config.properties, i);
        internal_print(*file_printer, "% ", property.name);

        switch property.type {
        case .String;  internal_print(*file_printer, property.value._string);
        case .Integer; internal_print(*file_printer, "%", property.value._integer);
        }
        
        internal_print(*file_printer, "\n");
    }
    
    close_file_printer(*file_printer);
}

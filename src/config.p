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
    allocator: *Allocator = *Default_Allocator;
    properties: [..]Property;
}

property_type_to_string :: (type: Property_Type) -> string {
    result: string = ---;

    switch type {
    case .String; result = "String";
    case .Integer; result = "Integer";
    case; result = "UnknownPropertyType";
    }

    return result;
}

create_property :: (config: *Config, name: string, type: Property_Type) -> *Property {
    property := array_push(*config.properties);
    property.name = name;
    property.type = type;
    return property;
}

find_property :: (config: *Config, name: string) -> *Property {
    for i := 0; i < config.properties.count; ++i {
        property := array_get(*config.properties, i);
        if compare_strings(property.name, name) return property;
    }
    
    print("No property named '%' could be found in the config file.\n", name);
    return null;
}

create_string_property :: (config: *Config, name: string, value: string) {
    property := create_property(config, name, .String);
    property.value._string = copy_string(value, config.allocator);
}

create_integer_property :: (config: *Config, name: string, value: s64) {
    property := create_property(config, name, .Integer);
    property.value._integer = value;
}

get_string_property :: (config: *Config, name: string) -> string {
    property := find_property(config, name);
    if !property return "";

    return property.value._string;
}

get_integer_property :: (config: *Config, name: string) -> s64 {
    property := find_property(config, name);
    if !property return 0;
    
    return property.value._integer;    
}

set_string_property :: (config: *Config, name: string, value: string) {
    property := find_property(config, name);
    if !property return;

    free_string(property.value._string, config.allocator);
    property.value._string = copy_string(value, config.allocator);
}

set_integer_property :: (config: *Config, name: string, value: s64) {
    property := find_property(config, name);
    if !property return;

    property.value._integer = value;
}

create_default_config :: (config: *Config) {
    create_string_property(config, "theme", "light");
    create_integer_property(config, "font-size", 15);
}

read_config_file :: (cmdx: *CmdX, config: *Config, file_path: string) -> bool {
    // Create all properties in this config, so that the default values for everything is already there.
    // The values set in the config file the override the default values.
    create_default_config(config);

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

        property := find_property(config, name);
        if !property {
            cmdx_print(cmdx, "Malformed config property in line %:", line_count);
            cmdx_print(cmdx, "   Property name '%' is unknown.", name);
            continue;
        }

        valid := false;
        
        switch property.type {
        case .String;
            valid = true;
            property.value._string = copy_string(value, config.allocator);
            
        case .Integer;
            valid = true;
            for i := 0; i < value.count; ++i {
                valid &= is_digit_character(value[i]);
            }            

            if valid property.value._integer = string_to_int(value);
        }

        if !valid {
            cmdx_print(cmdx, "Malformed config property in line %:", line_count);
            cmdx_print(cmdx, "   Property value of '%' is not valid, expected a % value.", property.name, property_type_to_string(property.type));
        }
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

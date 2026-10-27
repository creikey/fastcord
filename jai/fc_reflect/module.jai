#import "Basic";
enum_name_from_value :: (v: $E) -> string, bool {
    info := type_info(E);
    for info.values if it == cast(s64) v return info.names[it_index], true;
    return "", false;
}
enum_from_name :: ($E: Type, name: string) -> E, bool {
    info := type_info(E);
    for info.names if it == name return cast(E) info.values[it_index], true;
    return cast(E) 0, false;
}

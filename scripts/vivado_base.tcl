proc parse_config {{conf_file "board.config"}} {
    set conf [dict create]
    if [catch {open $conf_file r} fh] {
        puts "Cannot open '$conf_file'. Perhaps the file does not exist or is not readable?\n"
    } else {
        foreach line [split [read $fh] \n] {
            set line [regsub {#.*} $line ""]                            ; # Remove from the first #, if any, through the end of the line
            set line [string trim $line]                                ; # Remove trailing and leading white spaces (spaces, tabs, newlines, and carriage returns)
            if {[string compare $line ""] != 0} {                       ; # If non-blank line
                set part_meta  [split $line ":"]
                set key        [string trim [lindex $part_meta 0]]
                set val        [string trim [lindex $part_meta 1]]
                if {[dict exists $conf $key] == 1} {
                    puts "ERROR: Duplicate key ($key) detected in '$conf_file'"
                    puts "       You must use unique key's for each line."
                    exit 1
                }
                dict append conf $key $val
            }
        }
        close $fh
    }
    return $conf
}

proc get_variant {{conf_file "board.config"}} {
    set board_config [parse_config $conf_file]
    if {[dict exists $board_config memory] == 0} { ; # key does not exist, i.e. a line in the partition index file with this key does not exist
        puts "ERROR: Cannot locate key 'memory' in the build config file"
        exit 1
    }
    return [dict get $board_config memory]
}

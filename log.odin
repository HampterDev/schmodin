package main

import "core:fmt"
import "core:os"

log_file: os.Handle

log :: proc(msg: string) {
    fmt.println(msg)
    if log_file != os.INVALID_HANDLE {
        os.write_string(log_file, msg)
        os.write_string(log_file, "\n")
    }
}

log_fmt :: proc(format: string, args: ..any) {
    msg := fmt.tprintf(format, ..args)
    fmt.println(msg)
    if log_file != os.INVALID_HANDLE {
        os.write_string(log_file, msg)
        os.write_string(log_file, "\n")
    }
}

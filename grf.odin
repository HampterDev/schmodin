package main

import "core:bytes"
import "core:compress/zlib"
import "core:fmt"
import "core:os"
import "core:sys/windows"

// GRF format constants
GRF_HEADER_SIGNATURE: [15]u8 : {'M', 'a', 's', 't', 'e', 'r', ' ', 'o', 'f', ' ', 'M', 'a', 'g', 'i', 'c'}
GRF_HEADER_SIZE :: 46
GRF_FILELIST_TYPE_FILE :: 0x01
GRF_FILELIST_TYPE_ENCRYPT_MIXED :: 0x02
GRF_FILELIST_TYPE_ENCRYPT_HEADER :: 0x04

// GRF file header - 46 bytes
Grf_Header :: struct #packed {
    signature:         [15]u8,  // "Master of Magic"
    key:               [15]u8,  // Encryption key (usually zeroed)
    file_table_offset: u32,     // Offset to compressed file table
    seed:              u32,     // Seed value
    file_count:        u32,     // Number of files (adjusted by version)
    version:           u32,     // GRF version (0x200 for 2.0)
}

// GRF file entry (after decompression)
Grf_File_Entry :: struct {
    file_name:            string,
    compressed_size:      u32,  // Compressed size
    compressed_size_align: u32, // Compressed size aligned (bytes to read)
    original_size:        u32,  // Original uncompressed size
    flags:                u8,   // File type flags
    offset:               u32,  // Offset in GRF file (from start)
}

// GRF archive reader
Grf :: struct {
    file_handle: os.Handle,
    file_size:   i64,
    header:      Grf_Header,
    file_table:  map[string]Grf_File_Entry,
    is_open:     bool,
}

// Create a new GRF reader
grf_create :: proc() -> Grf {
    return Grf{
        file_handle = os.INVALID_HANDLE,
        is_open = false,
    }
}

// Open a GRF file
grf_open :: proc(grf: ^Grf, path: string) -> bool {
    grf_close(grf)

    handle, err := os.open(path, os.O_RDONLY)
    if err != os.ERROR_NONE {
        fmt.eprintln("Failed to open GRF file:", path)
        return false
    }

    grf.file_handle = handle

    // Get file size
    size, size_err := os.file_size(handle)
    if size_err != os.ERROR_NONE {
        os.close(handle)
        grf.file_handle = os.INVALID_HANDLE
        return false
    }
    grf.file_size = size

    // Read header
    if !grf_read_header(grf) {
        grf_close(grf)
        return false
    }

    // Read file table
    if !grf_read_file_table(grf) {
        grf_close(grf)
        return false
    }

    grf.is_open = true
    fmt.println("GRF opened successfully:", len(grf.file_table), "files")
    return true
}

// Close the GRF file
grf_close :: proc(grf: ^Grf) {
    if grf.file_handle != os.INVALID_HANDLE {
        os.close(grf.file_handle)
        grf.file_handle = os.INVALID_HANDLE
    }

    // Free all allocated file names in the table
    for key, _ in grf.file_table {
        delete(key)
    }
    delete(grf.file_table)
    grf.file_table = {}

    grf.is_open = false
    grf.header = {}
}

// Read GRF header
grf_read_header :: proc(grf: ^Grf) -> bool {
    header_bytes: [GRF_HEADER_SIZE]u8

    os.seek(grf.file_handle, 0, os.SEEK_SET)
    bytes_read, read_err := os.read(grf.file_handle, header_bytes[:])
    if read_err != os.ERROR_NONE || bytes_read != GRF_HEADER_SIZE {
        fmt.eprintln("Failed to read GRF header")
        return false
    }

    // Copy to header struct
    grf.header = (cast(^Grf_Header)&header_bytes[0])^

    // Verify signature
    if grf.header.signature != GRF_HEADER_SIGNATURE {
        fmt.eprintln("Invalid GRF signature")
        return false
    }

    // Only support GRF version 0x200 (2.0)
    if grf.header.version != 0x200 {
        fmt.eprintln("Unsupported GRF version:", grf.header.version)
        return false
    }

    return true
}

// Read and parse file table
grf_read_file_table :: proc(grf: ^Grf) -> bool {
    // File count in GRF 2.0: stored value - seed - 7
    file_count := grf.header.file_count - grf.header.seed - 7

    // File table offset needs GRF_HEADER_SIZE added
    table_offset := i64(grf.header.file_table_offset) + GRF_HEADER_SIZE

    // Read compressed/uncompressed sizes (8 bytes)
    os.seek(grf.file_handle, table_offset, os.SEEK_SET)
    size_data: [8]u8
    bytes_read, err := os.read(grf.file_handle, size_data[:])
    if err != os.ERROR_NONE || bytes_read != 8 {
        fmt.eprintln("Failed to read file table sizes")
        return false
    }

    compressed_size := (cast(^u32)&size_data[0])^
    original_size := (cast(^u32)&size_data[4])^

    // Read compressed table data
    compressed_data := make([]u8, compressed_size)
    defer delete(compressed_data)

    os.seek(grf.file_handle, table_offset + 8, os.SEEK_SET)
    bytes_read, err = os.read(grf.file_handle, compressed_data)
    if err != os.ERROR_NONE || u32(bytes_read) != compressed_size {
        fmt.eprintln("Failed to read compressed file table")
        return false
    }

    // Decompress file table
    table_data := make([]u8, original_size + 8) // Extra padding
    defer delete(table_data)

    if !grf_decompress(compressed_data, table_data[:original_size]) {
        fmt.eprintln("Failed to decompress file table")
        return false
    }

    // Parse file entries
    ptr: u32 = 0
    for i: u32 = 0; i < file_count && ptr < original_size; i += 1 {
        // Read null-terminated filename
        name_start := ptr
        for ptr < original_size && table_data[ptr] != 0 {
            ptr += 1
        }
        if ptr >= original_size {
            break
        }

        file_name_bytes := table_data[name_start:ptr]
        ptr += 1 // Skip null terminator

        // Read file info (17 bytes: 4+4+4+1+4)
        if ptr + 17 > original_size {
            break
        }

        entry: Grf_File_Entry
        entry.compressed_size = (cast(^u32)&table_data[ptr])^
        ptr += 4
        entry.compressed_size_align = (cast(^u32)&table_data[ptr])^
        ptr += 4
        entry.original_size = (cast(^u32)&table_data[ptr])^
        ptr += 4
        entry.flags = table_data[ptr]
        ptr += 1
        entry.offset = (cast(^u32)&table_data[ptr])^ + GRF_HEADER_SIZE
        ptr += 4

        // Only add actual files (not directories)
        if entry.flags & GRF_FILELIST_TYPE_FILE != 0 {
            // Normalize and store the path
            normalized := grf_normalize_path(file_name_bytes)
            entry.file_name = normalized
            grf.file_table[normalized] = entry
        }
    }

    return true
}

// Decompress data using zlib
grf_decompress :: proc(compressed: []u8, output: []u8) -> bool {
    buf: bytes.Buffer
    defer bytes.buffer_destroy(&buf)

    err := zlib.inflate(compressed, &buf, expected_output_size = len(output))
    if err != nil {
        fmt.eprintln("Zlib decompression error:", err)
        return false
    }

    // Copy decompressed data to output
    decompressed := bytes.buffer_to_bytes(&buf)
    if len(decompressed) != len(output) {
        fmt.eprintln("Decompression size mismatch:", len(decompressed), "vs", len(output))
        return false
    }
    copy(output, decompressed)

    return true
}

// Normalize path (convert slashes and lowercase ASCII)
grf_normalize_path :: proc(path_bytes: []u8) -> string {
    result := make([]u8, len(path_bytes))
    copy(result, path_bytes)

    for i := 0; i < len(result); i += 1 {
        c := result[i]
        // Convert forward slashes to backslashes
        if c == '/' {
            result[i] = '\\'
        }
        // Lowercase ASCII only (preserve Korean CP949 bytes)
        if c >= 'A' && c <= 'Z' {
            result[i] = c + 32
        }
    }

    return string(result)
}

// Convert CP949 (Korean) to UTF-8 string using Windows API
cp949_to_utf8 :: proc(cp949_bytes: []u8) -> (string, bool) {
    if len(cp949_bytes) == 0 {
        return "", true
    }

    // Check if it's pure ASCII (no conversion needed)
    is_ascii := true
    for c in cp949_bytes {
        if c > 127 {
            is_ascii = false
            break
        }
    }
    if is_ascii {
        result := make([]u8, len(cp949_bytes))
        copy(result, cp949_bytes)
        return string(result), true
    }

    // Convert CP949 to wide string (UTF-16)
    CP949 :: 949
    wide_len := windows.MultiByteToWideChar(
        CP949, 0,
        raw_data(cp949_bytes), i32(len(cp949_bytes)),
        nil, 0,
    )
    if wide_len == 0 {
        return "", false
    }

    wide_str := make([]u16, wide_len)
    defer delete(wide_str)

    windows.MultiByteToWideChar(
        CP949, 0,
        raw_data(cp949_bytes), i32(len(cp949_bytes)),
        raw_data(wide_str), wide_len,
    )

    // Convert wide string to UTF-8
    utf8_len := windows.WideCharToMultiByte(
        windows.CP_UTF8, 0,
        raw_data(wide_str), wide_len,
        nil, 0,
        nil, nil,
    )
    if utf8_len == 0 {
        return "", false
    }

    utf8_str := make([]u8, utf8_len)
    windows.WideCharToMultiByte(
        windows.CP_UTF8, 0,
        raw_data(wide_str), wide_len,
        raw_data(utf8_str), utf8_len,
        nil, nil,
    )

    return string(utf8_str), true
}

// Convert UTF-8 string to CP949 (Korean) encoding using Windows API
utf8_to_cp949 :: proc(utf8_str: string) -> ([]u8, bool) {
    if len(utf8_str) == 0 {
        return nil, true
    }

    // Check if it's pure ASCII (no conversion needed)
    is_ascii := true
    for c in utf8_str {
        if c > 127 {
            is_ascii = false
            break
        }
    }
    if is_ascii {
        result := make([]u8, len(utf8_str))
        copy(result, transmute([]u8)utf8_str)
        return result, true
    }

    // Convert UTF-8 to wide string (UTF-16)
    utf8_bytes := transmute([]u8)utf8_str
    wide_len := windows.MultiByteToWideChar(
        windows.CP_UTF8, 0,
        raw_data(utf8_bytes), i32(len(utf8_bytes)),
        nil, 0,
    )
    if wide_len == 0 {
        return nil, false
    }

    wide_str := make([]u16, wide_len)
    defer delete(wide_str)

    windows.MultiByteToWideChar(
        windows.CP_UTF8, 0,
        raw_data(utf8_bytes), i32(len(utf8_bytes)),
        raw_data(wide_str), wide_len,
    )

    // Convert wide string to CP949
    CP949 :: 949
    cp949_len := windows.WideCharToMultiByte(
        CP949, 0,
        raw_data(wide_str), wide_len,
        nil, 0,
        nil, nil,
    )
    if cp949_len == 0 {
        return nil, false
    }

    cp949_str := make([]u8, cp949_len)
    windows.WideCharToMultiByte(
        CP949, 0,
        raw_data(wide_str), wide_len,
        raw_data(cp949_str), cp949_len,
        nil, nil,
    )

    return cp949_str, true
}

// Normalize a query path (for lookups) - handles UTF-8 to CP949 conversion
grf_normalize_query :: proc(path: string) -> string {
    // Convert UTF-8 to CP949 if needed (for Korean paths)
    cp949_bytes, ok := utf8_to_cp949(path)
    if !ok {
        // Fallback: use path as-is
        result := make([]u8, len(path))
        copy(result, transmute([]u8)path)
        cp949_bytes = result
    }

    // Normalize slashes and lowercase ASCII
    for i := 0; i < len(cp949_bytes); i += 1 {
        c := cp949_bytes[i]
        if c == '/' {
            cp949_bytes[i] = '\\'
        }
        if c >= 'A' && c <= 'Z' {
            cp949_bytes[i] = c + 32
        }
    }

    return string(cp949_bytes)
}

// Normalize a CP949 path (for paths read from resource files in the GRF)
// Does NOT convert encoding - just normalizes slashes and lowercase
grf_normalize_cp949 :: proc(path: string) -> string {
    result := make([]u8, len(path))
    copy(result, transmute([]u8)path)

    for i := 0; i < len(result); i += 1 {
        c := result[i]
        if c == '/' {
            result[i] = '\\'
        }
        if c >= 'A' && c <= 'Z' {
            result[i] = c + 32
        }
    }

    return string(result)
}

// Check if file exists in GRF (handles both CP949 and UTF-8 paths transparently)
grf_has_file :: proc(grf: ^Grf, file_name: string) -> bool {
    if !grf.is_open {
        return false
    }

    // First try as CP949 (common case: paths from resource files)
    normalized := grf_normalize_cp949(file_name)
    if normalized in grf.file_table {
        delete(normalized)
        return true
    }
    delete(normalized)

    // If not found, try converting from UTF-8 (paths from source code)
    normalized = grf_normalize_query(file_name)
    defer delete(normalized)
    return normalized in grf.file_table
}

// Internal: read file data given a normalized path
@(private)
grf_get_data_internal :: proc(grf: ^Grf, normalized: string) -> (data: []u8, ok: bool) {
    entry, found := grf.file_table[normalized]
    if !found {
        return nil, false
    }

    if entry.original_size == 0 {
        return nil, false
    }

    // Read compressed data from GRF
    read_size := entry.compressed_size_align
    compressed_data := make([]u8, read_size)
    defer delete(compressed_data)

    os.seek(grf.file_handle, i64(entry.offset), os.SEEK_SET)
    bytes_read, err := os.read(grf.file_handle, compressed_data)
    if err != os.ERROR_NONE || u32(bytes_read) != read_size {
        return nil, false
    }

    // Allocate output buffer
    output := make([]u8, entry.original_size)

    // Check if data needs decompression
    if entry.flags & GRF_FILELIST_TYPE_FILE != 0 {
        // Decompress using compressed_size (not read_size)
        if !grf_decompress(compressed_data[:entry.compressed_size], output) {
            delete(output)
            return nil, false
        }
    } else {
        // Uncompressed - just copy
        copy(output, compressed_data[:entry.original_size])
    }

    return output, true
}

// Get file data from GRF (handles both CP949 and UTF-8 paths transparently)
// Caller must delete the returned slice
grf_get_data :: proc(grf: ^Grf, file_name: string) -> (data: []u8, ok: bool) {
    if !grf.is_open {
        return nil, false
    }

    // First try as CP949 (common case: paths from resource files)
    normalized := grf_normalize_cp949(file_name)
    if normalized in grf.file_table {
        data, ok = grf_get_data_internal(grf, normalized)
        delete(normalized)
        return data, ok
    }
    delete(normalized)

    // If not found, try converting from UTF-8 (paths from source code)
    normalized = grf_normalize_query(file_name)
    defer delete(normalized)
    return grf_get_data_internal(grf, normalized)
}

// GRF Manager - holds multiple GRF files
Grf_Manager :: struct {
    grfs: [dynamic]Grf,
}

// Create a new GRF manager
grf_manager_create :: proc() -> Grf_Manager {
    return Grf_Manager{}
}

// Destroy GRF manager and close all GRFs
grf_manager_destroy :: proc(mgr: ^Grf_Manager) {
    for &grf in mgr.grfs {
        grf_close(&grf)
    }
    delete(mgr.grfs)
}

// Add a GRF file to the manager
grf_manager_add :: proc(mgr: ^Grf_Manager, path: string) -> bool {
    grf := grf_create()
    if !grf_open(&grf, path) {
        return false
    }
    append(&mgr.grfs, grf)
    return true
}

// Check if file exists in any GRF (handles both CP949 and UTF-8 paths)
grf_manager_has_file :: proc(mgr: ^Grf_Manager, file_name: string) -> bool {
    for &grf in mgr.grfs {
        if grf_has_file(&grf, file_name) {
            return true
        }
    }
    return false
}

// Get file data from first GRF that contains it (handles both CP949 and UTF-8 paths)
grf_manager_get_data :: proc(mgr: ^Grf_Manager, file_name: string) -> (data: []u8, ok: bool) {
    for &grf in mgr.grfs {
        if grf_has_file(&grf, file_name) {
            return grf_get_data(&grf, file_name)
        }
    }
    return nil, false
}

// Test function to verify GRF reading works
test_grf :: proc() {
    fmt.println("=== GRF Test ===")

    grf := grf_create()
    defer grf_close(&grf)

    // Try to open data.grf from the ragnarok folder
    if !grf_open(&grf, "ragnarok/data.grf") {
        fmt.println("Could not open ragnarok/data.grf - skipping GRF test")
        return
    }

    // Try to read a test file
    test_file := "data\\texture\\gevent\\getop_04.bmp"
    if grf_has_file(&grf, test_file) {
        data, ok := grf_get_data(&grf, test_file)
        if ok {
            fmt.printf("Read %s: %d bytes, header: %c%c\n",
                       test_file, len(data), data[0], data[1])
            delete(data)
        }
    }

    // Show some Korean filenames properly converted to UTF-8
    fmt.println("Sample files (Korean paths converted to UTF-8):")
    count := 0
    for name, entry in grf.file_table {
        if count >= 5 {
            break
        }
        // Convert CP949 filename to UTF-8 for display
        utf8_name, ok := cp949_to_utf8(transmute([]u8)name)
        if ok {
            fmt.printf("  %s (%d bytes)\n", utf8_name, entry.original_size)
            delete(utf8_name)
        }
        count += 1
    }

    fmt.println("=== GRF Test Complete ===")
}

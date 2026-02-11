package main

import "core:math"

Walkability_Grid :: struct {
    walkable: []bool,
    width:    i32,
    height:   i32,
    zoom:     f32,
}

walkability_extract :: proc(gnd: ^GND_Ground) -> Walkability_Grid {
    count := int(gnd.width * gnd.height)
    grid := Walkability_Grid{
        walkable = make([]bool, count),
        width    = gnd.width,
        height   = gnd.height,
        zoom     = gnd.zoom,
    }

    for i := 0; i < count; i += 1 {
        grid.walkable[i] = gnd.cells[i].top_surface_id >= 0
    }

    return grid
}

walkability_destroy :: proc(grid: ^Walkability_Grid) {
    if grid.walkable != nil {
        delete(grid.walkable)
        grid.walkable = nil
    }
    grid.width = 0
    grid.height = 0
}

walkability_is_walkable :: proc(grid: ^Walkability_Grid, cell_x, cell_y: i32) -> bool {
    if cell_x < 0 || cell_x >= grid.width || cell_y < 0 || cell_y >= grid.height {
        return false
    }
    return grid.walkable[cell_y * grid.width + cell_x]
}

world_to_cell :: proc(grid: ^Walkability_Grid, world_x, world_z: f32) -> (i32, i32) {
    cx := i32(math.floor(world_x / grid.zoom))
    cy := i32(math.floor(world_z / grid.zoom))
    return cx, cy
}

cell_to_world :: proc(grid: ^Walkability_Grid, cell_x, cell_y: i32) -> Vec3 {
    return Vec3{
        (f32(cell_x) + 0.5) * grid.zoom,
        0,
        (f32(cell_y) + 0.5) * grid.zoom,
    }
}

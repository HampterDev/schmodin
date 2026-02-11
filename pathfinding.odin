package main

import "core:math"

Cell_Pos :: struct {
    x, y: i32,
}

// A* pathfinding on walkability grid. Returns path from start to goal (caller must delete), nil if unreachable.
pathfind :: proc(grid: ^Walkability_Grid, start, goal: Cell_Pos) -> []Cell_Pos {
    if !walkability_is_walkable(grid, goal.x, goal.y) do return nil
    if start.x == goal.x && start.y == goal.y do return nil

    SQRT2 :: f32(1.41421356)
    width := grid.width
    total := int(grid.width * grid.height)

    // Node storage
    g_score := make([]f32, total)
    defer delete(g_score)
    came_from := make([]i32, total)  // flat index of parent, -1 = none
    defer delete(came_from)
    closed := make([]bool, total)
    defer delete(closed)

    for i := 0; i < total; i += 1 {
        g_score[i] = max(f32) / 2
        came_from[i] = -1
    }

    flat :: proc(x, y, w: i32) -> i32 { return y * w + x }

    heuristic :: proc(a, b: Cell_Pos) -> f32 {
        dx := math.abs(f32(a.x - b.x))
        dy := math.abs(f32(a.y - b.y))
        return max(dx, dy) + (1.41421356 - 1.0) * min(dx, dy)
    }

    // Open set as simple sorted dynamic array (by f-score ascending)
    Open_Entry :: struct {
        pos:   Cell_Pos,
        f:     f32,
    }
    open := make([dynamic]Open_Entry)
    defer delete(open)

    start_idx := flat(start.x, start.y, width)
    g_score[start_idx] = 0

    append(&open, Open_Entry{start, heuristic(start, goal)})

    // 8 directions: dx, dy pairs
    dirs := [8][2]i32{
        {1, 0}, {-1, 0}, {0, 1}, {0, -1},  // cardinal
        {1, 1}, {1, -1}, {-1, 1}, {-1, -1},  // diagonal
    }

    for len(open) > 0 {
        // Pop entry with lowest f-score (last element, since sorted descending)
        current := open[len(open) - 1]
        ordered_remove(&open, len(open) - 1)

        cx, cy := current.pos.x, current.pos.y
        ci := flat(cx, cy, width)

        if closed[ci] do continue
        closed[ci] = true

        if cx == goal.x && cy == goal.y {
            // Reconstruct path
            path := make([dynamic]Cell_Pos)
            idx := ci
            for idx != -1 {
                px := idx % width
                py := idx / width
                append(&path, Cell_Pos{px, py})
                idx = i32(came_from[idx])
            }
            // Reverse
            result := make([]Cell_Pos, len(path))
            for i := 0; i < len(path); i += 1 {
                result[i] = path[len(path) - 1 - i]
            }
            delete(path)
            return result
        }

        for di in 0..<8 {
            nx := cx + dirs[di][0]
            ny := cy + dirs[di][1]

            if !walkability_is_walkable(grid, nx, ny) do continue

            // Diagonal: check both adjacent cardinal cells (no corner-cutting)
            if di >= 4 {
                if !walkability_is_walkable(grid, cx + dirs[di][0], cy) do continue
                if !walkability_is_walkable(grid, cx, cy + dirs[di][1]) do continue
            }

            ni := flat(nx, ny, width)
            if closed[ni] do continue

            cost: f32 = 1.0 if di < 4 else SQRT2
            tentative_g := g_score[ci] + cost

            if tentative_g < g_score[ni] {
                g_score[ni] = tentative_g
                came_from[ni] = i32(ci)
                f := tentative_g + heuristic(Cell_Pos{nx, ny}, goal)

                // Insert sorted (descending so we pop from end)
                inserted := false
                for i := 0; i < len(open); i += 1 {
                    if open[i].f <= f {
                        inject_at(&open, i, Open_Entry{Cell_Pos{nx, ny}, f})
                        inserted = true
                        break
                    }
                }
                if !inserted {
                    append(&open, Open_Entry{Cell_Pos{nx, ny}, f})
                }
            }
        }
    }

    return nil  // No path found
}

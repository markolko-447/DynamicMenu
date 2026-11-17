//
//  Log.swift
//  DynamicMenu
//
//  Unified logging. Read with:
//    log show --last 10m --predicate 'subsystem == "Markolko-s-Group.DynamicMenu"' --info
//

import OSLog

nonisolated enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "DynamicMenu"
    static let shelf = Logger(subsystem: subsystem, category: "Shelf")
}

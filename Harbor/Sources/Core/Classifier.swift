import Foundation

enum Kind: Sendable { case dev, other, hidden }

enum Classifier {
    static let devNames: Set<String> = [
        "node", "bun", "deno", "ruby", "php", "java", "go", "cargo", "vite", "next", "esbuild", "electron",
        "npm", "pnpm", "yarn", "tsx", "ts-node", "uvicorn", "gunicorn", "flask", "rails", "puma", "hugo",
        "jekyll", "dotnet", "rustc", "air", "webpack", "parcel", "astro", "nuxt", "php-fpm", "caddy", "ruby3",
    ]

    static func databaseAddress(_ row: PortRow) -> String? {
        guard [5432, 3306, 6379, 27017].contains(row.port) ||
              ["postgres", "mysqld", "redis-server", "mongod"].contains(row.name.lowercased()) else { return nil }
        return "localhost:\(row.port)"
    }

    static func classify(_ row: PortRow, home: String = NSHomeDirectory()) -> Kind {
        if row.container != nil { return .dev }
        let path = row.exePath
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") { return .hidden }
        let name = row.name.lowercased()
        if devNames.contains(name) || name.hasPrefix("python") { return .dev }
        // App bundles are apps, even when launched from a project folder.
        if path.contains(".app/") { return .other }
        let cwd = row.cwd
        if (cwd == home || cwd.hasPrefix(home + "/")) && !cwd.hasPrefix(home + "/Library") { return .dev }
        return .other
    }
}

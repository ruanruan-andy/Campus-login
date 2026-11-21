import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))

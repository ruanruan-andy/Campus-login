import AppKit
import CoreWLAN
import CoreLocation
import Darwin
import Security
import LocalAuthentication
import SwiftUI

enum Service: String, Codable, CaseIterable, Identifiable {
    case campus, mobile, unicom, telecom

    var id: Self { self }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        let name = try value.decode(String.self)
        if name == "other" {
            self = .campus
        } else if let service = Self(rawValue: name) {
            self = service
        } else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unrecognized campus service")
        }
    }

    var label: String {
        switch self {
        case .campus: "校园网"
        case .mobile: "中国移动"
        case .unicom: "中国联通"
        case .telecom: "中国电信"
        }
    }

    var suffix: String {
        switch self {
        case .campus: ""
        case .mobile: "@zgyd"
        case .unicom: "@cucc"
        case .telecom: "@ctc"
        }
    }
}

struct Server: Codable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var sshAlias = ""
    var username = ""
    var service = Service.campus
    var isLocal: Bool? = false
    var automatic: Bool? = false
    var intervalMinutes: Int? = 5
    var autoJoinCampusWiFi: Bool? = false

}

struct KeychainFailure: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "钥匙串错误码 \(status)"
    }
}

enum Passwords {
    static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.campus-login.portal",
            kSecAttrAccount as String: id.uuidString,
            kSecAttrSynchronizable as String: false
        ]
    }

    static func read(_ id: UUID, interactive: Bool = true) throws -> String? {
        var lookup = query(id)
        lookup[kSecReturnData as String] = true
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            lookup[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KeychainFailure(status: errSecDecode)
        }
        return password
    }

    static func deleteAll() throws {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.campus-login.portal",
            kSecAttrSynchronizable as String: false
        ]
        let status = SecItemDelete(lookup as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainFailure(status: status)
        }
    }

    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainFailure(status: status)
        }
    }

    static func save(_ password: String, for id: UUID) throws {
        let lookup = query(id)
        let data = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(lookup as CFDictionary, data as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(lookup.merging(data) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    }
}

enum Outcome: String, Decodable, Sendable {
    case online, restored, offline, credentialsRequired = "credentials_required"
    case portalChanged = "portal_changed", portalError = "portal_error"
    case authenticationFailed = "authentication_failed", acceptedOffline = "accepted_offline"
    case sshFailed, localNetwork, sshKey, remoteError, timedOut, wifiFailed

    var title: String {
        switch self {
        case .online: "已联网"
        case .restored: "外网已恢复"
        case .offline: "外网不可用"
        case .credentialsRequired: "需要登录校园网"
        case .portalChanged: "无法识别认证页面"
        case .portalError: "校园网网关异常"
        case .authenticationFailed: "校园网登录失败"
        case .acceptedOffline: "认证已通过"
        case .sshFailed: "SSH 连接失败"
        case .localNetwork: "无法连接服务器"
        case .sshKey: "SSH 密钥未通过认证"
        case .remoteError: "服务器命令执行失败"
        case .timedOut: "请求超时"
        case .wifiFailed: "校园 Wi-Fi 未就绪"
        }
    }

    var detail: String {
        switch self {
        case .online, .restored: "服务器已通过直连方式访问外网。"
        case .offline: "服务器无法访问外网，也没有检测到校园网认证页面。"
        case .credentialsRequired: "请在「编辑」中确认校园网账号、密码和运营商，再点「登录校园网」。"
        case .portalChanged: "此版本支持苏州大学的 Dr.COM 认证网关。"
        case .portalError: "无法访问校园网网关，或网关返回了无法识别的响应。"
        case .authenticationFailed: "请核对该服务器使用的校园网账号、密码和运营商。"
        case .acceptedOffline: "网关已接受登录，但外网检查仍未通过。"
        case .sshFailed: "请在终端检查 SSH 别名、主机密钥和密钥认证。"
        case .localNetwork: "请到「系统设置 → 隐私与安全性 → 本地网络」确认此应用有访问权限，再重试。"
        case .sshKey: "请在终端解锁 SSH 密钥，或将密钥添加到 macOS 的 SSH 代理后重试。"
        case .remoteError: "SSH 命令未返回结果。请确认服务器已安装 python3 和 curl。"
        case .timedOut: "所选服务器未能在规定时间内完成检查。"
        case .wifiFailed: "请确认 Wi-Fi 已开启、SUDA_WIFI 在信号范围内，并允许本应用使用定位服务。"
        }
    }

    var success: Bool { self == .online || self == .restored }
}

struct ServerResult: Decodable, Sendable {
    let outcome: Outcome
    var detail: String?

    static func read(_ data: Data) -> Self? {
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        let decoder = JSONDecoder()
        return lines.reversed().lazy.compactMap { try? decoder.decode(Self.self, from: Data($0.utf8)) }.first
    }
}

@MainActor
final class WiFiLocationPermission: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WiFiLocationPermission()
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorized: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    func request() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
}

enum CampusWiFi {
    static let ssid = "SUDA_WIFI"

    private static func hasAddress(_ name: String) -> Bool {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return false }
        defer { freeifaddrs(addresses) }
        var current = addresses
        while let entry = current {
            let item = entry.pointee
            if String(cString: item.ifa_name) == name,
               let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
                let number = UInt32(bigEndian: ipv4.sin_addr.s_addr)
                if number != 0 && number >> 16 != 0xA9FE { return true }
            }
            current = item.ifa_next
        }
        return false
    }

    /// A nil result means Wi-Fi association and DHCP are ready for portal checking.
    static func prepare() -> ServerResult? {
        guard let interface = CWWiFiClient.shared().interface(),
              let name = interface.interfaceName else {
            return ServerResult(outcome: .wifiFailed, detail: "未找到可用的 Wi-Fi 网卡。")
        }
        guard interface.powerOn() else {
            return ServerResult(outcome: .wifiFailed, detail: "请先开启 Mac 的 Wi-Fi，再重试。")
        }
        do {
            if interface.ssid() != ssid {
                let networks = try interface.scanForNetworks(withSSID: Data(ssid.utf8))
                guard let network = networks
                    .filter({ $0.ssid == ssid })
                    .max(by: { $0.rssiValue < $1.rssiValue }) else {
                    return ServerResult(outcome: .wifiFailed, detail: "未发现 SUDA_WIFI，请确认校园 Wi-Fi 在信号范围内。")
                }
                try interface.associate(to: network, password: nil)
            }
            let deadline = Date().addingTimeInterval(15)
            repeat {
                if interface.ssid() == ssid && hasAddress(name) { return nil }
                Thread.sleep(forTimeInterval: 0.5)
            } while Date() < deadline
            return ServerResult(outcome: .wifiFailed, detail: "连接 SUDA_WIFI 后尚未获得有效网络地址，请稍后重试。")
        } catch {
            return ServerResult(outcome: .wifiFailed, detail: "连接 SUDA_WIFI 失败：" + error.localizedDescription)
        }
    }
}

enum CampusSSH {
    struct Credentials: Encodable {
        let username: String
        let password: String
        let suffix: String
    }

    static func run(_ server: Server, password: String?) -> ServerResult {
        guard let scriptURL = Bundle.main.url(forResource: "portal", withExtension: "py"),
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let payload = try? JSONEncoder().encode(Credentials(
                username: server.username, password: password ?? "", suffix: server.service.suffix
              )) else { return ServerResult(outcome: .remoteError) }

        let command = "python3 -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=7",
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=yes", "-o", "ClearAllForwardings=yes",
            "--", server.sshAlias, command
        ]
        if server.isLocal == true {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", script]
        }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            return ServerResult(outcome: .sshFailed)
        }

        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 52, execute: timeout)
        defer { timeout.cancel() }

        do {
            try input.fileHandleForWriting.write(contentsOf: payload)
        } catch {
            // An SSH failure can close stdin before the payload is written.
        }
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationReason == .uncaughtSignal { return ServerResult(outcome: .timedOut) }
        if process.terminationStatus == 255 {
            let diagnostic = String(decoding: data, as: UTF8.self).lowercased()
            if diagnostic.contains("permission denied (publickey") { return ServerResult(outcome: .sshKey) }
            if ["no route to host", "operation not permitted", "network is unreachable"].contains(where: diagnostic.contains) {
                return ServerResult(outcome: .localNetwork)
            }
            return ServerResult(outcome: .sshFailed)
        }
        guard process.terminationStatus == 0 else { return ServerResult(outcome: .remoteError) }
        return ServerResult.read(data) ?? ServerResult(outcome: .remoteError)
    }
}

@MainActor
struct MainView: View {
    @AppStorage("servers") private var savedServers = Data()
    @AppStorage("selectedServer") private var savedSelection = ""
    @State private var servers = [Server]()
    @State private var selection: UUID?
    @State private var editor: Server?
    @State private var deletion: Server?
    @State private var outcomes = [UUID: ServerResult]()
    @State private var active: UUID?
    @State private var errorMessage: String?
    @State private var lastChecks = [UUID: Date]()
    @State private var automaticPaused = false
    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var selected: Server? { servers.first { $0.id == selection } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                Text("服务器")
                    .font(.headline)
                    .padding(.horizontal, 12)

                List(selection: $selection) {
                    ForEach(servers) { server in
                        Label(server.name, systemImage: server.isLocal == true ? "laptopcomputer" : "server.rack")
                            .lineLimit(1)
                            .tag(server.id)
                            .contextMenu {
                                Button("编辑…") { editor = server }
                                Button("删除服务器…", role: .destructive) { deletion = server }
                            }
                            .disabled(active != nil)
                    }
                    .onMove { source, destination in
                        servers.move(fromOffsets: source, toOffset: destination)
                        persist()
                    }
                    .moveDisabled(active != nil)
                }
                .listStyle(.sidebar)

                Button {
                    editor = Server()
                } label: {
                    Label("添加服务器", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 11)
                .disabled(active != nil)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 18)
            .frame(width: 176)
            .background(.regularMaterial)

            Divider()

            if let server = selected {
                detail(for: server)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack").font(.largeTitle).foregroundStyle(.secondary)
                    Text("添加服务器后即可登录校园网").foregroundStyle(.secondary)
                    Button("添加服务器") { editor = Server() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 590, idealWidth: 625, minHeight: 335, idealHeight: 370)
        .onAppear {
            guard servers.isEmpty else { return }
            servers = (try? JSONDecoder().decode([Server].self, from: savedServers)) ?? []
            persist()
            selection = servers.first { $0.id.uuidString == savedSelection }?.id ?? servers.first?.id
        }
        .onReceive(timer) { _ in
            guard active == nil, !automaticPaused else { return }
            let now = Date()
            if let server = servers.first(where: {
                $0.automatic == true &&
                now.timeIntervalSince(lastChecks[$0.id] ?? .distantPast) >= Double($0.intervalMinutes ?? 5) * 60
            }) {
                connect(server, authenticate: true, automatic: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pauseCampusAutomatic)) { _ in
            automaticPaused.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearCampusData)) { _ in
            guard active == nil else {
                errorMessage = "请等待当前联网检查结束后再清除数据。"
                return
            }
            let wasPaused = automaticPaused
            automaticPaused = true
            let alert = NSAlert()
            alert.messageText = "清除全部数据并退出？"
            alert.informativeText = "将永久删除所有设备配置、校园网账号和本应用保存的钥匙串密码。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "清除并退出")
            guard alert.runModal() == .alertSecondButtonReturn else {
                automaticPaused = wasPaused
                return
            }
            do {
                try Passwords.deleteAll()
                servers = []
                selection = nil
                outcomes = [:]
                lastChecks = [:]
                savedServers = Data()
                savedSelection = ""
                if let identifier = Bundle.main.bundleIdentifier {
                    UserDefaults.standard.removePersistentDomain(forName: identifier)
                }
                NSApplication.shared.terminate(nil)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .onChange(of: selection) { savedSelection = $0?.uuidString ?? "" }
        .sheet(item: $editor) { server in
            EditorView(server: server, existing: servers.contains { $0.id == server.id }, save: save)
        }
        .confirmationDialog("删除服务器？", isPresented: Binding(
            get: { deletion != nil },
            set: { if !$0 { deletion = nil } }
        ), titleVisibility: .visible) {
            Button("删除服务器", role: .destructive) {
                guard let server = deletion else { return }
                do {
                    try Passwords.delete(server.id)
                    servers.removeAll { $0.id == server.id }
                    outcomes[server.id] = nil
                    if selection == server.id { selection = servers.first?.id }
                    persist()
                } catch {
                    errorMessage = error.localizedDescription
                }
                deletion = nil
            }
            Button("取消", role: .cancel) { deletion = nil }
        } message: {
            Text("将删除「\(deletion?.name ?? "")」的配置和已保存的校园网密码。")
        }
        .alert("钥匙串操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func detail(for server: Server) -> some View {
        let result = outcomes[server.id]
        let outcome = result?.outcome
        let isWorking = active == server.id
        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.name).font(.system(size: 32, weight: .semibold))
                    Text(server.isLocal == true ? "本机网络" : "SSH · " + server.sshAlias).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("编辑…") { editor = server }
                    .disabled(active != nil)
            }

            HStack(alignment: .top, spacing: 13) {
                if isWorking {
                    ProgressView().controlSize(.small).frame(width: 23)
                } else {
                    Image(systemName: outcome?.success == true ? "checkmark.circle.fill" :
                        outcome == nil ? "network" : "exclamationmark.circle")
                        .font(.title3)
                        .frame(width: 23)
                        .foregroundStyle(outcome?.success == true ? Color.green : Color.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(isWorking ? "正在检查服务器…" : outcome?.title ?? "等待检查")
                        .font(.headline)
                    Text(isWorking ? (server.isLocal == true ? "正在检查本机网络。" : "正在通过 SSH 连接 \(server.name)。") :
                        result?.detail ?? outcome?.detail ?? "可以检查联网状态，或登录校园网。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(15)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 4) {
                if let checked = lastChecks[server.id] {
                    Text("最近检查 " + checked.formatted(date: .omitted, time: .standard))
                }
                if server.isLocal == true && server.autoJoinCampusWiFi == true {
                    Text("自动连接 SUDA_WIFI")
                }
                if server.automatic == true {
                    Text(automaticPaused ? "自动联网已暂停" : "每 \(server.intervalMinutes ?? 5) 分钟检查并自动联网")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack {
                Button("登录校园网") { connect(server, authenticate: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("检查连接") { connect(server, authenticate: false) }
            }
            .controlSize(.large)
            .disabled(active != nil)
        }
        .padding(23)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) { savedServers = data }
    }

    private func save(_ server: Server, _ password: String) throws {
        if !password.isEmpty { try Passwords.save(password, for: server.id) }
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        outcomes[server.id] = nil
        persist()
        selection = server.id
    }

    private func connect(_ server: Server, authenticate: Bool, automatic: Bool = false) {
        let joinWiFi = server.isLocal == true && server.autoJoinCampusWiFi == true
        if joinWiFi && !WiFiLocationPermission.shared.authorized {
            if !automatic { WiFiLocationPermission.shared.request() }
            outcomes[server.id] = ServerResult(
                outcome: .wifiFailed,
                detail: "识别 SUDA_WIFI 需要定位权限。请在系统设置中允许本应用使用定位服务，再重试。"
            )
            lastChecks[server.id] = Date()
            return
        }
        active = server.id
        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    if joinWiFi, let failure = CampusWiFi.prepare() { return failure }
                    let check = CampusSSH.run(server, password: nil)
                    guard authenticate, check.outcome == .credentialsRequired, !server.username.isEmpty else { return check }
                    let password = try Passwords.read(server.id, interactive: !automatic)
                    return CampusSSH.run(server, password: password)
                }.value
                outcomes[server.id] = outcome
            } catch {
                if automatic {
                    outcomes[server.id] = ServerResult(outcome: .credentialsRequired, detail: "自动联网无法读取密码，请手动登录并完成钥匙串授权。")
                } else {
                    errorMessage = error.localizedDescription
                }
            }
            lastChecks[server.id] = Date()
            active = nil
        }
    }
}

enum SSHConfiguration {
    static func aliases() -> [String] {
        var visited = Set<String>()
        var result = Set<String>()

        func read(_ path: String, depth: Int) {
            guard depth < 12, visited.insert(path).inserted,
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            for line in content.components(separatedBy: .newlines) {
                let clean = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                let fields = clean.replacingOccurrences(of: "=", with: " ")
                    .split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard let key = fields.first?.lowercased() else { continue }
                let values = fields.dropFirst()
                if key == "host" {
                    for alias in values where alias.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil {
                        result.insert(alias)
                    }
                }
                if key == "include" {
                    for value in values {
                        let expanded = (value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) as NSString).expandingTildeInPath
                        let absolute = expanded.hasPrefix("/") ? expanded :
                            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh").appendingPathComponent(expanded).path
                        var matches = glob_t()
                        if glob(absolute, 0, nil, &matches) == 0 {
                            for index in 0..<Int(matches.gl_pathc) {
                                if let item = matches.gl_pathv[index] {
                                    read(String(cString: item), depth: depth + 1)
                                }
                            }
                        }
                        globfree(&matches)
                    }
                }
            }
        }

        read(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config").path, depth: 0)
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

struct EditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var server: Server
    let existing: Bool
    let save: (Server, String) throws -> Void
    @State private var password = ""
    @State private var showPassword = false
    @State private var sshAliases = [String]()
    @State private var failure: String?

    private var validAlias: Bool {
        sshAliases.contains(server.sshAlias)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(existing ? "编辑服务器" : "添加服务器").font(.title2.bold())
            Form {
                Toggle("本机 Mac", isOn: Binding(
                    get: { server.isLocal == true }, set: { server.isLocal = $0 }
                ))
                if server.isLocal != true {
                    TextField("名称", text: $server.name)
                    Picker("SSH 配置", selection: $server.sshAlias) {
                        Text("请选择服务器").tag("")
                        if !server.sshAlias.isEmpty && !sshAliases.contains(server.sshAlias) {
                            Text(server.sshAlias + "（配置中已不存在）").tag(server.sshAlias)
                        }
                        ForEach(sshAliases, id: \.self) { alias in
                            Text(alias).tag(alias)
                        }
                    }
                    if sshAliases.isEmpty {
                        Text("未找到 SSH 主机，请先在 ~/.ssh/config 中配置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if server.isLocal == true {
                    Toggle("自动连接 SUDA_WIFI", isOn: Binding(
                        get: { server.autoJoinCampusWiFi == true },
                        set: {
                            server.autoJoinCampusWiFi = $0
                            if $0 { WiFiLocationPermission.shared.request() }
                        }
                    ))
                    if server.autoJoinCampusWiFi == true {
                        Text("登录和定时检查时会切换到 SUDA_WIFI，需要定位权限识别网络。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField("校园网账号", text: $server.username)
                HStack {
                    Group {
                        if showPassword {
                            TextField("校园网密码", text: $password)
                        } else {
                            SecureField("校园网密码", text: $password)
                        }
                    }
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showPassword ? "隐藏密码" : "显示密码")
                    .accessibilityLabel(showPassword ? "隐藏密码" : "显示密码")
                }
                Picker("运营商", selection: $server.service) {
                    ForEach(Service.allCases) { service in
                        Text(service.label).tag(service)
                    }
                }
                Toggle("定时检查并自动联网", isOn: Binding(
                    get: { server.automatic == true }, set: { server.automatic = $0 }
                ))
                if server.automatic == true {
                    HStack {
                        TextField("检查间隔", value: Binding(
                            get: { server.intervalMinutes ?? 5 },
                            set: { server.intervalMinutes = $0 }
                        ), format: .number.grouping(.never))
                        Text("分钟").foregroundStyle(.secondary)
                    }
                    if (server.intervalMinutes ?? 5) < 1 {
                        Text("检查间隔至少为 1 分钟。").font(.caption).foregroundStyle(.red)
                    }
                }
            }

            Text("密码保存在 macOS 钥匙串中。服务器与学校认证网关之间使用 HTTP。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text(failure).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    server.name = server.isLocal == true ? "本机 Mac" : server.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    server.username = server.username.trimmingCharacters(in: .whitespacesAndNewlines)
                    do {
                        try save(server, password)
                        dismiss()
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((server.isLocal != true && (!validAlias || server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) || (server.automatic == true && (server.intervalMinutes ?? 5) < 1))
            }
        }
        .padding(23)
        .frame(width: 465)
        .onAppear {
            sshAliases = SSHConfiguration.aliases()
            guard existing else { return }
            do {
                password = try Passwords.read(server.id) ?? ""
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

extension Notification.Name {
    static let pauseCampusAutomatic = Notification.Name("pauseCampusAutomatic")
    static let clearCampusData = Notification.Name("clearCampusData")
}

final class CampusAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidBecomeActive(_ notification: Notification) {
        for window in NSApplication.shared.windows where window.identifier?.rawValue == "main" {
            window.delegate = self
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct CampusMenu: View {
    @Environment(\.openWindow) private var openWindow
    @State private var paused = false

    var body: some View {
        Button("打开校园网登录") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button(paused ? "恢复自动联网" : "暂停自动联网") {
            paused.toggle()
            NotificationCenter.default.post(name: .pauseCampusAutomatic, object: nil)
        }
        Divider()
        Button("清除全部数据并退出…") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .clearCampusData, object: nil)
        }
        Button("退出") { NSApplication.shared.terminate(nil) }
    }
}

@main
struct CampusLoginApp: App {
    @NSApplicationDelegateAdaptor(CampusAppDelegate.self) private var appDelegate
    init() {
        signal(SIGPIPE, SIG_IGN)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        Window("校园网登录", id: "main") {
            MainView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(before: .appTermination) {
                Button("清除全部数据并退出…") {
                    NotificationCenter.default.post(name: .clearCampusData, object: nil)
                }
            }
        }
        MenuBarExtra("校园网登录", systemImage: "network") {
            CampusMenu()
        }
    }
}

import AppKit
import Foundation

struct UpdateInfo: Equatable {
    let version: String
    let zipURL: URL
    let pageURL: URL
}

enum UpdateState: Equatable {
    case none
    case available(UpdateInfo)
    case installing(UpdateInfo)
    case failed(UpdateInfo, String)
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Обновление из GitHub Releases: спросить последнюю версию, скачать zip, подменить .app, перезапуститься.
enum Updater {
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? ProcessInfo.processInfo.environment["DEMOSUFLER_VERSION"] ?? "0"
    }

    /// Адрес ленты можно подменить для проверки: DEMOSUFLER_FEED=file:///…/latest.json
    private static var feedOverride: URL? {
        ProcessInfo.processInfo.environment["DEMOSUFLER_FEED"].flatMap { URL(string: $0) }
    }

    /// Сравнение версий вида 1.2.3 (буква v в начале не мешает).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.drop(while: { !$0.isNumber }).split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Приложение может заменить само себя, только если лежит в обычной папке, куда можно писать.
    /// Из образа .dmg и из «карантинной» копии macOS (AppTranslocation) это не получится.
    static var canSelfUpdate: Bool {
        let app = Bundle.main.bundleURL
        if app.pathExtension != "app" { return false }
        if app.path.contains("/AppTranslocation/") { return false }
        return FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    /// Возвращает описание обновления, если в последнем релизе версия новее текущей.
    static func check() async -> UpdateInfo? {
        if let feed = feedOverride { return await checkFeed(feed) }

        // Ask the releases page, not the GitHub API. The page "releases/latest" redirects to the
        // page of the newest release, and its address ends with the version tag. The API would
        // tell the same, but it allows only 60 anonymous requests an hour per network address:
        // on a shared network (a campus, an office) that runs out and updates silently stop.
        var request = URLRequest(url: Config.releasesPage, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let landed = response.url, landed.scheme == "https", landed.host == "github.com",
              let marker = landed.path.range(of: "/\(Config.repo)/releases/tag/")
        else { return nil }
        let tag = String(landed.path[marker.upperBound...])
        guard !tag.isEmpty, !tag.contains("/"), isNewer(tag, than: currentVersion),
              let encoded = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let zipURL = URL(string: "https://github.com/\(Config.repo)/releases/download/\(encoded)/\(Config.zipAssetName)")
        else { return nil }
        return UpdateInfo(version: String(tag.drop(while: { !$0.isNumber })), zipURL: zipURL, pageURL: Config.releasesPage)
    }

    /// The test feed: a JSON file shaped like the GitHub API answer for a release.
    private static func checkFeed(_ feed: URL) async -> UpdateInfo? {
        let request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              isNewer(tag, than: currentVersion),
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == Config.zipAssetName }),
              let link = asset["browser_download_url"] as? String,
              let zipURL = URL(string: link)
        else { return nil }
        return UpdateInfo(version: String(tag.drop(while: { !$0.isNumber })), zipURL: zipURL, pageURL: Config.releasesPage)
    }

    /// Скачивает архив, проверяет его и кладёт новую версию на место текущей.
    static func install(_ info: UpdateInfo) async throws {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL
        guard canSelfUpdate else {
            throw UpdateError(tr("Move demosufler to Applications and run it from there", "Перенеси demosufler в «Программы» и запусти оттуда"))
        }

        let work = fm.temporaryDirectory.appendingPathComponent("demosufler-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let (downloaded, response) = try await URLSession.shared.download(from: info.zipURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError(tr("GitHub answered \(http.statusCode)", "GitHub ответил \(http.statusCode)"))
        }
        let zip = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: downloaded, to: zip)

        let unpacked = work.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])

        // В архиве приложение всегда называется одинаково, даже если пользователь переименовал своё.
        let newApp = unpacked.appendingPathComponent("demosufler.app")
        guard let plist = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              plist["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let newVersion = plist["CFBundleShortVersionString"] as? String,
              isNewer(newVersion, than: currentVersion)
        else {
            throw UpdateError(tr("The archive holds a different version of demosufler", "В архиве не та версия demosufler"))
        }
        // Подпись должна быть целой: архив не побился и не был изменён после сборки.
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        // And it has to come from the same signer as the app that is running.
        guard signedLikeThisApp(newApp) else {
            throw UpdateError(tr("The update is signed by someone else", "Обновление подписано кем-то другим"))
        }

        let backup = work.appendingPathComponent("previous.app")
        try fm.moveItem(at: appURL, to: backup)
        do {
            try fm.moveItem(at: newApp, to: appURL)
        } catch {
            try? fm.moveItem(at: backup, to: appURL)
            throw error
        }
        try? fm.removeItem(at: work)
    }

    /// true when `app` satisfies the designated requirement of the running app, that is, when it
    /// was signed with the same identity. A build with a one-off local signature has nothing to
    /// compare with, so it accepts any intact build.
    static func signedLikeThisApp(_ app: URL) -> Bool {
        var running: SecCode?
        var mine: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &mine) == errSecSuccess, let mine else { return true }
        var info: CFDictionary?
        SecCodeCopySigningInformation(mine, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let flags = ((info as? [String: Any])?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let adHoc: UInt32 = 0x2
        var requirement: SecRequirement?
        guard flags & adHoc == 0, (info as? [String: Any])?[kSecCodeInfoCertificates as String] != nil,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement else {
            return true
        }
        var other: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &other) == errSecSuccess, let other else { return false }
        return SecStaticCodeCheckValidity(other, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }

    /// Запускает новую копию после выхода текущей.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw UpdateError(tr("The archive did not pass the check", "Не прошла проверка архива") + " (\(URL(fileURLWithPath: tool).lastPathComponent))")
        }
    }
}

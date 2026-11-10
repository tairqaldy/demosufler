import Foundation

enum Config {
    /// Репозиторий, из релизов которого приложение берёт обновления.
    static let repo = "tairqaldy/demosufler"
    /// Имя архива с приложением в каждом релизе.
    static let zipAssetName = "demosufler.zip"

    static var latestReleaseAPI: URL { URL(string: "https://api.github.com/repos/\(repo)/releases/latest")! }
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }
}

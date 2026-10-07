import ArgumentParser
import Foundation
import MacOSInstallerKit

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show every macOS version that can be downloaded or reused."
    )

    @Flag(name: .long, help: "Skip Apple's catalog and use only softwareupdate and local installers.")
    var offline = false

    func run() async throws {
        let fetcher = URLSessionDataFetcher()
        let runner = RealCommandRunner()

        var sources: [any InstallerSource] = [
            LocalInstallerSource(),
            SoftwareUpdateSource(runner: runner),
        ]
        if !offline {
            sources.append(SucatalogSource(fetcher: fetcher))
        }

        let result = await ReleaseCatalog(sources: sources).allReleases()

        print(ReleaseTableFormatter.render(result.releases))

        for failure in result.failures {
            FileHandle.standardError.write(Data("warning: source unavailable — \(failure)\n".utf8))
        }
    }
}

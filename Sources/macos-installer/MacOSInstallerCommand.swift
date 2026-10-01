import ArgumentParser

@main
struct MacOSInstallerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macos-installer",
        abstract: "Create a bootable offline macOS installer on an external drive.",
        subcommands: [ListCommand.self, CreateCommand.self],
        defaultSubcommand: ListCommand.self
    )
}

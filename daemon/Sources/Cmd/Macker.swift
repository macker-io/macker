import ArgumentParser
import ContainerEngine

struct Macker: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: Invocation.commandName,
        abstract: "CLI for the Macker daemon (Docker-compatible client).",
        discussion: """
        Talks to the daemon at \(DaemonPaths.defaultHostURL).
        Independent of the system `docker` binary. Invoking this tool as `docker`
        (symlink or alias) enables the same command surface.
        """,
        version: DaemonAPI.clientVersion,
        subcommands: [
            Setup.self, FetchRuntime.self, Doctor.self, Status.self,
            Pull.self, Push.self, Images.self, Rmi.self, Tag.self, History.self, Search.self,
            Inspect.self, Save.self, Load.self, Build.self,
            Ps.self, Run.self, Create.self, Start.self, Stop.self, Restart.self, Kill.self,
            Rm.self, Pause.self, Unpause.self, Rename.self, Logs.self, Wait.self, Top.self, Stats.self,
            Exec.self, Version.self, Info.self, Events.self,
            ImageGroup.self, ContainerGroup.self, VolumeGroup.self, NetworkGroup.self, SystemGroup.self,
        ]
    )
}

import ArgumentParser
import ContainerEngine

public struct Macker: ParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: Invocation.commandName,
        abstract: "CLI for the Macker daemon (Docker-compatible client).",
        discussion: """
        Talks to the daemon at \(DaemonPaths.defaultHostURL).
        Independent of the system `docker` binary. Invoking this tool as `docker`
        (symlink or alias) enables the same command surface.
        """,
        version: DaemonAPI.clientVersion,
        subcommands: [
            Setup.self, FetchRuntime.self, Doctor.self, Status.self, HelperGroup.self,
            Login.self, Logout.self,
            Pull.self, Push.self, Images.self, Rmi.self, Tag.self, History.self, Search.self,
            Inspect.self, Save.self, Load.self, Import.self, Build.self,
            Ps.self, Run.self, Create.self, Start.self, Stop.self, Restart.self, Update.self, Kill.self,
            Rm.self, Pause.self, Unpause.self, Rename.self, Logs.self, Wait.self, Top.self, Stats.self,
            Attach.self, Exec.self, Cp.self, Export.self, Diff.self, Commit.self, Port.self, Version.self, Info.self, Events.self,
            ImageGroup.self, ContainerGroup.self, VolumeGroup.self, NetworkGroup.self, SystemGroup.self,
            BuilderGroup.self,
            PluginGroup.self, CheckpointGroup.self, ContextGroup.self, ManifestGroup.self, TrustGroup.self,
            SwarmGroup.self, NodeGroup.self, ServiceGroup.self, SecretGroup.self, ConfigGroup.self, StackGroup.self,
        ],
        helpNames: [.long]
    )
}

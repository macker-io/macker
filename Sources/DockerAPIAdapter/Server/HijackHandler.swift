import Foundation
import NIOCore
import NIOWebSocket

/// Raw TCP stream after Docker `Upgrade: tcp` hijack.
final class TCPHijackHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let session: DockerHijack
    private var closed = false

    init(session: DockerHijack) {
        self.session = session
    }

    func handlerAdded(context: ChannelHandlerContext) {
        pumpOutput(channel: context.channel)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard let onStdin = session.onStdin else { return }
        let bytes = Data(buffer.readableBytesView)
        Task { await onStdin(bytes) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
    }

    private func pumpOutput(channel: Channel) {
        let session = self.session
        Task {
            for await chunk in session.output {
                try? await channel.eventLoop.submit {
                    guard channel.isActive else { return }
                    channel.writeAndFlush(chunk, promise: nil)
                }.get()
            }
            try? await channel.eventLoop.submit {
                guard channel.isActive else { return }
                channel.close(promise: nil)
            }.get()
            self.finish()
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        let onClose = session.onClose
        Task { await onClose() }
    }
}

/// WebSocket frames for `GET /containers/{id}/attach/ws`.
final class AttachWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let session: DockerHijack
    private var closed = false

    init(session: DockerHijack) {
        self.session = session
    }

    func handlerAdded(context: ChannelHandlerContext) {
        pumpOutput(context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .binary:
            if let onStdin = session.onStdin {
                let bytes = Data(frame.unmaskedData.readableBytesView)
                Task { await onStdin(bytes) }
            }
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            context.close(promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
    }

    private func pumpOutput(context: ChannelHandlerContext) {
        let channel = context.channel
        let session = self.session
        Task {
            for await chunk in session.output {
                try? await channel.eventLoop.submit {
                    guard channel.isActive else { return }
                    let frame = WebSocketFrame(fin: true, opcode: .binary, data: chunk)
                    channel.writeAndFlush(frame, promise: nil)
                }.get()
            }
            try? await channel.eventLoop.submit {
                guard channel.isActive else { return }
                channel.close(promise: nil)
            }.get()
            self.finish()
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        let onClose = session.onClose
        Task { await onClose() }
    }
}

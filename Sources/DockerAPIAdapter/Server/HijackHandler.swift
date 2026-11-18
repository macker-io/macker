import Foundation
import NIOCore
import NIOWebSocket

/// Raw TCP stream after Docker `Upgrade: tcp` hijack.
///
/// Inbound bytes are raw stdin (never framed, even without a TTY). A write-side shutdown
/// from the client is stdin EOF; output keeps flowing until the session ends.
final class TCPHijackHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum StdinEvent: Sendable {
        case data(Data)
        case closed
    }

    private let session: DockerHijack
    private let stdin: AsyncStream<StdinEvent>.Continuation
    private var closed = false

    init(session: DockerHijack) {
        self.session = session
        let (events, continuation) = AsyncStream<StdinEvent>.makeStream()
        self.stdin = continuation
        // One consumer keeps stdin ordered and puts EOF after the last byte.
        Task {
            for await event in events {
                switch event {
                case .data(let bytes):
                    await session.onStdin?(bytes)
                case .closed:
                    await session.onStdinClosed?()
                }
            }
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        pumpOutput(channel: context.channel)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard session.onStdin != nil else { return }
        stdin.yield(.data(Data(buffer.readableBytesView)))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            stdin.yield(.closed)
            stdin.finish()
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        stdin.finish()
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

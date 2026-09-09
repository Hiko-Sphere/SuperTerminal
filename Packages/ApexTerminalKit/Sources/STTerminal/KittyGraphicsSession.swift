import Foundation

/// What a Kitty graphics command asks the terminal to do (D-065).
public enum KittyOutcome: Sendable, Equatable {
    /// Nothing to do — a chunk that is not the last one, or a command with no effect.
    case none
    /// Keep the picture under this id without drawing it.
    case store(TerminalImage, id: Int?)
    /// Draw it at the cursor. `columns`/`rows` are the sender's `c`/`r`, when it gave them.
    case display(id: Int, columns: Int?, rows: Int?, movesCursor: Bool)
    /// Store it and draw it, which is what `a=T` means.
    case storeAndDisplay(TerminalImage, id: Int?, columns: Int?, rows: Int?, movesCursor: Bool)
    /// Forget one picture, or all of them.
    case delete(id: Int?)
    /// A reply the sender is waiting for, as the text between `APC G` and `ST`.
    case respond(String)
}

/// The state Kitty's protocol needs between commands (D-065).
///
/// A picture arrives in chunks — `m=1` on every piece but the last — so something has to hold
/// the pieces. That something is bounded: a sender that starts a hundred transfers and
/// finishes none must not be able to fill the device with them.
public struct KittyGraphicsSession: Sendable {
    /// The most a single transfer may accumulate before it is abandoned.
    public static let maximumTransferBytes = 32 << 20
    /// How many unfinished transfers may be held at once.
    public static let maximumPendingTransfers = 8

    private struct Transfer {
        var keys: [String: String]
        var payload: [UInt8]
    }

    private var pending: [Int: Transfer] = [:]
    private var order: [Int] = []

    public init() {}

    /// Applies one command, returning what the terminal should do about it.
    public mutating func handle(_ command: KittyCommand) -> KittyOutcome {
        switch command.action {
        case .query:
            // `a=q` asks whether this terminal speaks the protocol. Answering is the whole
            // point: a program that gets no answer falls back to something else.
            return reply(to: command, body: "OK")
        case .delete:
            return delete(command)
        case .transmit, .transmitAndDisplay:
            return receive(command)
        case .display:
            guard let id = command.integer("i"), id > 0 else { return reply(to: command, body: "ENOENT:no image id") }
            return .display(
                id: id,
                columns: command.integer("c"),
                rows: command.integer("r"),
                movesCursor: command.string("C") != "1"
            )
        case .animationFrame, .animationControl, .compose:
            // Animation is a protocol of its own on top of this one. Saying so is better
            // than dropping the sequence: the sender can choose a still image instead.
            return reply(to: command, body: "ENOTSUPPORTED:animation is not implemented")
        }
    }

    // MARK: - Transmission

    private mutating func receive(_ command: KittyCommand) -> KittyOutcome {
        // Only the direct medium can work here. `t=f`, `t=t` and `t=s` name a file, a
        // temporary file or a shared-memory object — on the machine running the program,
        // which over SSH is the server. This app is not on it.
        if let medium = command.string("t"), medium != "d" {
            return reply(to: command, body: "ENOTSUPPORTED:only direct transmission is available over a network connection")
        }

        let key = command.integer("i") ?? -(command.integer("I") ?? 0)
        var transfer = pending[key] ?? Transfer(keys: [:], payload: [])
        // The first chunk carries the description; later ones carry only `m` and data.
        for (name, value) in command.keys where transfer.keys[name] == nil {
            transfer.keys[name] = value
        }
        transfer.payload.append(contentsOf: command.payload)

        guard transfer.payload.count <= Self.maximumTransferBytes else {
            forget(key)
            return reply(to: command, body: "EFBIG:image is larger than this terminal will hold")
        }

        if command.integer("m") == 1 {
            if pending[key] == nil {
                if order.count >= Self.maximumPendingTransfers, let oldest = order.first { forget(oldest) }
                order.append(key)
            }
            pending[key] = transfer
            return .none
        }

        forget(key)
        return finish(transfer, command: command)
    }

    private mutating func finish(_ transfer: Transfer, command: KittyCommand) -> KittyOutcome {
        let merged = KittyCommand(keys: transfer.keys, payload: transfer.payload)
        // No `i=` means the sender does not intend to refer to it again; the store gives
        // it a number of its own.
        let id = merged.integer("i")
        do {
            let image = try KittyImageDecoder.decode(merged)
            let displays = merged.action == .transmitAndDisplay
            if displays {
                return .storeAndDisplay(
                    image,
                    id: id,
                    columns: merged.integer("c"),
                    rows: merged.integer("r"),
                    movesCursor: merged.string("C") != "1"
                )
            }
            return .store(image, id: id)
        } catch {
            return reply(to: command, body: "EINVAL:\(KittyImageDecoder.describe(error))")
        }
    }

    private mutating func forget(_ key: Int) {
        pending.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    // MARK: - Deletion

    private mutating func delete(_ command: KittyCommand) -> KittyOutcome {
        switch command.string("d")?.lowercased() {
        case "i":
            return .delete(id: command.integer("i"))
        case "a", nil:
            return .delete(id: nil)
        default:
            // The other deletion selectors address pictures by where they are on screen,
            // which this terminal does not index. Deleting everything would be worse than
            // saying so.
            return reply(to: command, body: "ENOTSUPPORTED:only deleting by id or all is implemented")
        }
    }

    // MARK: - Replies

    /// `q=1` asks for silence on success, `q=2` for silence on failure too. A sender that
    /// asked for quiet and gets chatter has escape sequences printed into its output.
    private func reply(to command: KittyCommand, body: String) -> KittyOutcome {
        let quiet = command.integer("q") ?? 0
        let isError = body != "OK"
        if quiet >= 2 || (quiet == 1 && !isError) { return .none }
        let id = command.integer("i") ?? 0
        return .respond(id > 0 ? "i=\(id);\(body)" : body)
    }
}

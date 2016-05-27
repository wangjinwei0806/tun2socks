import Foundation
import lwip

public protocol TSTCPSocketDelegate: class {
    /**
     The socket is closed on local side (FIN received), which means we will not read data anymore.
     */
    func localDidClose(socket: TSTCPSocket)

    /**
     The socket is reseted (RST received), it should be released now.
     */
    func socketDidReset(socket: TSTCPSocket)

    /**
     The socket is aborted (RST sent). I do not know when will this happen, but just release it.
     */
    func socketDidAbort(socket: TSTCPSocket)

    /**
     The socket can be released now. This will only be triggered if the socket is closed actively by calling `close()`.
     */
    func socketDidClose(socket: TSTCPSocket)


    func didReadData(data: NSData, from: TSTCPSocket)

    /**
     The socket has sent the specific length of data.

     - parameter length: The length of data being ACKed.
     - parameter from:   The socket.
     */
    func didWriteData(length: Int, from: TSTCPSocket)
}

// There is no way the error will be anything but ERR_OK, so the `error` parameter should be ignored.
func tcp_recv_func(arg: UnsafeMutablePointer<Void>, pcb: UnsafeMutablePointer<tcp_pcb>, buf: UnsafeMutablePointer<pbuf>, error: err_t) -> err_t {
    guard let socket = SocketDict.lookup(UnsafeMutablePointer<SocketIdentity>(arg).memory) else {
        // we do not know what this socket is, abort it
        tcp_abort(pcb)
        return err_t(ERR_ABRT)
    }
    socket.recved(buf)
    return err_t(ERR_OK)
}

func tcp_sent_func(arg: UnsafeMutablePointer<Void>, pcb: UnsafeMutablePointer<tcp_pcb>, len: UInt16) -> err_t {
    guard let socket = SocketDict.lookup(UnsafeMutablePointer<SocketIdentity>(arg).memory) else {
        // we do not know what this socket is, abort it
        tcp_abort(pcb)
        return err_t(ERR_ABRT)
    }
    socket.sent(Int(len))
    return err_t(ERR_OK)
}

func tcp_err_func(arg: UnsafeMutablePointer<Void>, error: err_t) {
    SocketDict.lookup(UnsafeMutablePointer<SocketIdentity>(arg).memory)?.errored(error)
}

class SocketDict {
    static var socketDict = [SocketIdentity:TSTCPSocket]()

    static func lookup(id: SocketIdentity) -> TSTCPSocket? {
        return socketDict[id]
    }
}

struct SocketIdentity: Hashable {
    let id: Int

    var hashValue: Int {
        return id
    }
}

func ==(left: SocketIdentity, right: SocketIdentity) -> Bool {
    return left.id == right.id
}

/**
 Unless one of `socketDidReset`, `socketDidAbort` or `socketDidClose` is called, please do `close()`the socket actively and wait for `socketDidClose` before releasing it.
 */
public class TSTCPSocket {
    private var pcb: UnsafeMutablePointer<tcp_pcb>
    public let sourceAddress: in_addr
    public let destinationAddress: in_addr
    public let sourcePort: UInt16
    public let destinationPort: UInt16
    let queue: dispatch_queue_t
    private var identity: SocketIdentity

    var invalid: Bool {
        return pcb == nil
    }

    public var connected: Bool {
        return !invalid && pcb.memory.state.rawValue >= ESTABLISHED.rawValue && pcb.memory.state.rawValue < CLOSED.rawValue
    }

    public weak var delegate: TSTCPSocketDelegate?

    init(pcb: UnsafeMutablePointer<tcp_pcb>, queue: dispatch_queue_t) {
        self.pcb = pcb
        self.queue = queue

        // see comments in "lwip/src/core/ipv4/ip.c"
        sourcePort = pcb.memory.remote_port
        destinationPort = pcb.memory.local_port
        sourceAddress = in_addr(s_addr: pcb.memory.remote_ip.addr)
        destinationAddress = in_addr(s_addr: pcb.memory.local_ip.addr)

        identity = SocketIdentity(id: pcb.hashValue)
        SocketDict.socketDict[identity] = self

        withUnsafeMutablePointer(&identity) {
            tcp_arg(pcb, UnsafeMutablePointer<Void>($0))
        }
        tcp_recv(pcb, tcp_recv_func)
        tcp_sent(pcb, tcp_sent_func)
        tcp_err(pcb, tcp_err_func)
    }

    func errored(error: err_t) {
        release()
        switch Int32(error) {
        case ERR_RST:
            delegate?.socketDidReset(self)
        case ERR_ABRT:
            delegate?.socketDidAbort(self)
        default:
            break
        }
    }

    func sent(length: Int) {
        delegate?.didWriteData(length, from: self)
    }

    func recved(buf: UnsafeMutablePointer<pbuf>) {
        if buf == nil {
            delegate?.localDidClose(self)
        } else {
            let data = NSMutableData(length: Int(buf.memory.tot_len))!
            pbuf_copy_partial(buf, data.mutableBytes, buf.memory.tot_len, 0)
            delegate?.didReadData(data, from: self)
            tcp_recved(pcb, buf.memory.tot_len)
            pbuf_free(buf)
        }
    }

    public func writeData(data: NSData) -> Bool {
        // Note this is called synchronously since we need the result of `tcp_write()` and `tcp_write()` just puts the packets on the queue without sending them, so we can get the result immediately.
        var result = false
        dispatch_sync(queue) {
            if !self.invalid {
                result = false
                return
            }

            if tcp_write(self.pcb, data.bytes, UInt16(data.length), UInt8(TCP_WRITE_FLAG_COPY)) != err_t(ERR_OK) {
                result = false
            } else {
                result = true
            }

        }
        return result
    }

    public func close() {
        dispatch_async(queue) {
            guard !self.invalid else {
                return
            }

            tcp_close(self.pcb)
            self.release()
            // the lwip will handle the following things for us
            self.delegate?.socketDidClose(self)
        }
    }

    func release() {
        pcb = nil
    }

    deinit {
        SocketDict.socketDict.removeValueForKey(identity)
    }
}
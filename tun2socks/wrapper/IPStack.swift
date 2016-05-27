import Foundation
import lwip

public protocol IPStackDelegate: class {
    func didAcceptTCPSocket(sock: TSTCPSocket)
}

func tcpAcceptFn(arg: UnsafeMutablePointer<Void>, pcb: UnsafeMutablePointer<tcp_pcb>, error: err_t) -> err_t {
    return TUNIPStack.stack.didAcceptTCPSocket(pcb, error: error)
}

func outputPCB(interface: UnsafeMutablePointer<netif>, buf: UnsafeMutablePointer<pbuf>, ipaddr: UnsafeMutablePointer<ip_addr_t>) -> err_t {
    TUNIPStack.stack.writePBuf(buf)
    return err_t(ERR_OK)
}

public class TUNIPStack {
    public static var stack = TUNIPStack()

    // The whole stack is running in this dispatch queue.
    let processQueue = dispatch_queue_create("IPStackQueue", DISPATCH_QUEUE_SERIAL)!

    let timer: dispatch_source_t
    let listenPCB: UnsafeMutablePointer<tcp_pcb>

    /// This has to be set before calling `startProcessing()`
    public var tunInterface: TunInterfaceProtocol!

    public weak var delegate: IPStackDelegate?

    // Since all we need is a mock interface, we just use the loopback interface provided by lwip.
    // Do not need to add any interface.
    var interface: UnsafeMutablePointer<netif> {
        return netif_list
    }

    private init() {
        lwip_init()

        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, processQueue)

        // add a listening pcb
        var pcb = tcp_new()
        var addr = ip_addr_any
        tcp_bind(pcb, &addr, 0)
        pcb = tcp_listen_with_backlog(pcb, UInt8(TCP_DEFAULT_LISTEN_BACKLOG))
        listenPCB = pcb
        tcp_accept(pcb, tcpAcceptFn)

        interface.memory.output = outputPCB

        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 20, NSEC_PER_MSEC / 100)
        dispatch_source_set_event_handler(timer) {
            self.checkTimeout()
        }
    }

    /**
     The `tunInterface` and `delegate` should be set before calling this.
     */
    public func startProcessing() {
        dispatch_resume(timer)
        readPackets()
    }

    private func checkTimeout() {
        sys_check_timeouts()
    }

    func readPackets() {
        // Any error should already be handled by `tunInterface`.
        tunInterface.readPackets() { packets in
            self.dispatch_call {
                for packet in packets {
                    self.recievedPacket(packet)
                }
            }
            self.readPackets()
        }
    }

    func dispatch_call(block: () -> ()) {
        dispatch_async(processQueue, block)
    }

    func recievedPacket(data: NSData) {
        // Due to the limitation of swift, if we want a zero-copy implemention, we have to change the definition of `pbuf.payload` to `const`, which is not possible.
        // So we have to copy the data anyway.
        let buf = pbuf_alloc(PBUF_RAW, UInt16(data.length), PBUF_RAM)
        data.getBytes(buf.memory.payload, length: data.length)

        // The `netif->input()` should be ip_input(). According to the docs of lwip, we do not pass packets into the `ip_input()` function directly.
        netif_list.memory.input(buf, interface)
    }

    func writePBuf(buf: UnsafeMutablePointer<pbuf>) {
        let data = NSMutableData(length: Int(buf.memory.tot_len))!
        pbuf_copy_partial(buf, data.mutableBytes, buf.memory.tot_len, 0)
        // Only support IPv4 as of now.
        tunInterface.writePackets([data], versions: [Int(AF_INET)])
    }

    func didAcceptTCPSocket(pcb: UnsafeMutablePointer<tcp_pcb>, error: err_t) -> err_t {
        tcp_accepted_c(listenPCB)
        delegate?.didAcceptTCPSocket(TSTCPSocket(pcb: pcb, queue: processQueue))
        return err_t(ERR_OK)
    }
}
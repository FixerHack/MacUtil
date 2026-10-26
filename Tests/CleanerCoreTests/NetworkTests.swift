@testable import CleanerCore
import Foundation
import Testing

@Suite struct NetworkAdapterTests {
    /// Real `networksetup -listnetworkserviceorder` output, including a disabled service.
    private let serviceOrder = """
    An asterisk (*) denotes that a network service is disabled.
    (1) USB 10/100 LAN
    (Hardware Port: USB 10/100 LAN, Device: en7)

    (2) Thunderbolt Bridge
    (Hardware Port: Thunderbolt Bridge, Device: bridge0)

    (3) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)

    (*) Old Adapter
    (Hardware Port: Old Adapter, Device: en9)
    """

    @Test func readsTheOrderMacOSTriesServicesIn() {
        let services = NetworkAdapters.parseServiceOrder(serviceOrder)
        #expect(services["en7"]?.name == "USB 10/100 LAN")
        #expect(services["en7"]?.order == 1)
        #expect(services["en0"]?.name == "Wi-Fi")
        #expect(services["en0"]?.order == 3)
        #expect(services["bridge0"]?.order == 2)
    }

    @Test func aSwitchedOffServiceHasNoRank() {
        let services = NetworkAdapters.parseServiceOrder(serviceOrder)
        let disabled = try? #require(services["en9"])
        #expect(disabled?.name == "Old Adapter")
        // It is still a service, but macOS will not reach for it.
        #expect(disabled?.order == Int.max)
    }

    @Test func findsWhichInterfaceCarriesTheDefaultRoute() {
        let output = """
           route to: default
        destination: default
               mask: default
            gateway: 10.0.104.1
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC>
        """
        #expect(NetworkAdapters.parseDefaultRoute(output) == "en0")
        #expect(NetworkAdapters.parseDefaultRoute("route: writing to routing socket: not in table") == nil)
    }

    @Test func readsTheNameServersWithoutRepeatingThem() {
        let output = """
        DNS configuration

        resolver #1
          search domain[0] : lan
          nameserver[0] : 10.0.104.1
          nameserver[1] : 1.1.1.1
          flags    : Request A records

        resolver #2
          nameserver[0] : 10.0.104.1
        """
        #expect(NetworkAdapters.parseDNS(output) == ["10.0.104.1", "1.1.1.1"])
    }

    @Test func readsTheNegotiatedLinkSpeed() {
        let output = """
        lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
        \tinet 127.0.0.1 netmask 0xff000000
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tether aa:bb:cc:dd:ee:ff
        \tmedia: autoselect
        \tstatus: active
        en7: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tmedia: autoselect (100baseTX <full-duplex>)
        \tstatus: active
        en8: flags=8863<UP,BROADCAST> mtu 1500
        \tmedia: autoselect (1000baseT <full-duplex>)
        """
        let speeds = NetworkAdapters.parseLinkSpeeds(output)
        #expect(speeds["en7"] == 100)
        #expect(speeds["en8"] == 1000)
        // Wi-Fi reports no rate this way, and inventing one would be worse than none.
        #expect(speeds["en0"] == nil)
    }

    @Test func tellsTheKindsOfAdapterApart() {
        #expect(NetworkAdapters.kind(of: "lo0", service: nil) == .loopback)
        #expect(NetworkAdapters.kind(of: "en0", service: "Wi-Fi") == .wifi)
        #expect(NetworkAdapters.kind(of: "utun4", service: nil) == .vpn)
        #expect(NetworkAdapters.kind(of: "bridge0", service: "Thunderbolt Bridge") == .bridge)
        #expect(NetworkAdapters.kind(of: "en7", service: "USB 10/100 LAN") == .tether)
        #expect(NetworkAdapters.kind(of: "en5", service: "iPhone USB") == .tether)
        #expect(NetworkAdapters.kind(of: "en1", service: "Ethernet") == .ethernet)
    }

    @Test func readsTheInterfacesOfThisMac() {
        let interfaces = NetworkAdapters.readInterfaces()
        // Every Mac has a loopback, and it is always up.
        let loopback = try? #require(interfaces["lo0"])
        #expect(loopback?.isUp == true)
        #expect(loopback?.addresses.contains("127.0.0.1") == true)
    }

    @Test func describesThisMacsNetwork() async {
        let snapshot = await NetworkAdapters.load()
        #expect(!snapshot.adapters.isEmpty)
        // Nothing usable may be the loopback, whatever else is going on.
        #expect(!snapshot.usable.contains { $0.kind == .loopback })
        for adapter in snapshot.usable {
            #expect(!adapter.addresses.isEmpty)
            #expect(adapter.isRunning)
        }
    }
}

// pgc-tunnel: PG Connect's built-in WireGuard tunnel for Windows (DESIGN.md section 5, phase 2).
//
// The MSI installs this program as the "PGConnectTunnel" service (LocalSystem). PG Connect, running
// as the player, asks it over a named pipe to bring a Gamezone tunnel up or down, so players need
// neither WireGuard for Windows nor an admin prompt per session.
//
//	pgc-tunnel.exe /broker          run as the PGConnectTunnel service (the MSI sets this up)
//	pgc-tunnel.exe /tunnel <conf>   run one tunnel; started by the broker as "WireGuardTunnel$pgc"
//
// Safety rules (enforced here, not in the app, because the app runs as the player):
//   - split tunnel only: one peer, one /32 allowed IP, all addresses inside 10.77.0.0/16
//   - no DNS, no scripts, no routing-table changes; MTU forced to 1280 (see DESIGN.md)
//   - one tunnel at a time; it is removed when the app says "down" or its pipe connection closes
//   - the config (it holds a private key) is written only to a SYSTEM/Administrators-only folder
//     and deleted on teardown; keys are never logged
//
// Uses wireguard-windows (MIT) and the prebuilt wireguard.dll from wireguard-nt, which must sit
// next to this program.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
	"golang.zx2c4.com/wireguard/windows/conf"
	"golang.zx2c4.com/wireguard/windows/tunnel"
)

const (
	brokerServiceName = "PGConnectTunnel"
	tunnelName        = "pgc"
	pipePath          = `\\.\pipe\PGConnectTunnel`
	// SYSTEM and Administrators: full access. Interactive users (the player): read/write.
	pipeSDDL  = "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)"
	dirSDDL   = "O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
	tunnelMTU = 1280
	maxConfig = 8 << 10
)

var allowedNet = netip.MustParsePrefix("10.77.0.0/16")

func main() {
	if len(os.Args) >= 3 && strings.EqualFold(os.Args[1], "/tunnel") {
		if err := tunnel.Run(os.Args[2]); err != nil {
			os.Exit(1)
		}
		return
	}
	if len(os.Args) >= 2 && strings.EqualFold(os.Args[1], "/broker") {
		if err := svc.Run(brokerServiceName, &broker{}); err != nil {
			os.Exit(1)
		}
		return
	}
	fmt.Fprintln(os.Stderr, "pgc-tunnel is started by Windows as the PG Connect tunnel service.")
	os.Exit(2)
}

// ---- config validation ----

// validate parses a wg-quick config from the app and returns it only if it is a Productify split tunnel.
func validate(text string) (*conf.Config, error) {
	if len(text) > maxConfig {
		return nil, errors.New("config too large")
	}
	c, err := conf.FromWgQuick(text, tunnelName)
	if err != nil {
		return nil, errors.New("config could not be parsed")
	}
	i := &c.Interface
	if len(i.DNS) > 0 || len(i.DNSSearch) > 0 {
		return nil, errors.New("DNS is not allowed")
	}
	if i.PreUp != "" || i.PostUp != "" || i.PreDown != "" || i.PostDown != "" {
		return nil, errors.New("scripts are not allowed")
	}
	if i.TableOff {
		return nil, errors.New("Table = off is not allowed")
	}
	if len(i.Addresses) == 0 {
		return nil, errors.New("interface address missing")
	}
	for _, a := range i.Addresses {
		if !a.Addr().Is4() || !allowedNet.Contains(a.Addr()) || a.Bits() < allowedNet.Bits() {
			return nil, fmt.Errorf("interface address %s is outside %s", a, allowedNet)
		}
	}
	if len(c.Peers) != 1 {
		return nil, errors.New("exactly one peer is required")
	}
	p := &c.Peers[0]
	if len(p.AllowedIPs) != 1 {
		return nil, errors.New("exactly one allowed IP is required")
	}
	a := p.AllowedIPs[0]
	if !a.Addr().Is4() || a.Bits() != 32 || !allowedNet.Contains(a.Addr()) {
		return nil, fmt.Errorf("allowed IP must be one /32 inside %s", allowedNet)
	}
	if p.Endpoint.IsEmpty() {
		return nil, errors.New("peer endpoint missing")
	}
	i.MTU = tunnelMTU
	i.ListenPort = 0
	return c, nil
}

// ---- tunnel lifecycle (one at a time) ----

type tunnelManager struct {
	mu sync.Mutex
}

func tunnelDir() string {
	return filepath.Join(os.Getenv("ProgramData"), "PGConnect", "tunnels")
}

func confPath() string { return filepath.Join(tunnelDir(), tunnelName+".conf") }

func ensurePrivateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	sd, err := windows.SecurityDescriptorFromString(dirSDDL)
	if err != nil {
		return err
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	owner, _, _ := sd.Owner()
	return windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION|windows.OWNER_SECURITY_INFORMATION,
		owner, nil, dacl, nil)
}

func (t *tunnelManager) up(c *conf.Config) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.downLocked()
	if err := ensurePrivateDir(tunnelDir()); err != nil {
		return fmt.Errorf("could not prepare the tunnel folder: %w", err)
	}
	if err := os.WriteFile(confPath(), []byte(c.ToWgQuick()), 0o600); err != nil {
		return fmt.Errorf("could not write the tunnel config: %w", err)
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	serviceName, err := conf.ServiceNameOfTunnel(tunnelName)
	if err != nil {
		return err
	}
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()
	s, err := m.CreateService(serviceName, exe, mgr.Config{
		ServiceType:  windows.SERVICE_WIN32_OWN_PROCESS,
		StartType:    mgr.StartManual,
		ErrorControl: mgr.ErrorNormal,
		Dependencies: []string{"Nsi", "TcpIp"},
		DisplayName:  "PG Connect tunnel",
		SidType:      windows.SERVICE_SID_TYPE_UNRESTRICTED,
	}, "/tunnel", confPath())
	if err != nil {
		os.Remove(confPath())
		return fmt.Errorf("could not create the tunnel service: %w", err)
	}
	defer s.Close()
	if err := s.Start(); err != nil {
		t.downLocked()
		return fmt.Errorf("could not start the tunnel: %w", err)
	}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		st, err := s.Query()
		if err == nil && st.State == svc.Running {
			return nil
		}
		if err == nil && st.State == svc.Stopped {
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	t.downLocked()
	return errors.New("the tunnel did not start")
}

func (t *tunnelManager) down() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.downLocked()
}

func (t *tunnelManager) downLocked() {
	defer os.Remove(confPath())
	serviceName, err := conf.ServiceNameOfTunnel(tunnelName)
	if err != nil {
		return
	}
	m, err := mgr.Connect()
	if err != nil {
		return
	}
	defer m.Disconnect()
	s, err := m.OpenService(serviceName)
	if err != nil {
		return
	}
	defer s.Close()
	_, _ = s.Control(svc.Stop)
	for i := 0; i < 40; i++ {
		st, err := s.Query()
		if err != nil || st.State == svc.Stopped {
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	_ = s.Delete()
}

// ---- broker service and pipe protocol ----

type request struct {
	Op     string `json:"op"`               // "up", "down" or "ping"
	Config string `json:"config,omitempty"` // wg-quick text for "up"
}

type response struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

type broker struct {
	tunnels tunnelManager
}

func (b *broker) Execute(_ []string, r <-chan svc.ChangeRequest, s chan<- svc.Status) (bool, uint32) {
	s <- svc.Status{State: svc.StartPending}
	b.tunnels.down() // a tunnel left over from a crash or reboot is never kept
	l, err := winio.ListenPipe(pipePath, &winio.PipeConfig{SecurityDescriptor: pipeSDDL})
	if err != nil {
		log.Printf("pipe: %v", err)
		return false, 1
	}
	go b.serve(l)
	s <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for c := range r {
		switch c.Cmd {
		case svc.Interrogate:
			s <- c.CurrentStatus
		case svc.Stop, svc.Shutdown:
			s <- svc.Status{State: svc.StopPending}
			l.Close()
			b.tunnels.down()
			return false, 0
		}
	}
	return false, 0
}

func (b *broker) serve(l net.Listener) {
	for {
		conn, err := l.Accept()
		if err != nil {
			return
		}
		go b.handle(conn)
	}
}

// handle serves one app connection. A tunnel brought up on this connection is torn down when
// the connection ends, so a crashed or killed app never leaves a tunnel behind.
func (b *broker) handle(conn net.Conn) {
	defer conn.Close()
	owns := false
	defer func() {
		if owns {
			b.tunnels.down()
		}
	}()
	in := bufio.NewScanner(conn)
	in.Buffer(make([]byte, 0, 4096), maxConfig+1024)
	out := json.NewEncoder(conn)
	for in.Scan() {
		var req request
		if err := json.Unmarshal(in.Bytes(), &req); err != nil {
			_ = out.Encode(response{Error: "bad request"})
			continue
		}
		switch req.Op {
		case "ping":
			_ = out.Encode(response{OK: true})
		case "up":
			c, err := validate(req.Config)
			if err == nil {
				err = b.tunnels.up(c)
			}
			if err != nil {
				_ = out.Encode(response{Error: err.Error()})
				continue
			}
			owns = true
			_ = out.Encode(response{OK: true})
		case "down":
			if owns {
				b.tunnels.down()
				owns = false
			}
			_ = out.Encode(response{OK: true})
		default:
			_ = out.Encode(response{Error: "unknown op"})
		}
	}
}

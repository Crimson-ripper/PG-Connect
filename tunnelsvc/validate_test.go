package main

import (
	"strings"
	"testing"
)

const goodConfig = `[Interface]
PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 10.77.0.2/32

[Peer]
PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=
AllowedIPs = 10.77.0.1/32
Endpoint = 203.0.113.7:51820
PersistentKeepalive = 25
`

func TestValidateAcceptsSplitTunnelAndForcesMTU(t *testing.T) {
	c, err := validate(goodConfig + "\n")
	if err != nil {
		t.Fatalf("good config refused: %v", err)
	}
	if c.Interface.MTU != 1280 {
		t.Fatalf("MTU = %d, want 1280", c.Interface.MTU)
	}
}

func TestValidateRefusesUnsafeConfigs(t *testing.T) {
	cases := map[string]string{
		"default route":   strings.Replace(goodConfig, "10.77.0.1/32", "0.0.0.0/0", 1),
		"wider range":     strings.Replace(goodConfig, "10.77.0.1/32", "10.77.0.0/16", 1),
		"other network":   strings.Replace(goodConfig, "10.77.0.1/32", "192.168.1.1/32", 1),
		"two allowed IPs": strings.Replace(goodConfig, "10.77.0.1/32", "10.77.0.1/32, 10.77.0.3/32", 1),
		"address outside": strings.Replace(goodConfig, "Address = 10.77.0.2/32", "Address = 192.168.5.2/32", 1),
		"DNS":             strings.Replace(goodConfig, "Address = 10.77.0.2/32", "Address = 10.77.0.2/32\nDNS = 1.1.1.1", 1),
		"script":          strings.Replace(goodConfig, "Address = 10.77.0.2/32", "Address = 10.77.0.2/32\nPostUp = calc.exe", 1),
		"table off":       strings.Replace(goodConfig, "Address = 10.77.0.2/32", "Address = 10.77.0.2/32\nTable = off", 1),
		"no endpoint":     strings.Replace(goodConfig, "Endpoint = 203.0.113.7:51820\n", "", 1),
		"two peers":       goodConfig + "\n[Peer]\nPublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=\nAllowedIPs = 10.77.0.9/32\nEndpoint = 203.0.113.8:51820\n",
		"garbage":         "not a config",
		"too large":       goodConfig + strings.Repeat("#", 9000),
	}
	for name, cfg := range cases {
		if _, err := validate(cfg); err == nil {
			t.Errorf("%s: accepted, want refused", name)
		}
	}
}

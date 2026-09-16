// Command scan starts a 10 second BLE scan using the corebluetoothd helper
// and prints every peripheral it discovers. Build and run on macOS only:
//
//	make example   # from the repo root: builds the helper + this binary
//	./bin/scan
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/gomi-source/corebluetooth-go/ble"
)

func main() {
	ctx := context.Background()

	client, err := ble.Start(ctx, ble.Options{Stderr: os.Stderr})
	if err != nil {
		log.Fatalf("start: %v", err)
	}
	defer client.Close()

	state, err := client.State(ctx)
	if err != nil {
		log.Fatalf("state: %v", err)
	}
	fmt.Println("bluetooth state:", state)
	if state != ble.StatePoweredOn {
		log.Fatalf("bluetooth is not powered on (state=%s); enable Bluetooth and re-run", state)
	}

	if err := client.StartScan(ctx, ble.ScanOptions{AllowDuplicates: false}); err != nil {
		log.Fatalf("start scan: %v", err)
	}
	fmt.Println("scanning for 10 seconds...")

	seen := map[string]bool{}
	deadline := time.After(10 * time.Second)

loop:
	for {
		select {
		case p := <-client.Discoveries():
			if seen[p.PeripheralID] {
				continue
			}
			seen[p.PeripheralID] = true
			name := "(unnamed)"
			if p.Name != nil {
				name = *p.Name
			}
			fmt.Printf("%s  rssi=%-4d  %s\n", p.PeripheralID, p.RSSI, name)
		case err := <-client.Errors():
			log.Println("error:", err)
		case <-deadline:
			break loop
		}
	}

	if err := client.StopScan(ctx); err != nil {
		log.Printf("stop scan: %v", err)
	}
	fmt.Printf("done, saw %d peripheral(s)\n", len(seen))
}

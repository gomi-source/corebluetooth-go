package ble

import (
	"context"
	"encoding/base64"
	"time"
)

// State returns the adapter's current CBManagerState.
func (c *Client) State(ctx context.Context) (State, error) {
	var res struct {
		State State `json:"state"`
	}
	if err := c.conn.call(ctx, "state.get", nil, &res); err != nil {
		return "", err
	}
	return res.State, nil
}

// ScanOptions configures StartScan.
type ScanOptions struct {
	// ServiceUUIDs restricts the scan to peripherals advertising at least
	// one of these service UUIDs. Leave empty to discover everything
	// (noisy, but sometimes necessary during development).
	ServiceUUIDs []string
	// AllowDuplicates asks CoreBluetooth to report every advertisement
	// instead of coalescing repeats per peripheral. Off by default, which
	// is friendlier to battery/CPU and matches typical use.
	AllowDuplicates bool
}

// StartScan begins scanning for peripherals. Results are delivered on
// Discoveries() until StopScan is called.
func (c *Client) StartScan(ctx context.Context, opts ScanOptions) error {
	params := map[string]interface{}{
		"allowDuplicates": opts.AllowDuplicates,
	}
	if len(opts.ServiceUUIDs) > 0 {
		params["serviceUUIDs"] = opts.ServiceUUIDs
	}
	return c.conn.call(ctx, "scan.start", params, nil)
}

// StopScan stops an in-progress scan.
func (c *Client) StopScan(ctx context.Context) error {
	return c.conn.call(ctx, "scan.stop", nil, nil)
}

// Connect connects to a peripheral previously seen via Discoveries(). It
// blocks until CoreBluetooth reports the connection succeeded or failed
// (or timeout elapses, if > 0).
func (c *Client) Connect(ctx context.Context, peripheralID string, timeout time.Duration) error {
	params := map[string]interface{}{"peripheralId": peripheralID}
	if timeout > 0 {
		params["timeoutMs"] = timeout.Milliseconds()
	}
	return c.conn.call(ctx, "peripheral.connect", params, nil)
}

// Disconnect disconnects a connected peripheral.
func (c *Client) Disconnect(ctx context.Context, peripheralID string) error {
	return c.conn.call(ctx, "peripheral.disconnect", map[string]interface{}{
		"peripheralId": peripheralID,
	}, nil)
}

// DiscoverServices discovers services on a connected peripheral. Pass a
// nil/empty serviceUUIDs to discover all services. Must be called (and
// its result awaited) before DiscoverCharacteristics for the same
// peripheral.
func (c *Client) DiscoverServices(ctx context.Context, peripheralID string, serviceUUIDs []string) ([]Service, error) {
	params := map[string]interface{}{"peripheralId": peripheralID}
	if len(serviceUUIDs) > 0 {
		params["serviceUUIDs"] = serviceUUIDs
	}
	var res struct {
		Services []Service `json:"services"`
	}
	if err := c.conn.call(ctx, "peripheral.discoverServices", params, &res); err != nil {
		return nil, err
	}
	return res.Services, nil
}

// DiscoverCharacteristics discovers characteristics of a previously
// discovered service. Pass nil/empty characteristicUUIDs to discover all
// characteristics.
func (c *Client) DiscoverCharacteristics(ctx context.Context, peripheralID, serviceUUID string, characteristicUUIDs []string) ([]Characteristic, error) {
	params := map[string]interface{}{
		"peripheralId": peripheralID,
		"serviceUUID":  serviceUUID,
	}
	if len(characteristicUUIDs) > 0 {
		params["characteristicUUIDs"] = characteristicUUIDs
	}
	var res struct {
		Characteristics []Characteristic `json:"characteristics"`
	}
	if err := c.conn.call(ctx, "peripheral.discoverCharacteristics", params, &res); err != nil {
		return nil, err
	}
	return res.Characteristics, nil
}

// ReadCharacteristic reads a characteristic's current value.
func (c *Client) ReadCharacteristic(ctx context.Context, peripheralID, serviceUUID, characteristicUUID string) ([]byte, error) {
	var res struct {
		ValueBase64 string `json:"valueBase64"`
	}
	if err := c.conn.call(ctx, "peripheral.readValue", charRefParams(peripheralID, serviceUUID, characteristicUUID), &res); err != nil {
		return nil, err
	}
	return base64.StdEncoding.DecodeString(res.ValueBase64)
}

// WriteCharacteristic writes a value to a characteristic. When
// withResponse is true, this blocks until the peripheral acknowledges the
// write; when false, it returns as soon as the write is queued (matching
// CBCharacteristicWriteType.withoutResponse, which never notifies the
// delegate).
func (c *Client) WriteCharacteristic(ctx context.Context, peripheralID, serviceUUID, characteristicUUID string, value []byte, withResponse bool) error {
	params := charRefParams(peripheralID, serviceUUID, characteristicUUID)
	params["valueBase64"] = base64.StdEncoding.EncodeToString(value)
	params["withResponse"] = withResponse
	return c.conn.call(ctx, "peripheral.writeValue", params, nil)
}

// SetNotify enables or disables notify/indicate delivery for a
// characteristic. Once enabled, updates arrive on Notifications().
func (c *Client) SetNotify(ctx context.Context, peripheralID, serviceUUID, characteristicUUID string, enabled bool) error {
	params := charRefParams(peripheralID, serviceUUID, characteristicUUID)
	params["enabled"] = enabled
	return c.conn.call(ctx, "peripheral.setNotifyValue", params, nil)
}

// ReadRSSI reads the current RSSI for a connected peripheral.
func (c *Client) ReadRSSI(ctx context.Context, peripheralID string) (int, error) {
	var res struct {
		RSSI int `json:"rssi"`
	}
	if err := c.conn.call(ctx, "peripheral.readRSSI", map[string]interface{}{
		"peripheralId": peripheralID,
	}, &res); err != nil {
		return 0, err
	}
	return res.RSSI, nil
}

func charRefParams(peripheralID, serviceUUID, characteristicUUID string) map[string]interface{} {
	return map[string]interface{}{
		"peripheralId":       peripheralID,
		"serviceUUID":        serviceUUID,
		"characteristicUUID": characteristicUUID,
	}
}

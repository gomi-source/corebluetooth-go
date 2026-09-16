package ble

// State mirrors CBManagerState.
type State string

const (
	StatePoweredOn    State = "poweredOn"
	StatePoweredOff   State = "poweredOff"
	StateUnauthorized State = "unauthorized"
	StateUnsupported  State = "unsupported"
	StateResetting    State = "resetting"
	StateUnknown      State = "unknown"
)

// AdvertisementData mirrors the fields CoreBluetooth exposes in a
// peripheral's advertisement dictionary. Binary fields (manufacturer data,
// service data) are base64-encoded on the wire; decode with encoding/base64.
type AdvertisementData struct {
	LocalName              *string           `json:"localName,omitempty"`
	ManufacturerDataBase64 *string           `json:"manufacturerDataBase64,omitempty"`
	ServiceUUIDs           []string          `json:"serviceUUIDs,omitempty"`
	ServiceData            map[string]string `json:"serviceData,omitempty"`
	TxPowerLevel           *int              `json:"txPowerLevel,omitempty"`
	IsConnectable          *bool             `json:"isConnectable,omitempty"`
	OverflowServiceUUIDs   []string          `json:"overflowServiceUUIDs,omitempty"`
	SolicitedServiceUUIDs  []string          `json:"solicitedServiceUUIDs,omitempty"`
}

// DiscoveredPeripheral is delivered on Client.Discoveries() for every
// advertisement CoreBluetooth reports while a scan is active.
type DiscoveredPeripheral struct {
	PeripheralID      string            `json:"peripheralId"`
	Name              *string           `json:"name,omitempty"`
	RSSI              int               `json:"rssi"`
	AdvertisementData AdvertisementData `json:"advertisementData"`
	IsConnectable     *bool             `json:"isConnectable,omitempty"`
}

// CharacteristicProperties mirrors CBCharacteristicProperties.
type CharacteristicProperties struct {
	Broadcast                  bool `json:"broadcast"`
	Read                       bool `json:"read"`
	WriteWithoutResponse       bool `json:"writeWithoutResponse"`
	Write                      bool `json:"write"`
	Notify                     bool `json:"notify"`
	Indicate                   bool `json:"indicate"`
	AuthenticatedSignedWrites  bool `json:"authenticatedSignedWrites"`
	ExtendedProperties         bool `json:"extendedProperties"`
	NotifyEncryptionRequired   bool `json:"notifyEncryptionRequired"`
	IndicateEncryptionRequired bool `json:"indicateEncryptionRequired"`
}

// Service mirrors CBService.
type Service struct {
	UUID      string `json:"uuid"`
	IsPrimary bool   `json:"isPrimary"`
}

// Characteristic mirrors CBCharacteristic.
type Characteristic struct {
	UUID        string                   `json:"uuid"`
	ServiceUUID string                   `json:"serviceUUID"`
	Properties  CharacteristicProperties `json:"properties"`
}

// CharacteristicUpdate is delivered on Client.Notifications() whenever a
// subscribed (notify/indicate) characteristic pushes a new value.
type CharacteristicUpdate struct {
	PeripheralID       string `json:"peripheralId"`
	ServiceUUID        string `json:"serviceUUID"`
	CharacteristicUUID string `json:"characteristicUUID"`
	ValueBase64        string `json:"valueBase64"`
	IsNotification     bool   `json:"isNotification"`
}

// Disconnection is delivered on Client.Disconnections() whenever a
// peripheral disconnects, whether requested (Disconnect) or not.
type Disconnection struct {
	PeripheralID string
	Err          error
}

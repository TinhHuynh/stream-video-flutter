package video_coordinator_rpc

import "github.com/GetStream/video/internal/validator"

func init() {
	validator.Register[CreateCallRequest](map[string]string{
		"Type":           "required,max=255",
		"Id":             "required,max=255",
		"ParticipantIds": "max=100",
	})

	validator.Register[UpdateCallRequest](map[string]string{
		"Type": "required,max=255",
		"Id":   "required,max=255",
	})

	validator.Register[AddDeviceRequest](map[string]string{
		"UserId":           "required,max=255",
		"Id":               "required,max=255",
		"PushProviderName": "required,oneof=firebase,huawei,apn,xiaomi",
	})
}
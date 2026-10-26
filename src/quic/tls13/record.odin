package tls13

ALERT_UNEXPECTED_MESSAGE :: 10
ALERT_BAD_RECORD_MAC :: 20
ALERT_RECORD_OVERFLOW :: 22
ALERT_HANDSHAKE_FAILURE :: 40
ALERT_BAD_CERTIFICATE :: 42
ALERT_CERTIFICATE_UNKNOWN :: 46
ALERT_ILLEGAL_PARAMETER :: 47
ALERT_DECODE_ERROR :: 50
ALERT_DECRYPT_ERROR :: 51
ALERT_PROTOCOL_VERSION :: 70
ALERT_INTERNAL_ERROR :: 80
ALERT_MISSING_EXTENSION :: 109
ALERT_UNSUPPORTED_EXTENSION :: 110
ALERT_NO_APPLICATION_PROTOCOL :: 120

// Upper bound on a single reassembled handshake message (certificate chains are ~5-10 KiB).
MAX_HANDSHAKE_MESSAGE :: 1 << 18

@(private)
alert_for :: proc(e: Error) -> u8 {
	#partial switch e {
	case .Decode:
		return ALERT_DECODE_ERROR
	case .Unexpected_Message:
		return ALERT_UNEXPECTED_MESSAGE
	case .Bad_Record_Mac:
		return ALERT_BAD_RECORD_MAC
	case .Record_Overflow, .Too_Large:
		return ALERT_RECORD_OVERFLOW
	case .Handshake_Failure:
		return ALERT_HANDSHAKE_FAILURE
	case .Protocol_Version:
		return ALERT_PROTOCOL_VERSION
	case .Illegal_Parameter:
		return ALERT_ILLEGAL_PARAMETER
	case .Unsupported_Extension:
		return ALERT_UNSUPPORTED_EXTENSION
	case .Missing_Extension:
		return ALERT_MISSING_EXTENSION
	case .Bad_Certificate, .Unsupported_Compression:
		return ALERT_BAD_CERTIFICATE
	case .Untrusted_Certificate:
		return ALERT_CERTIFICATE_UNKNOWN
	case .Bad_Signature, .Bad_Finished:
		return ALERT_DECRYPT_ERROR
	case .No_Application_Protocol:
		return ALERT_NO_APPLICATION_PROTOCOL
	}
	return ALERT_INTERNAL_ERROR
}

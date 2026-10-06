// Stub of google.golang.org/grpc/codes: enough surface for the fixture to type-check.
package codes

type Code uint32

const (
	InvalidArgument  Code = 3
	NotFound         Code = 5
	PermissionDenied Code = 7
	Unimplemented    Code = 12
	Internal         Code = 13
	Unavailable      Code = 14
)

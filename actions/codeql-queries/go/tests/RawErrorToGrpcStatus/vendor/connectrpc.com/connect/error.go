// Stub of connectrpc.com/connect: enough surface for the fixture to type-check.
package connect

type Code int

const CodeInternal Code = 13

type Error struct{}

func (e *Error) Error() string { return "" }

func NewError(c Code, underlying error) *Error { return &Error{} }

// Stub of google.golang.org/grpc/status: enough surface for the fixture to type-check.
package status

import "google.golang.org/grpc/codes"

type Status struct{}

func (s *Status) Err() error { return nil }

func New(c codes.Code, msg string) *Status { return &Status{} }

func Error(c codes.Code, msg string) error { return nil }

func Errorf(c codes.Code, format string, a ...interface{}) error { return nil }

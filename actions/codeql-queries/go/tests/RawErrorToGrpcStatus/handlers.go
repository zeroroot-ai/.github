package handlers

import (
	"context"
	"errors"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type Request struct{}

type Response struct{}

func lookup() error { return errors.New("db: no rows") }

// ErrUnavailable is a package-level error that carries a gRPC code.
var ErrUnavailable = status.Error(codes.Unavailable, "try again later")

// thingServer implements ThingServiceServer, so its RPC methods are handlers.
type thingServer struct {
	UnimplementedThingServiceServer
}

// Positive: the database error returns to the caller unwrapped.
func (s *thingServer) GetThing(ctx context.Context, req *Request) (*Response, error) {
	if err := lookup(); err != nil {
		return nil, err
	}
	return &Response{}, nil
}

// load is a helper that returns a raw error.
func load() (*Response, error) {
	if err := lookup(); err != nil {
		return nil, err
	}
	return &Response{}, nil
}

// Positive: the raw error of a helper returns to the caller unwrapped.
func (s *thingServer) GetDeep(ctx context.Context, req *Request) (*Response, error) {
	resp, err := load()
	if err != nil {
		return nil, err
	}
	return resp, nil
}

// Negative: the returned variable was produced by status.Errorf.
func (s *thingServer) GetCoded(ctx context.Context, req *Request) (*Response, error) {
	if err := lookup(); err != nil {
		cerr := status.Errorf(codes.NotFound, "thing: %v", err)
		return nil, cerr
	}
	return &Response{}, nil
}

// Negative: the returned variable was produced by connect.NewError.
func (s *thingServer) GetConnect(ctx context.Context, req *Request) (*Response, error) {
	if err := lookup(); err != nil {
		cerr := connect.NewError(connect.CodeInternal, err)
		return nil, cerr
	}
	return &Response{}, nil
}

// Negative: the returned variable came from a Status value's Err().
func (s *thingServer) GetStatusErr(ctx context.Context, req *Request) (*Response, error) {
	if err := lookup(); err != nil {
		st := status.New(codes.Internal, "thing")
		e := st.Err()
		return nil, e
	}
	return &Response{}, nil
}

// tenant is a helper that sets the gRPC code itself.
func tenant(ctx context.Context) (string, error) {
	if ctx == nil {
		return "", status.Error(codes.PermissionDenied, "no tenant")
	}
	return "t-1", nil
}

// Negative: the helper already set the gRPC code.
func (s *thingServer) GetHelperCoded(ctx context.Context, req *Request) (*Response, error) {
	_, err := tenant(ctx)
	if err != nil {
		return nil, err
	}
	return &Response{}, nil
}

// engine is a helper that returns a package-level coded error.
func engine(ok bool) (*Response, error) {
	if !ok {
		return nil, ErrUnavailable
	}
	return &Response{}, nil
}

// Negative: the helper returned a package-level error with a gRPC code.
func (s *thingServer) GetSentinel(ctx context.Context, req *Request) (*Response, error) {
	resp, err := engine(req != nil)
	if err != nil {
		return nil, err
	}
	return resp, nil
}

// scope holds a function value. The query cannot see which function a
// value names.
type scope struct {
	ref func(id string) (string, error)
}

var scopes = map[string]scope{
	"team": {ref: func(id string) (string, error) {
		return "", status.Error(codes.InvalidArgument, "bad team id")
	}},
}

// Negative: the error comes from a call through a function value.
func (s *thingServer) GetByScope(ctx context.Context, req *Request) (*Response, error) {
	_, err := scopes["team"].ref("t-1")
	if err != nil {
		return nil, err
	}
	return &Response{}, nil
}

// Negative: an exported function with the handler shape that is not a
// method of a gRPC server. A library returns its own errors.
func Load(ctx context.Context, req *Request) (*Response, error) {
	if err := lookup(); err != nil {
		return nil, err
	}
	return &Response{}, nil
}

// Negative: a method with an RPC name on a type that is no gRPC server.
type cache struct{}

func (c *cache) GetThing(ctx context.Context, req *Request) (*Response, error) {
	if err := lookup(); err != nil {
		return nil, err
	}
	return &Response{}, nil
}

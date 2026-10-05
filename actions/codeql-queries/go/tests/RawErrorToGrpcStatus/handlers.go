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

// Positive: the database error returns to the caller unwrapped.
func GetThing(ctx context.Context, req *Request) (*Response, error) {
	if err := lookup(); err != nil {
		return nil, err
	}
	return &Response{}, nil
}

// Negative: the returned variable was produced by status.Errorf.
func GetCoded(ctx context.Context, req *Request) (*Response, error) {
	if err := lookup(); err != nil {
		cerr := status.Errorf(codes.NotFound, "thing: %v", err)
		return nil, cerr
	}
	return &Response{}, nil
}

// Negative: the returned variable was produced by connect.NewError.
func GetConnect(ctx context.Context, req *Request) (*Response, error) {
	if err := lookup(); err != nil {
		cerr := connect.NewError(connect.CodeInternal, err)
		return nil, cerr
	}
	return &Response{}, nil
}

// Negative: the returned variable came from a Status value's Err().
func GetStatusErr(ctx context.Context, req *Request) (*Response, error) {
	if err := lookup(); err != nil {
		st := status.New(codes.Internal, "thing")
		e := st.Err()
		return nil, e
	}
	return &Response{}, nil
}

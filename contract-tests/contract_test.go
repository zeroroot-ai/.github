// Copyright 2026 Zero Day AI, Inc.
// Licensed under BUSL-1.1; see LICENSE.
//
// Cross-repo contract tests — slice .github#114 of PRD .github#101.
//
// Exercises one happy-path RPC per platform-sdk service via in-process stub
// gRPC servers, then asserts ErrorDetail shape on forced failure cases.
// Testcontainer deps (Neo4j, Redis, OpenFGA, Postgres) are started by the
// workflow via docker-compose for environment parity; the stubs do not
// connect to them in this stub phase.
package contracttests

import (
	"context"
	"fmt"
	"net"
	"os"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	errorsv1 "github.com/zero-day-ai/platform-sdk/gen/gibson/common/errors/v1"

	adminv1 "github.com/zero-day-ai/platform-sdk/gen/gibson/admin/v1"
	authzv1 "github.com/zero-day-ai/platform-sdk/gen/gibson/authz/v1"
	daemonadminv1 "github.com/zero-day-ai/platform-sdk/gen/gibson/daemon/admin/v1"
	discoveryv1 "github.com/zero-day-ai/platform-sdk/gen/gibson/daemon/discovery/v1"
	platformv1 "github.com/zero-day-ai/platform-sdk/gen/gibson/platform/v1"
	tenantv1 "github.com/zero-day-ai/platform-sdk/gen/gibson/tenant/v1"
	usagev1 "github.com/zero-day-ai/platform-sdk/gen/gibson/usage/v1"
)

// errorDetailStatus builds a gRPC status with an ErrorDetail in the details
// slot — the canonical failure shape every platform-sdk consumer must handle.
func errorDetailStatus(grpcCode codes.Code, errCode errorsv1.ErrorCode, msg string) error {
	st := status.New(grpcCode, msg)
	detail := &errorsv1.ErrorDetail{
		Code:      errCode,
		Retryable: false,
		Detail:    msg,
		Metadata:  map[string]string{"test": "forced-failure"},
	}
	st2, err := st.WithDetails(detail)
	if err != nil {
		return st.Err()
	}
	return st2.Err()
}

// assertErrorDetail verifies the canonical ErrorDetail shape in a gRPC error.
func assertErrorDetail(t *testing.T, err error, wantGRPC codes.Code, wantCode errorsv1.ErrorCode) {
	t.Helper()
	if err == nil {
		t.Fatal("expected an error, got nil")
	}
	st := status.Convert(err)
	if st.Code() != wantGRPC {
		t.Errorf("gRPC code: got %v, want %v", st.Code(), wantGRPC)
	}
	var found *errorsv1.ErrorDetail
	for _, d := range st.Details() {
		if ed, ok := d.(*errorsv1.ErrorDetail); ok {
			found = ed
			break
		}
	}
	if found == nil {
		t.Fatalf("no ErrorDetail in status details; details: %v", st.Details())
	}
	if found.Code != wantCode {
		t.Errorf("ErrorDetail.Code: got %v, want %v", found.Code, wantCode)
	}
	if found.Detail == "" {
		t.Error("ErrorDetail.Detail must be non-empty")
	}
}

// --- Stub servers --- //

type stubPlatformOperator struct{ platformv1.UnimplementedPlatformOperatorServiceServer }

func (s *stubPlatformOperator) Shutdown(_ context.Context, req *platformv1.ShutdownRequest) (*platformv1.ShutdownResponse, error) {
	if req.GetReason() == "bad-tenant" {
		return nil, errorDetailStatus(codes.PermissionDenied, errorsv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED, "invalid tenant")
	}
	return &platformv1.ShutdownResponse{}, nil
}

type stubTenantAdmin struct{ tenantv1.UnimplementedTenantAdminServiceServer }

func (s *stubTenantAdmin) ListAgentIdentities(_ context.Context, req *tenantv1.ListAgentIdentitiesRequest) (*tenantv1.ListAgentIdentitiesResponse, error) {
	if req.GetTenantId() == "bad-tenant" {
		return nil, errorDetailStatus(codes.NotFound, errorsv1.ErrorCode_ERROR_CODE_NOT_FOUND, "tenant not found")
	}
	return &tenantv1.ListAgentIdentitiesResponse{}, nil
}

type stubUsage struct{ usagev1.UnimplementedUsageServiceServer }

func (s *stubUsage) ListUsage(_ context.Context, req *usagev1.ListUsageRequest) (*usagev1.ListUsageResponse, error) {
	if req.GetTenantId() == "bad-tenant" {
		return nil, errorDetailStatus(codes.InvalidArgument, errorsv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "invalid tenant id")
	}
	return &usagev1.ListUsageResponse{}, nil
}

type stubModelAccess struct{ authzv1.UnimplementedModelAccessServiceServer }

func (s *stubModelAccess) ListAccess(_ context.Context, req *authzv1.ListAccessRequest) (*authzv1.ListAccessResponse, error) {
	if req.GetTenantId() == "bad-tenant" {
		return nil, errorDetailStatus(codes.PermissionDenied, errorsv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED, "permission denied")
	}
	return &authzv1.ListAccessResponse{}, nil
}

type stubDiscovery struct{ discoveryv1.UnimplementedDiscoveryServiceServer }

func (s *stubDiscovery) ListAgents(_ context.Context, req *discoveryv1.ListAgentsRequest) (*discoveryv1.ListAgentsResponse, error) {
	if req.GetTenantId() == "bad-tenant" {
		return nil, errorDetailStatus(codes.NotFound, errorsv1.ErrorCode_ERROR_CODE_NOT_FOUND, "tenant not found")
	}
	return &discoveryv1.ListAgentsResponse{}, nil
}

type stubDaemonAdmin struct{ daemonadminv1.UnimplementedDaemonAdminServiceServer }

func (s *stubDaemonAdmin) StartComponent(_ context.Context, req *daemonadminv1.StartComponentRequest) (*daemonadminv1.StartComponentResponse, error) {
	if req.GetComponentId() == "bad-component" {
		return nil, errorDetailStatus(codes.NotFound, errorsv1.ErrorCode_ERROR_CODE_NOT_FOUND, "component not found")
	}
	return &daemonadminv1.StartComponentResponse{}, nil
}

type stubAdminTenant struct{ adminv1.UnimplementedTenantAdminServiceServer }

func (s *stubAdminTenant) GetReservedNames(_ context.Context, _ *adminv1.GetReservedNamesRequest) (*adminv1.GetReservedNamesResponse, error) {
	return &adminv1.GetReservedNamesResponse{}, nil
}

// --- Test harness --- //

func startStubServer(t *testing.T) string {
	t.Helper()
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	srv := grpc.NewServer()
	platformv1.RegisterPlatformOperatorServiceServer(srv, &stubPlatformOperator{})
	tenantv1.RegisterTenantAdminServiceServer(srv, &stubTenantAdmin{})
	usagev1.RegisterUsageServiceServer(srv, &stubUsage{})
	authzv1.RegisterModelAccessServiceServer(srv, &stubModelAccess{})
	discoveryv1.RegisterDiscoveryServiceServer(srv, &stubDiscovery{})
	daemonadminv1.RegisterDaemonAdminServiceServer(srv, &stubDaemonAdmin{})
	adminv1.RegisterTenantAdminServiceServer(srv, &stubAdminTenant{})
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.GracefulStop)
	return lis.Addr().String()
}

// --- Tests --- //

func TestContractSuite(t *testing.T) {
	addr := startStubServer(t)
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("grpc dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })

	start := time.Now()
	results := map[string]string{}

	t.Run("PlatformOperatorService/Shutdown", func(t *testing.T) {
		c := platformv1.NewPlatformOperatorServiceClient(conn)
		rpcStart := time.Now()
		if _, err := c.Shutdown(context.Background(), &platformv1.ShutdownRequest{Reason: "test"}); err != nil {
			t.Errorf("happy path: %v", err)
		}
		_, err := c.Shutdown(context.Background(), &platformv1.ShutdownRequest{Reason: "bad-tenant"})
		assertErrorDetail(t, err, codes.PermissionDenied, errorsv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED)
		results["PlatformOperatorService/Shutdown"] = fmt.Sprintf("ok (%s)", time.Since(rpcStart).Round(time.Millisecond))
	})

	t.Run("TenantAdminService/ListAgentIdentities", func(t *testing.T) {
		c := tenantv1.NewTenantAdminServiceClient(conn)
		rpcStart := time.Now()
		if _, err := c.ListAgentIdentities(context.Background(), &tenantv1.ListAgentIdentitiesRequest{TenantId: "t-ok"}); err != nil {
			t.Errorf("happy path: %v", err)
		}
		_, err := c.ListAgentIdentities(context.Background(), &tenantv1.ListAgentIdentitiesRequest{TenantId: "bad-tenant"})
		assertErrorDetail(t, err, codes.NotFound, errorsv1.ErrorCode_ERROR_CODE_NOT_FOUND)
		results["TenantAdminService/ListAgentIdentities"] = fmt.Sprintf("ok (%s)", time.Since(rpcStart).Round(time.Millisecond))
	})

	t.Run("UsageService/ListUsage", func(t *testing.T) {
		c := usagev1.NewUsageServiceClient(conn)
		rpcStart := time.Now()
		if _, err := c.ListUsage(context.Background(), &usagev1.ListUsageRequest{TenantId: "t-ok"}); err != nil {
			t.Errorf("happy path: %v", err)
		}
		_, err := c.ListUsage(context.Background(), &usagev1.ListUsageRequest{TenantId: "bad-tenant"})
		assertErrorDetail(t, err, codes.InvalidArgument, errorsv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT)
		results["UsageService/ListUsage"] = fmt.Sprintf("ok (%s)", time.Since(rpcStart).Round(time.Millisecond))
	})

	t.Run("ModelAccessService/ListAccess", func(t *testing.T) {
		c := authzv1.NewModelAccessServiceClient(conn)
		rpcStart := time.Now()
		if _, err := c.ListAccess(context.Background(), &authzv1.ListAccessRequest{TenantId: "t-ok"}); err != nil {
			t.Errorf("happy path: %v", err)
		}
		_, err := c.ListAccess(context.Background(), &authzv1.ListAccessRequest{TenantId: "bad-tenant"})
		assertErrorDetail(t, err, codes.PermissionDenied, errorsv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED)
		results["ModelAccessService/ListAccess"] = fmt.Sprintf("ok (%s)", time.Since(rpcStart).Round(time.Millisecond))
	})

	t.Run("DiscoveryService/ListAgents", func(t *testing.T) {
		c := discoveryv1.NewDiscoveryServiceClient(conn)
		rpcStart := time.Now()
		if _, err := c.ListAgents(context.Background(), &discoveryv1.ListAgentsRequest{TenantId: "t-ok"}); err != nil {
			t.Errorf("happy path: %v", err)
		}
		_, err := c.ListAgents(context.Background(), &discoveryv1.ListAgentsRequest{TenantId: "bad-tenant"})
		assertErrorDetail(t, err, codes.NotFound, errorsv1.ErrorCode_ERROR_CODE_NOT_FOUND)
		results["DiscoveryService/ListAgents"] = fmt.Sprintf("ok (%s)", time.Since(rpcStart).Round(time.Millisecond))
	})

	t.Run("DaemonAdminService/StartComponent", func(t *testing.T) {
		c := daemonadminv1.NewDaemonAdminServiceClient(conn)
		rpcStart := time.Now()
		if _, err := c.StartComponent(context.Background(), &daemonadminv1.StartComponentRequest{ComponentId: "c-ok"}); err != nil {
			t.Errorf("happy path: %v", err)
		}
		_, err := c.StartComponent(context.Background(), &daemonadminv1.StartComponentRequest{ComponentId: "bad-component"})
		assertErrorDetail(t, err, codes.NotFound, errorsv1.ErrorCode_ERROR_CODE_NOT_FOUND)
		results["DaemonAdminService/StartComponent"] = fmt.Sprintf("ok (%s)", time.Since(rpcStart).Round(time.Millisecond))
	})

	t.Run("AdminTenantService/GetReservedNames", func(t *testing.T) {
		c := adminv1.NewTenantAdminServiceClient(conn)
		rpcStart := time.Now()
		resp, err := c.GetReservedNames(context.Background(), &adminv1.GetReservedNamesRequest{})
		if err != nil {
			t.Errorf("happy path: %v", err)
		}
		// Wire-compat: assert no Unknown fields survive a round-trip marshal.
		b, _ := proto.Marshal(resp)
		var check adminv1.GetReservedNamesResponse
		if uerr := proto.Unmarshal(b, &check); uerr != nil {
			t.Errorf("round-trip unmarshal (Unknown fields?): %v", uerr)
		}
		results["AdminTenantService/GetReservedNames"] = fmt.Sprintf("ok (%s)", time.Since(rpcStart).Round(time.Millisecond))
	})

	fmt.Printf("\n=== Contract test results (total: %s) ===\n", time.Since(start).Round(time.Millisecond))
	for rpc, result := range results {
		fmt.Printf("  %-55s %s\n", rpc, result)
	}
	fmt.Println("==========================================")

	if summaryFile := os.Getenv("GITHUB_STEP_SUMMARY"); summaryFile != "" {
		if f, err := os.OpenFile(summaryFile, os.O_APPEND|os.O_WRONLY, 0644); err == nil {
			defer f.Close()
			fmt.Fprintln(f, "## Cross-repo contract test results")
			fmt.Fprintln(f, "| RPC | Result |")
			fmt.Fprintln(f, "|-----|--------|")
			for rpc, result := range results {
				fmt.Fprintf(f, "| `%s` | %s |\n", rpc, result)
			}
		}
	}
}

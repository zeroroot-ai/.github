// Copyright 2026 Zero Day AI, Inc.
// Licensed under BUSL-1.1; see LICENSE.
//
// Cross-repo contract tests — slice .github#114 of PRD .github#101.
//
// Exercises one happy-path RPC per platform-sdk service via in-process stub
// gRPC servers, then asserts ErrorDetail shape on forced failure cases.
// Each stub discriminates happy-path vs. forced-failure using a sentinel
// field value that IS present in the actual proto (verified against gen/).
//
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
	errorsv1 "github.com/zeroroot-ai/platform-sdk/gen/gibson/common/errors/v1"

	adminv1 "github.com/zeroroot-ai/platform-sdk/gen/gibson/admin/v1"
	authzv1 "github.com/zeroroot-ai/platform-sdk/gen/gibson/authz/v1"
	discoveryv1 "github.com/zeroroot-ai/platform-sdk/gen/gibson/daemon/discovery/v1"
	operatorv1 "github.com/zeroroot-ai/platform-sdk/gen/gibson/daemon/operator/v1"
	usagev1 "github.com/zeroroot-ai/platform-sdk/gen/gibson/usage/v1"
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

// DaemonOperatorService: Shutdown(force=false) → ok, Shutdown(force=true) → forced failure.
// RefreshToolCatalog(force=false) → ok, RefreshToolCatalog(force=true) → forced failure.
// Note: GetReservedNames/ListTeams/ListTeamMembers were removed in platform-sdk#44.
type stubDaemonOperator struct{ operatorv1.UnimplementedDaemonOperatorServiceServer }

func (s *stubDaemonOperator) Shutdown(_ context.Context, req *operatorv1.ShutdownRequest) (*operatorv1.ShutdownResponse, error) {
	if req.GetForce() {
		return nil, errorDetailStatus(codes.PermissionDenied, errorsv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED, "forced shutdown denied")
	}
	return &operatorv1.ShutdownResponse{}, nil
}

func (s *stubDaemonOperator) RefreshToolCatalog(_ context.Context, req *operatorv1.RefreshToolCatalogRequest) (*operatorv1.RefreshToolCatalogResponse, error) {
	if req.GetForce() {
		return nil, errorDetailStatus(codes.NotFound, errorsv1.ErrorCode_ERROR_CODE_NOT_FOUND, "catalog refresh target not found")
	}
	return &operatorv1.RefreshToolCatalogResponse{}, nil
}

// UsageService: ListUsage(scope=default) → ok, ListUsage(subject_filter="bad") → forced failure.
type stubUsage struct{ usagev1.UnimplementedUsageServiceServer }

func (s *stubUsage) ListUsage(_ context.Context, req *usagev1.ListUsageRequest) (*usagev1.ListUsageResponse, error) {
	if req.GetSubjectFilter() == "bad-tenant" {
		return nil, errorDetailStatus(codes.InvalidArgument, errorsv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "invalid tenant id")
	}
	return &usagev1.ListUsageResponse{}, nil
}

// ModelAccessService: ListAccess(subject_id="") → ok, ListAccess(subject_id="bad") → forced failure.
type stubModelAccess struct{ authzv1.UnimplementedModelAccessServiceServer }

func (s *stubModelAccess) ListAccess(_ context.Context, req *authzv1.ListAccessRequest) (*authzv1.ListAccessResponse, error) {
	if req.GetSubjectId() == "bad-tenant" {
		return nil, errorDetailStatus(codes.PermissionDenied, errorsv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED, "permission denied")
	}
	return &authzv1.ListAccessResponse{}, nil
}

// DiscoveryService: ListAgents(query=nil) → ok, ListAgents(query non-nil, limit=999) → forced failure.
// ListAgents has a *ListQuery field; we use a nil query for happy path.
type stubDiscovery struct{ discoveryv1.UnimplementedDiscoveryServiceServer }

func (s *stubDiscovery) ListAgents(_ context.Context, req *discoveryv1.ListAgentsRequest) (*discoveryv1.ListAgentsResponse, error) {
	if req.GetQuery() != nil && req.GetQuery().GetPageSize() == 999 {
		return nil, errorDetailStatus(codes.NotFound, errorsv1.ErrorCode_ERROR_CODE_NOT_FOUND, "tenant not found")
	}
	return &discoveryv1.ListAgentsResponse{}, nil
}

// Admin TenantAdminService (admin/v1): CountSecrets → ok.
// Uses rpc_filter="" for happy path, rpc_filter="bad" triggers error in forced-failure case
// via GrantsAdminService.ListActiveGrants.
type stubAdminTenant struct{ adminv1.UnimplementedTenantAdminServiceServer }

func (s *stubAdminTenant) CountSecrets(_ context.Context, _ *adminv1.CountSecretsRequest) (*adminv1.CountSecretsResponse, error) {
	return &adminv1.CountSecretsResponse{}, nil
}

type stubAdminGrants struct{ adminv1.UnimplementedGrantsAdminServiceServer }

func (s *stubAdminGrants) ListActiveGrants(_ context.Context, req *adminv1.ListActiveGrantsRequest) (*adminv1.ListActiveGrantsResponse, error) {
	if req.GetRpcFilter() == "bad-rpc" {
		return nil, errorDetailStatus(codes.InvalidArgument, errorsv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "invalid rpc filter")
	}
	return &adminv1.ListActiveGrantsResponse{}, nil
}

// --- Test harness --- //

func startStubServer(t *testing.T) string {
	t.Helper()
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	srv := grpc.NewServer()
	operatorv1.RegisterDaemonOperatorServiceServer(srv, &stubDaemonOperator{})
	usagev1.RegisterUsageServiceServer(srv, &stubUsage{})
	authzv1.RegisterModelAccessServiceServer(srv, &stubModelAccess{})
	discoveryv1.RegisterDiscoveryServiceServer(srv, &stubDiscovery{})
	adminv1.RegisterTenantAdminServiceServer(srv, &stubAdminTenant{})
	adminv1.RegisterGrantsAdminServiceServer(srv, &stubAdminGrants{})
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

	// DaemonOperatorService: Shutdown + RefreshToolCatalog (wire-compat check)
	t.Run("DaemonOperatorService/Shutdown", func(t *testing.T) {
		c := operatorv1.NewDaemonOperatorServiceClient(conn)
		rpcStart := time.Now()
		if _, err := c.Shutdown(context.Background(), &operatorv1.ShutdownRequest{Force: false}); err != nil {
			t.Errorf("happy path: %v", err)
		}
		_, err := c.Shutdown(context.Background(), &operatorv1.ShutdownRequest{Force: true})
		assertErrorDetail(t, err, codes.PermissionDenied, errorsv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED)
		results["DaemonOperatorService/Shutdown"] = fmt.Sprintf("ok (%s)", time.Since(rpcStart).Round(time.Millisecond))
	})

	t.Run("DaemonOperatorService/RefreshToolCatalog", func(t *testing.T) {
		c := operatorv1.NewDaemonOperatorServiceClient(conn)
		rpcStart := time.Now()
		if _, err := c.RefreshToolCatalog(context.Background(), &operatorv1.RefreshToolCatalogRequest{Force: false}); err != nil {
			t.Errorf("happy path: %v", err)
		}
		_, err := c.RefreshToolCatalog(context.Background(), &operatorv1.RefreshToolCatalogRequest{Force: true})
		assertErrorDetail(t, err, codes.NotFound, errorsv1.ErrorCode_ERROR_CODE_NOT_FOUND)
		results["DaemonOperatorService/RefreshToolCatalog"] = fmt.Sprintf("ok (%s)", time.Since(rpcStart).Round(time.Millisecond))
	})

	// UsageService
	t.Run("UsageService/ListUsage", func(t *testing.T) {
		c := usagev1.NewUsageServiceClient(conn)
		rpcStart := time.Now()
		if _, err := c.ListUsage(context.Background(), &usagev1.ListUsageRequest{}); err != nil {
			t.Errorf("happy path: %v", err)
		}
		_, err := c.ListUsage(context.Background(), &usagev1.ListUsageRequest{SubjectFilter: "bad-tenant"})
		assertErrorDetail(t, err, codes.InvalidArgument, errorsv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT)
		results["UsageService/ListUsage"] = fmt.Sprintf("ok (%s)", time.Since(rpcStart).Round(time.Millisecond))
	})

	// ModelAccessService
	t.Run("ModelAccessService/ListAccess", func(t *testing.T) {
		c := authzv1.NewModelAccessServiceClient(conn)
		rpcStart := time.Now()
		if _, err := c.ListAccess(context.Background(), &authzv1.ListAccessRequest{}); err != nil {
			t.Errorf("happy path: %v", err)
		}
		_, err := c.ListAccess(context.Background(), &authzv1.ListAccessRequest{SubjectId: "bad-tenant"})
		assertErrorDetail(t, err, codes.PermissionDenied, errorsv1.ErrorCode_ERROR_CODE_PERMISSION_DENIED)
		results["ModelAccessService/ListAccess"] = fmt.Sprintf("ok (%s)", time.Since(rpcStart).Round(time.Millisecond))
	})

	// DiscoveryService
	t.Run("DiscoveryService/ListAgents", func(t *testing.T) {
		c := discoveryv1.NewDiscoveryServiceClient(conn)
		rpcStart := time.Now()
		if _, err := c.ListAgents(context.Background(), &discoveryv1.ListAgentsRequest{}); err != nil {
			t.Errorf("happy path: %v", err)
		}
		_, err := c.ListAgents(context.Background(), &discoveryv1.ListAgentsRequest{
			Query: &discoveryv1.ListQuery{PageSize: 999},
		})
		assertErrorDetail(t, err, codes.NotFound, errorsv1.ErrorCode_ERROR_CODE_NOT_FOUND)
		results["DiscoveryService/ListAgents"] = fmt.Sprintf("ok (%s)", time.Since(rpcStart).Round(time.Millisecond))
	})

	// Admin TenantAdminService (admin/v1): CountSecrets happy path
	t.Run("AdminTenantService/CountSecrets", func(t *testing.T) {
		c := adminv1.NewTenantAdminServiceClient(conn)
		rpcStart := time.Now()
		if _, err := c.CountSecrets(context.Background(), &adminv1.CountSecretsRequest{}); err != nil {
			t.Errorf("happy path: %v", err)
		}
		results["AdminTenantService/CountSecrets"] = fmt.Sprintf("ok (%s)", time.Since(rpcStart).Round(time.Millisecond))
	})

	// Admin GrantsAdminService (admin/v1): forced-failure asserts ErrorDetail shape
	t.Run("AdminGrantsService/ListActiveGrants", func(t *testing.T) {
		c := adminv1.NewGrantsAdminServiceClient(conn)
		rpcStart := time.Now()
		if _, err := c.ListActiveGrants(context.Background(), &adminv1.ListActiveGrantsRequest{}); err != nil {
			t.Errorf("happy path: %v", err)
		}
		_, err := c.ListActiveGrants(context.Background(), &adminv1.ListActiveGrantsRequest{RpcFilter: "bad-rpc"})
		assertErrorDetail(t, err, codes.InvalidArgument, errorsv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT)
		results["AdminGrantsService/ListActiveGrants"] = fmt.Sprintf("ok (%s)", time.Since(rpcStart).Round(time.Millisecond))
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

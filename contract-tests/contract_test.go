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
// Surface scope: after ADR-0039 the former tenant-admin protos
// (gibson.usage.v1 UsageService, gibson.authz.v1 ModelAccessService,
// gibson.admin.v1 TenantAdminService/GrantsAdminService) moved to the OSS
// SDK and were removed from platform-sdk. The genuinely-private platform
// services that remain here are DaemonOperatorService, DiscoveryService, and
// BillingService — those are what this suite covers.
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

	billingv1 "github.com/zeroroot-ai/platform-sdk/gen/gibson/billing/v1"
	discoveryv1 "github.com/zeroroot-ai/platform-sdk/gen/gibson/daemon/discovery/v1"
	operatorv1 "github.com/zeroroot-ai/platform-sdk/gen/gibson/daemon/operator/v1"
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

// DiscoveryService: ListAgents(query=nil) → ok, ListAgents(query non-nil, limit=999) → forced failure.
// ListAgents has a *ListQuery field; we use a nil query for happy path.
type stubDiscovery struct{ discoveryv1.UnimplementedDiscoveryServiceServer }

func (s *stubDiscovery) ListAgents(_ context.Context, req *discoveryv1.ListAgentsRequest) (*discoveryv1.ListAgentsResponse, error) {
	if req.GetQuery() != nil && req.GetQuery().GetPageSize() == 999 {
		return nil, errorDetailStatus(codes.NotFound, errorsv1.ErrorCode_ERROR_CODE_NOT_FOUND, "tenant not found")
	}
	return &discoveryv1.ListAgentsResponse{}, nil
}

// BillingService: RecordWebhookEvent(event_id set) → ok, RecordWebhookEvent(event_id="bad-event") → forced failure.
type stubBilling struct{ billingv1.UnimplementedBillingServiceServer }

func (s *stubBilling) RecordWebhookEvent(_ context.Context, req *billingv1.RecordWebhookEventRequest) (*billingv1.RecordWebhookEventResponse, error) {
	if req.GetEventId() == "bad-event" {
		return nil, errorDetailStatus(codes.InvalidArgument, errorsv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT, "invalid webhook event id")
	}
	return &billingv1.RecordWebhookEventResponse{IsNew: true}, nil
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
	discoveryv1.RegisterDiscoveryServiceServer(srv, &stubDiscovery{})
	billingv1.RegisterBillingServiceServer(srv, &stubBilling{})
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

	// BillingService: RecordWebhookEvent happy path + forced-failure ErrorDetail shape
	t.Run("BillingService/RecordWebhookEvent", func(t *testing.T) {
		c := billingv1.NewBillingServiceClient(conn)
		rpcStart := time.Now()
		if _, err := c.RecordWebhookEvent(context.Background(), &billingv1.RecordWebhookEventRequest{EventId: "evt_123", EventType: "invoice.paid"}); err != nil {
			t.Errorf("happy path: %v", err)
		}
		_, err := c.RecordWebhookEvent(context.Background(), &billingv1.RecordWebhookEventRequest{EventId: "bad-event"})
		assertErrorDetail(t, err, codes.InvalidArgument, errorsv1.ErrorCode_ERROR_CODE_INVALID_ARGUMENT)
		results["BillingService/RecordWebhookEvent"] = fmt.Sprintf("ok (%s)", time.Since(rpcStart).Round(time.Millisecond))
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

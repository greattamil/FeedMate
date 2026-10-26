// Command api is the Andipatti Animal Feed System Go backend HTTP server.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/andipatti/feedmate/services/api/internal/config"
	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/auditlog"
	"github.com/andipatti/feedmate/services/api/internal/domain/cloudusage"
	"github.com/andipatti/feedmate/services/api/internal/domain/contra"
	"github.com/andipatti/feedmate/services/api/internal/domain/customer"
	"github.com/andipatti/feedmate/services/api/internal/domain/dbbackup"
	"github.com/andipatti/feedmate/services/api/internal/domain/devicepairing"
	"github.com/andipatti/feedmate/services/api/internal/domain/docseries"
	"github.com/andipatti/feedmate/services/api/internal/domain/eod"
	"github.com/andipatti/feedmate/services/api/internal/domain/identity"
	"github.com/andipatti/feedmate/services/api/internal/domain/location"
	"github.com/andipatti/feedmate/services/api/internal/domain/masterdata"
	"github.com/andipatti/feedmate/services/api/internal/domain/notify"
	"github.com/andipatti/feedmate/services/api/internal/domain/payment"
	"github.com/andipatti/feedmate/services/api/internal/domain/platformadmin"
	"github.com/andipatti/feedmate/services/api/internal/domain/pos"
	"github.com/andipatti/feedmate/services/api/internal/domain/procurement"
	"github.com/andipatti/feedmate/services/api/internal/domain/product"
	"github.com/andipatti/feedmate/services/api/internal/domain/pushnotify"
	"github.com/andipatti/feedmate/services/api/internal/domain/reports"
	"github.com/andipatti/feedmate/services/api/internal/domain/returns"
	"github.com/andipatti/feedmate/services/api/internal/domain/settings"
	"github.com/andipatti/feedmate/services/api/internal/domain/stockcount"
	"github.com/andipatti/feedmate/services/api/internal/domain/subscription"
	"github.com/andipatti/feedmate/services/api/internal/domain/supplier"
	"github.com/andipatti/feedmate/services/api/internal/httpapi"
	appmw "github.com/andipatti/feedmate/services/api/internal/middleware"
	"github.com/andipatti/feedmate/services/api/internal/paymentprovider"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	cfg, err := config.Load()
	if err != nil {
		slog.Error("configuration error", "error", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	db, err := dbctx.ConnectWithPoolConfig(ctx, cfg.DatabaseURL, cfg.DatabaseAdminURL, dbctx.PoolConfig{
		AppUserMaxConns: cfg.DBPoolMaxConns,
		AdminMaxConns:   cfg.DBAdminPoolMaxConns,
	})
	cancel()
	if err != nil {
		slog.Error("database connection failed", "error", err)
		os.Exit(1)
	}
	defer db.Close()

	identitySvc := identity.NewService(db, cfg.JWTSigningKey, cfg.AccessTokenTTL, cfg.RefreshTokenTTL, cfg.BcryptCost)
	productSvc := product.NewService(db)
	pushNotifySvc := pushnotify.NewService(db, cfg.FirebaseProjectID)
	notifySvc := notify.NewService(db, pushNotifySvc)
	posSvc := pos.NewService(db, notifySvc)
	procurementSvc := procurement.NewService(db)
	returnsSvc := returns.NewService(db)
	contraSvc := contra.NewService(db)
	eodSvc := eod.NewService(db)
	reportsSvc := reports.NewService(db)
	auditLogSvc := auditlog.NewService(db)
	stockCountSvc := stockcount.NewService(db)
	docSeriesSvc := docseries.NewService(db)
	locationSvc := location.NewService(db)
	devicePairingSvc := devicepairing.NewService(db)
	customerSvc := customer.NewService(db)
	supplierSvc := supplier.NewService(db)
	masterDataSvc := masterdata.NewService(db)
	settingsSvc := settings.NewService(db)
	platformSvc := platformadmin.NewService(db, cfg.JWTSigningKey, cfg.AccessTokenTTL, cfg.RefreshTokenTTL, cfg.BcryptCost)
	subscriptionSvc := subscription.NewService(db)
	cloudUsageSvc := cloudusage.NewService(db, cfg.CloudflareAPIToken, cfg.CloudflareAccountID, cfg.GCPProjectID, cfg.AivenAPIToken, cfg.AivenProject, cfg.AivenService)

	var provider paymentprovider.Provider
	switch cfg.PaymentProvider {
	case "sandbox":
		provider = paymentprovider.NewSandboxProvider(cfg.SandboxWebhookSecret)
	default:
		slog.Error("unknown PAYMENT_PROVIDER", "value", cfg.PaymentProvider)
		os.Exit(1)
	}
	paymentSvc := payment.NewService(db, provider)

	authHandlers := &httpapi.AuthHandlers{Identity: identitySvc}
	staffHandlers := &httpapi.StaffHandlers{Identity: identitySvc}
	healthHandlers := &httpapi.HealthHandlers{DB: db}
	productHandlers := &httpapi.ProductHandlers{Product: productSvc}
	posHandlers := &httpapi.POSHandlers{POS: posSvc}
	procurementHandlers := &httpapi.ProcurementHandlers{Procurement: procurementSvc}
	returnsHandlers := &httpapi.ReturnsHandlers{Returns: returnsSvc}
	paymentHandlers := &httpapi.PaymentHandlers{Payment: paymentSvc}
	contraHandlers := &httpapi.ContraHandlers{Contra: contraSvc}
	eodHandlers := &httpapi.EODHandlers{EOD: eodSvc}
	reportsHandlers := &httpapi.ReportsHandlers{Reports: reportsSvc}
	auditLogHandlers := &httpapi.AuditLogHandlers{AuditLog: auditLogSvc}
	stockCountHandlers := &httpapi.StockCountHandlers{StockCount: stockCountSvc}
	docSeriesHandlers := &httpapi.DocSeriesHandlers{DocSeries: docSeriesSvc}
	locationHandlers := &httpapi.LocationHandlers{Location: locationSvc}
	deviceHandlers := &httpapi.DeviceHandlers{DevicePairing: devicePairingSvc, PushNotify: pushNotifySvc}
	customerHandlers := &httpapi.CustomerHandlers{Customer: customerSvc}
	supplierHandlers := &httpapi.SupplierHandlers{Supplier: supplierSvc}
	masterDataHandlers := &httpapi.MasterDataHandlers{MasterData: masterDataSvc}
	settingsHandlers := &httpapi.SettingsHandlers{Settings: settingsSvc}
	platformHandlers := &httpapi.PlatformHandlers{Platform: platformSvc, Subscription: subscriptionSvc}
	cloudUsageHandlers := &httpapi.CloudUsageHandlers{CloudUsage: cloudUsageSvc}
	dbBackupTrigger := &dbbackup.Trigger{HTTPClient: http.DefaultClient, ProjectID: cfg.GCPProjectID, Region: cfg.GCPRegion, JobName: cfg.DBBackupJobName}
	cronHandlers := &httpapi.CronHandlers{Subscription: subscriptionSvc, CloudUsage: cloudUsageSvc, Customer: customerSvc, Notify: notifySvc, DBBackup: dbBackupTrigger, CronSecret: cfg.CronSecret}

	// PublicWebsiteTenantID is parsed once here, not per-request — an
	// unset/invalid value leaves this nil, and PublicHandlers.GetPublicCatalog
	// fails closed (500) rather than guessing a tenant on every call.
	var publicWebsiteTenantID *uuid.UUID
	if cfg.PublicWebsiteTenantID != "" {
		if id, err := uuid.Parse(cfg.PublicWebsiteTenantID); err == nil {
			publicWebsiteTenantID = &id
		} else {
			slog.Error("invalid PUBLIC_WEBSITE_TENANT_ID, public catalog endpoint disabled", "error", err)
		}
	}
	publicHandlers := &httpapi.PublicHandlers{DB: db, PublicWebsiteTenantID: publicWebsiteTenantID}

	// Full debug-level detail for every error response — not just
	// CodeInternal — is persisted here so the platform admin's error log
	// screen can show more than "check docker logs" — see
	// httpapi.SetErrorSink's doc comment. Fire-and-forget on its own
	// short-lived context: a broken error-log write must never fail or
	// slow down the request that triggered it.
	httpapi.SetErrorSink(func(detail httpapi.ErrorLogDetail) {
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			var reqIDPtr *uuid.UUID
			if id, err := uuid.Parse(detail.RequestID); err == nil {
				reqIDPtr = &id
			}
			parseUUIDPtr := func(s *string) *uuid.UUID {
				if s == nil {
					return nil
				}
				if id, err := uuid.Parse(*s); err == nil {
					return &id
				}
				return nil
			}
			in := platformadmin.RecordErrorInput{
				RequestID: reqIDPtr, StatusCode: detail.StatusCode, Code: detail.Code, Message: detail.Message,
				Method: detail.Method, Path: detail.Path, QueryParams: detail.QueryParams, RequestBody: detail.RequestBody,
				IPAddress: detail.IP, UserAgent: detail.UserAgent, StackTrace: detail.StackTrace,
				TenantID: parseUUIDPtr(detail.TenantID), ActorUserID: parseUUIDPtr(detail.ActorUserID), ActorPlatformAdminID: parseUUIDPtr(detail.ActorPlatformAdminID),
			}
			if err := platformSvc.RecordError(ctx, in); err != nil {
				slog.Error("failed to persist error log", "error", err)
			}
		}()
	})

	r := chi.NewRouter()
	r.Use(appmw.RequireEdgeSecret(cfg.EdgeSharedSecret))
	r.Use(appmw.RequestID)
	r.Use(appmw.CaptureRequestMeta)
	r.Use(appmw.BufferRequestBody)
	r.Use(appmw.Recoverer)
	r.Use(appmw.CORS)

	r.Get("/health/live", healthHandlers.Live)
	r.Get("/health/ready", healthHandlers.Ready)

	r.Route("/api/v1", func(r chi.Router) {
		r.Post("/auth/login", authHandlers.Login)
		r.Post("/auth/refresh", authHandlers.Refresh)
		r.Post("/auth/logout", authHandlers.Logout)

		// Platform admin — a separate login entirely from tenant auth above
		// (no device, no tenant); see platformadmin.Service's doc comment.
		r.Post("/platform/auth/login", platformHandlers.Login)
		r.Post("/platform/auth/refresh", platformHandlers.Refresh)
		r.Post("/platform/auth/logout", platformHandlers.Logout)
		r.Group(func(r chi.Router) {
			r.Use(appmw.RequireAuth(cfg.JWTSigningKey))
			r.Use(appmw.RequirePlatform)

			r.Get("/platform/tenants", platformHandlers.ListTenants)
			r.Post("/platform/tenants", platformHandlers.CreateTenant)
			r.Get("/platform/tenants/{id}", platformHandlers.GetTenant)
			r.Put("/platform/tenants/{id}", platformHandlers.UpdateTenant)
			r.Post("/platform/tenants/{id}/status", platformHandlers.SetTenantStatus)
			r.Put("/platform/tenants/{id}/plan", platformHandlers.SetTenantPlan)
			r.Put("/platform/tenants/{id}/branding", platformHandlers.SetTenantBranding)
			r.Put("/platform/tenants/{id}/features", platformHandlers.SetTenantFeature)
			r.Get("/platform/tenants/{id}/users", platformHandlers.ListTenantUsers)
			r.Post("/platform/tenants/{id}/users", platformHandlers.CreateTenantUser)
			r.Get("/platform/tenants/{id}/users/{userId}", platformHandlers.GetTenantUser)
			r.Put("/platform/tenants/{id}/users/{userId}", platformHandlers.UpdateTenantUser)
			r.Post("/platform/tenants/{id}/users/{userId}/status", platformHandlers.SetTenantUserStatus)
			r.Post("/platform/tenants/{id}/users/{userId}/reset-password", platformHandlers.ResetTenantUserPassword)
			r.Get("/platform/tenants/{id}/roles", platformHandlers.ListTenantUserRoles)
			r.Put("/platform/tenants/{id}/users/{userId}/roles", platformHandlers.SetTenantUserRoles)
			r.Get("/platform/tenants/{id}/devices", platformHandlers.ListTenantDevices)
			r.Post("/platform/tenants/{id}/devices/{deviceId}/revoke", platformHandlers.RevokeTenantDevice)
			r.Post("/platform/tenants/{id}/devices/pairing-codes", platformHandlers.GeneratePairingCodeForTenant)
			r.Get("/platform/plans", platformHandlers.ListPlans)
			r.Post("/platform/plans", platformHandlers.CreatePlan)
			r.Put("/platform/plans/{id}", platformHandlers.UpdatePlan)
			r.Get("/platform/tenants/{id}/subscription", platformHandlers.GetTenantSubscription)
			r.Put("/platform/tenants/{id}/subscription/plan", platformHandlers.SetTenantSubscriptionPlan)
			r.Post("/platform/tenants/{id}/subscription/payments", platformHandlers.RecordSubscriptionPayment)
			r.Get("/platform/tenants/{id}/subscription/payments", platformHandlers.ListBillingHistory)
			r.Get("/platform/audit-logs", platformHandlers.ListAuditLogs)
			r.Get("/platform/error-logs", platformHandlers.ListErrorLogs)
			r.Get("/platform/settings", platformHandlers.GetPlatformSettings)
			r.Put("/platform/settings", platformHandlers.UpdatePlatformSettings)
			r.Get("/platform/cloud-usage", cloudUsageHandlers.ListUsage)
			r.Get("/platform/cloud-usage/alerts", cloudUsageHandlers.ListAlerts)
			r.Post("/platform/cloud-usage/refresh", cloudUsageHandlers.Refresh)
			r.Put("/platform/cloud-usage/thresholds/{id}", cloudUsageHandlers.UpdateThreshold)
		})

		// The one place "FeedMate" / its tagline / logo / color come from —
		// deliberately unauthenticated (see GetBranding's doc comment): the
		// login screen has no access token, only an optional device_uuid.
		r.Get("/branding", platformHandlers.GetBranding)

		// A brand new device has no access token — its only credential is a
		// short-lived pairing code generated by an already-authenticated user
		// on another device (see devicepairing.Service). Deliberately not
		// behind RequireAuth.
		r.Post("/devices/register", deviceHandlers.RegisterDevice)

		// The marketing website (bpks-website/, a separate static site, not
		// FeedMate itself) fetches this directly from the visitor's browser
		// with no credential at all — see httpapi.PublicHandlers's doc
		// comment for why that's safe (pinned to one tenant via server
		// config, never request input).
		r.Get("/public/catalog", publicHandlers.GetPublicCatalog)

		// Google Cloud Scheduler calls these on a schedule to drive the
		// billing cycle and cloud-usage poll on Cloud Run — see
		// httpapi.CronHandlers's doc comment for why an in-process ticker
		// alone isn't reliable there. Gated by CronSecret, not RequireAuth
		// (Cloud Scheduler carries no user JWT).
		r.Post("/internal/cron/billing-cycle", cronHandlers.RunBillingCycle)
		r.Post("/internal/cron/cloud-usage-poll", cronHandlers.PollCloudUsage)
		r.Post("/internal/cron/overdue-sweep", cronHandlers.RunOverdueSweep)
		// Combined billing-cycle + overdue-sweep, scheduled as a single
		// Cloud Scheduler job instead of two — see RunDailyTasks's doc
		// comment (Cloud Scheduler's Always Free tier is 3 jobs/account).
		// The two individual routes above stay for manual/debug use, just
		// aren't each given their own Scheduler job anymore.
		r.Post("/internal/cron/daily-tasks", cronHandlers.RunDailyTasks)
		// Triggered by a Cloudflare Worker Cron Trigger, not Google Cloud
		// Scheduler — see internal/domain/dbbackup's doc comment.
		r.Post("/internal/cron/trigger-db-backup", cronHandlers.TriggerDBBackup)

		// Payment webhooks are called by the external provider, which cannot
		// present one of our bearer tokens — authentication here is the
		// provider's cryptographic signature (verified inside the handler),
		// never RequireAuth.
		r.Post("/payments/webhooks/sandbox", paymentHandlers.SandboxWebhook)

		r.Group(func(r chi.Router) {
			r.Use(appmw.RequireAuth(cfg.JWTSigningKey))

			// Any authenticated device may set its own FCM push token —
			// scoped to claims.DeviceID, no special permission needed.
			r.Put("/devices/fcm-token", deviceHandlers.SetFCMToken)

			r.Get("/products/search", productHandlers.Search)
			r.Get("/products", productHandlers.List)
			r.Get("/products/{id}", productHandlers.Get)
			r.With(appmw.RequirePermission("product.manage")).Post("/products", productHandlers.Create)
			r.With(appmw.RequirePermission("product.manage")).Put("/products/{id}", productHandlers.Update)
			r.With(appmw.RequirePermission("product.manage")).Post("/products/{id}/status", productHandlers.SetStatus)

			r.Get("/categories", masterDataHandlers.ListCategories)
			r.With(appmw.RequirePermission("product.manage")).Get("/categories/all", masterDataHandlers.ListAllCategories)
			r.With(appmw.RequirePermission("product.manage")).Post("/categories", masterDataHandlers.CreateCategory)
			r.With(appmw.RequirePermission("product.manage")).Put("/categories/{id}", masterDataHandlers.UpdateCategory)
			r.With(appmw.RequirePermission("product.manage")).Post("/categories/{id}/status", masterDataHandlers.SetCategoryActive)
			r.Get("/brands", masterDataHandlers.ListBrands)
			r.With(appmw.RequirePermission("product.manage")).Get("/brands/all", masterDataHandlers.ListAllBrands)
			r.With(appmw.RequirePermission("product.manage")).Post("/brands", masterDataHandlers.CreateBrand)
			r.With(appmw.RequirePermission("product.manage")).Put("/brands/{id}", masterDataHandlers.UpdateBrand)
			r.With(appmw.RequirePermission("product.manage")).Post("/brands/{id}/status", masterDataHandlers.SetBrandActive)
			r.Get("/uoms", masterDataHandlers.ListUOMs)
			r.Get("/tax-profiles", masterDataHandlers.ListTaxProfiles)
			r.With(appmw.RequirePermission("product.manage")).Get("/tax-profiles/all", masterDataHandlers.ListAllTaxProfiles)
			r.With(appmw.RequirePermission("product.manage")).Post("/tax-profiles", masterDataHandlers.CreateTaxProfile)
			r.With(appmw.RequirePermission("product.manage")).Put("/tax-profiles/{id}", masterDataHandlers.UpdateTaxProfile)
			r.With(appmw.RequirePermission("product.manage")).Post("/tax-profiles/{id}/status", masterDataHandlers.SetTaxProfileActive)

			r.With(appmw.RequirePermission("pos.sell")).Post("/pos/quote", posHandlers.Quote)
			r.With(appmw.RequirePermission("pos.sell")).Post("/pos/invoices", posHandlers.FinalizeInvoice)
			r.With(appmw.RequirePermission("return.create")).Get("/pos/invoices", posHandlers.GetInvoiceForReturn)
			r.With(appmw.RequirePermission("pos.sell")).Get("/pos/invoices/history", posHandlers.ListInvoices)
			r.With(appmw.RequirePermission("pos.sell")).Get("/pos/invoices/{id}", posHandlers.GetInvoiceDetail)

			r.With(appmw.RequirePermission("pos.sell")).Get("/locations", locationHandlers.List)
			r.With(appmw.RequirePermission("product.manage")).Get("/locations/all", locationHandlers.ListAll)
			r.With(appmw.RequirePermission("product.manage")).Post("/locations", locationHandlers.Create)
			r.With(appmw.RequirePermission("product.manage")).Put("/locations/{id}", locationHandlers.Update)
			r.With(appmw.RequirePermission("product.manage")).Post("/locations/{id}/status", locationHandlers.SetActive)

			r.With(appmw.RequirePermission("device.manage")).Post("/devices/pairing-codes", deviceHandlers.GeneratePairingCode)
			r.With(appmw.RequirePermission("device.manage")).Get("/devices", deviceHandlers.List)
			r.With(appmw.RequirePermission("device.manage")).Post("/devices/{id}/revoke", deviceHandlers.Revoke)

			r.With(appmw.RequirePermission("user.manage")).Post("/users", staffHandlers.CreateUser)
			r.With(appmw.RequirePermission("user.manage")).Get("/users", staffHandlers.ListUsers)
			r.With(appmw.RequirePermission("user.manage")).Get("/users/{id}", staffHandlers.GetUser)
			r.With(appmw.RequirePermission("user.manage")).Put("/users/{id}", staffHandlers.UpdateUser)
			r.With(appmw.RequirePermission("user.manage")).Post("/users/{id}/status", staffHandlers.SetUserStatus)
			r.With(appmw.RequirePermission("user.manage")).Post("/users/{id}/reset-password", staffHandlers.ResetUserPassword)
			r.With(appmw.RequirePermission("user.manage")).Put("/users/{id}/roles", staffHandlers.SetUserRoles)
			r.With(appmw.RequirePermission("user.manage")).Get("/roles", staffHandlers.ListRoles)

			r.With(appmw.RequirePermission("grn.post")).Post("/procurement/grns", procurementHandlers.PostGRN)
			r.With(appmw.RequirePermission("grn.post")).Get("/procurement/grns", procurementHandlers.ListGRNs)
			r.With(appmw.RequirePermission("grn.post")).Get("/procurement/grns/{id}", procurementHandlers.GetGRNDetail)

			r.With(appmw.RequirePermission("return.create")).Post("/pos/returns", returnsHandlers.PostReturn)

			r.With(appmw.RequirePermission("pos.sell")).Post("/payments/receipt-intents", paymentHandlers.CreateReceiptIntent)
			r.With(appmw.RequirePermission("pos.sell")).Get("/payments/intents/{id}", paymentHandlers.GetIntentStatus)
			r.With(appmw.RequirePermission("pos.sell")).Post("/payments/receipts", paymentHandlers.RecordManualReceipt)
			r.With(appmw.RequirePermission("pos.sell")).Get("/payments/{id}", paymentHandlers.GetManualPayment)
			r.With(appmw.RequirePermission("supplier.manage")).Post("/payments/supplier-payments", paymentHandlers.RecordSupplierPayment)

			r.With(appmw.RequirePermission("contra.approve")).Post("/contra", contraHandlers.PostContra)

			r.With(appmw.RequirePermission("cash.eod_close")).Post("/eod/open", eodHandlers.OpenSession)
			r.With(appmw.RequirePermission("cash.eod_close")).Post("/eod/close", eodHandlers.CloseSession)
			r.With(appmw.RequirePermission("eod.reopen")).Post("/eod/reopen", eodHandlers.ReopenSession)
			r.With(appmw.RequirePermission("cash.eod_close")).Get("/eod", eodHandlers.GetSession)
			r.With(appmw.RequirePermission("cash.eod_close")).Post("/eod/cash-movements", eodHandlers.RecordCashMovement)
			r.With(appmw.RequirePermission("cash.eod_close")).Get("/eod/cash-movements", eodHandlers.ListCashMovements)

			r.With(appmw.RequirePermission("report.view")).Get("/reports/sales-summary", reportsHandlers.SalesSummary)
			r.With(appmw.RequirePermission("report.view")).Get("/reports/stock-on-hand", reportsHandlers.StockOnHand)
			// Unlike the other /reports/* routes, stock-summary is not
			// gated on report.view: every staff role that can see the
			// product catalog (POS cashiers included) needs to see real
			// stock/reorder status, the same way /products has no extra
			// permission gate.
			r.Get("/reports/stock-summary", reportsHandlers.StockSummary)
			r.With(appmw.RequirePermission("report.view")).Get("/reports/customer-balances", reportsHandlers.CustomerBalances)
			r.With(appmw.RequirePermission("report.view")).Get("/reports/eod-history", reportsHandlers.EODHistory)
			r.With(appmw.RequirePermission("report.view")).Get("/reports/dashboard", reportsHandlers.DashboardOverview)

			r.With(appmw.RequirePermission("tenant.admin")).Get("/audit-logs", auditLogHandlers.List)

			r.With(appmw.RequirePermission("stock.count")).Post("/stock-counts", stockCountHandlers.StartCount)
			r.With(appmw.RequirePermission("stock.count")).Get("/stock-counts", stockCountHandlers.ListCounts)
			r.With(appmw.RequirePermission("stock.count")).Get("/stock-counts/{id}", stockCountHandlers.GetCountDetail)
			r.With(appmw.RequirePermission("stock.count")).Get("/stock-counts/{id}/batches", stockCountHandlers.ListBatchesForProduct)
			r.With(appmw.RequirePermission("stock.count")).Post("/stock-counts/{id}/lines", stockCountHandlers.RecordCount)
			r.With(appmw.RequirePermission("stock.count")).Post("/stock-counts/{id}/post", stockCountHandlers.PostCount)
			r.With(appmw.RequirePermission("stock.count")).Post("/stock-counts/{id}/cancel", stockCountHandlers.CancelCount)

			r.With(appmw.RequirePermission("tenant.admin")).Get("/financial-years", docSeriesHandlers.ListFinancialYears)
			r.With(appmw.RequirePermission("tenant.admin")).Post("/financial-years", docSeriesHandlers.CreateFinancialYear)
			r.With(appmw.RequirePermission("tenant.admin")).Post("/financial-years/{id}/close", docSeriesHandlers.CloseFinancialYear)
			r.With(appmw.RequirePermission("tenant.admin")).Get("/financial-years/{id}/document-series", docSeriesHandlers.ListDocumentSeries)
			r.With(appmw.RequirePermission("tenant.admin")).Post("/financial-years/{id}/document-series", docSeriesHandlers.CreateDocumentSeries)
			r.With(appmw.RequirePermission("tenant.admin")).Post("/financial-years/{id}/document-series/seed-defaults", docSeriesHandlers.SeedDefaultSeries)
			r.With(appmw.RequirePermission("tenant.admin")).Post("/document-series/{id}/status", docSeriesHandlers.SetDocumentSeriesActive)

			r.With(appmw.RequirePermission("tenant.admin")).Get("/settings/store-profile", settingsHandlers.GetStoreProfile)
			r.With(appmw.RequirePermission("tenant.admin")).Put("/settings/store-profile", settingsHandlers.UpdateStoreProfile)
			r.With(appmw.RequirePermission("tenant.admin")).Get("/settings/notification-prefs", settingsHandlers.GetNotificationPrefs)
			r.With(appmw.RequirePermission("tenant.admin")).Put("/settings/notification-prefs", settingsHandlers.UpdateNotificationPrefs)

			r.Get("/customers", customerHandlers.List)
			r.Get("/customers/{id}", customerHandlers.Get)
			r.Get("/customers/{id}/ledger", customerHandlers.Ledger)
			r.With(appmw.RequirePermission("credit.configure")).Post("/customers", customerHandlers.Create)
			r.With(appmw.RequirePermission("credit.configure")).Put("/customers/{id}", customerHandlers.Update)
			r.With(appmw.RequirePermission("credit.configure")).Post("/customers/{id}/status", customerHandlers.SetStatus)
			r.With(appmw.RequirePermission("credit.configure")).Put("/customers/{id}/credit-limit", customerHandlers.SetCreditLimit)

			r.Get("/suppliers", supplierHandlers.List)
			r.Get("/suppliers/{id}", supplierHandlers.Get)
			r.Get("/suppliers/{id}/ledger", supplierHandlers.Ledger)
			r.With(appmw.RequirePermission("supplier.manage")).Post("/suppliers", supplierHandlers.Create)
			r.With(appmw.RequirePermission("supplier.manage")).Put("/suppliers/{id}", supplierHandlers.Update)
			r.With(appmw.RequirePermission("supplier.manage")).Post("/suppliers/{id}/status", supplierHandlers.SetStatus)

			// Further authenticated routes (inventory, etc.) are registered
			// here as each domain module is implemented.
		})
	})

	// Advances past-due subscriptions and auto-suspends tenants whose grace
	// period has elapsed, plus the cloud-usage poll — see
	// subscription.Service.StartBillingScheduler's doc comment for why
	// this in-process ticker is only enabled by default on deployments
	// where the process runs continuously (self-hosted/VPS). Cloud Run
	// (cfg.EnableInProcessScheduler=false there) drives the same work via
	// Google Cloud Scheduler hitting /internal/cron/* instead — see
	// httpapi.CronHandlers.
	if cfg.EnableInProcessScheduler {
		schedulerCtx, stopScheduler := context.WithCancel(context.Background())
		defer stopScheduler()
		go subscriptionSvc.StartBillingScheduler(schedulerCtx, 24*time.Hour)
		go cloudUsageSvc.StartUsagePollScheduler(schedulerCtx, cfg.CloudUsagePollInterval)
	}

	srv := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           r,
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		slog.Info("api server starting", "addr", cfg.HTTPAddr, "env", cfg.AppEnv)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	slog.Info("shutting down")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("graceful shutdown failed", "error", err)
	}
}

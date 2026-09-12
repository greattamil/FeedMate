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

	"github.com/andipatti/feedmate/services/api/internal/config"
	"github.com/andipatti/feedmate/services/api/internal/dbctx"
	"github.com/andipatti/feedmate/services/api/internal/domain/identity"
	"github.com/andipatti/feedmate/services/api/internal/domain/pos"
	"github.com/andipatti/feedmate/services/api/internal/domain/procurement"
	"github.com/andipatti/feedmate/services/api/internal/domain/product"
	"github.com/andipatti/feedmate/services/api/internal/httpapi"
	appmw "github.com/andipatti/feedmate/services/api/internal/middleware"
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
	db, err := dbctx.Connect(ctx, cfg.DatabaseURL, cfg.DatabaseAdminURL)
	cancel()
	if err != nil {
		slog.Error("database connection failed", "error", err)
		os.Exit(1)
	}
	defer db.Close()

	identitySvc := identity.NewService(db, cfg.JWTSigningKey, cfg.AccessTokenTTL, cfg.RefreshTokenTTL, cfg.BcryptCost)
	productSvc := product.NewService(db)
	posSvc := pos.NewService(db)
	procurementSvc := procurement.NewService(db)

	authHandlers := &httpapi.AuthHandlers{Identity: identitySvc}
	healthHandlers := &httpapi.HealthHandlers{DB: db}
	productHandlers := &httpapi.ProductHandlers{Product: productSvc}
	posHandlers := &httpapi.POSHandlers{POS: posSvc}
	procurementHandlers := &httpapi.ProcurementHandlers{Procurement: procurementSvc}

	r := chi.NewRouter()
	r.Use(appmw.RequestID)
	r.Use(appmw.Recoverer)

	r.Get("/health/live", healthHandlers.Live)
	r.Get("/health/ready", healthHandlers.Ready)

	r.Route("/api/v1", func(r chi.Router) {
		r.Post("/auth/login", authHandlers.Login)
		r.Post("/auth/refresh", authHandlers.Refresh)
		r.Post("/auth/logout", authHandlers.Logout)

		r.Group(func(r chi.Router) {
			r.Use(appmw.RequireAuth(cfg.JWTSigningKey))

			r.Get("/products/search", productHandlers.Search)
			r.Get("/products/{id}", productHandlers.Get)
			r.With(appmw.RequirePermission("product.manage")).Post("/products", productHandlers.Create)

			r.With(appmw.RequirePermission("pos.sell")).Post("/pos/invoices", posHandlers.FinalizeInvoice)

			r.With(appmw.RequirePermission("grn.post")).Post("/procurement/grns", procurementHandlers.PostGRN)

			// Further authenticated routes (customers, inventory, procurement,
			// etc.) are registered here as each domain module is implemented.
		})
	})

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

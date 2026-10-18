// Command connect-api runs the MyBuddy Connect signaling/registry service.
//
// It listens on loopback by default and must be exposed only through a TLS
// reverse proxy (see infrastructure/). Configuration is via MYBUDDY_* env vars.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"mybuddy.local/connect-api/internal/api"
	"mybuddy.local/connect-api/internal/config"
	"mybuddy.local/connect-api/internal/store"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		os.Exit(healthcheck())
	}
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if err := run(log); err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var st store.Store
	if cfg.DatabaseURL != "" {
		pg, err := store.OpenPostgres(ctx, cfg.DatabaseURL)
		if err != nil {
			return err
		}
		st = pg
	} else {
		log.Warn("MYBUDDY_DATABASE_URL not set: using the in-memory store (data is lost on restart)")
		st = store.NewMemoryStore()
	}
	defer st.Close()

	srv := api.New(api.Options{Config: cfg, Store: st, Log: log})
	go srv.RunMaintenance(ctx, time.Minute)

	httpServer := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    16 * 1024,
	}
	errCh := make(chan error, 1)
	go func() {
		log.Info("connect-api listening", "config", cfg.String())
		errCh <- httpServer.ListenAndServe()
	}()
	select {
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		log.Info("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return httpServer.Shutdown(shutdownCtx)
	}
	return nil
}

// healthcheck probes /healthz on this container's listener (distroless images have no curl).
func healthcheck() int {
	_, port, err := net.SplitHostPort(os.Getenv("MYBUDDY_LISTEN"))
	if err != nil || port == "" {
		port = "8787"
	}
	client := http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://127.0.0.1:" + port + "/healthz")
	if err != nil {
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 1
	}
	return 0
}

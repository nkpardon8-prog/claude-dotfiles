package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"macmini-server/internal/auth"
	"macmini-server/internal/config"
	"macmini-server/internal/handlers/admin"
	"macmini-server/internal/handlers/files"
	"macmini-server/internal/handlers/health"
	"macmini-server/internal/handlers/paste"
	runh "macmini-server/internal/handlers/run"
	"macmini-server/internal/handlers/shot"
	"macmini-server/internal/logging"
	"macmini-server/internal/redact"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		// Fall back to stderr because the rotating writer isn't open yet.
		slog.Error("config_load_failed", slog.String("err", err.Error()))
		os.Exit(2)
	}

	rw, err := logging.NewRotatingWriter(cfg.LogPath)
	if err != nil {
		slog.Error("log_open_failed", slog.String("err", err.Error()), slog.String("path", cfg.LogPath))
		os.Exit(2)
	}
	defer rw.Close()
	logger := logging.NewLogger(rw)
	slog.SetDefault(logger)

	if err := auth.LoadToken(cfg.TokenPath); err != nil {
		logger.Error("token_load_failed",
			slog.String("err", err.Error()),
			slog.String("path", cfg.TokenPath),
			slog.String("hint", "run skills/macmini/install/install.sh to generate"),
		)
		os.Exit(2)
	}

	redactList := redact.BuildRedactList()
	logger.Info("redact_list_built", slog.Int("count", len(redactList)))

	mux := http.NewServeMux()

	// Per-request log middleware wraps every authed handler. /health stays
	// outside auth but inside logging.
	logMW := logging.Middleware(logger)
	authMW := func(next http.Handler) http.Handler { return logMW(auth.Middleware(next)) }

	// /health: logging only, no auth.
	healthMux := http.NewServeMux()
	health.Register(healthMux, cfg.Version, cfg.StartTime)
	mux.Handle("GET /health", logMW(healthMux))

	paste.Register(mux, authMW)
	files.Register(mux, authMW)
	runh.Register(mux, authMW, redactList)
	shot.Register(mux, authMW)
	admin.Register(mux, authMW, &auth.TokenPtr, cfg.TokenPath)

	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    64 * 1024,
	}

	logger.Info("server_starting",
		slog.String("addr", cfg.ListenAddr),
		slog.String("version", cfg.Version),
	)

	idle := make(chan struct{})
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		sig := <-sigCh
		logger.Info("server_shutdown_signal", slog.String("signal", sig.String()))
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			logger.Error("server_shutdown_error", slog.String("err", err.Error()))
		}
		close(idle)
	}()

	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("server_listen_error", slog.String("err", err.Error()))
		os.Exit(1)
	}
	<-idle
	logger.Info("server_stopped")
}

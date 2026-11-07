package main

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"time"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
)

type statusResponse struct {
	Service string `json:"service"`
	Status  string `json:"status"`
	Time    string `json:"time"`
}

type apiResponse struct {
	Service string `json:"service"`
	Status  string `json:"status"`
	Method  string `json:"method"`
	Path    string `json:"path"`
	Time    string `json:"time"`
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Server-Status", "200")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Server-Status", "200")
		_ = json.NewEncoder(w).Encode(statusResponse{
			Service: "xgcpx-control",
			Status:  "ready",
			Time:    time.Now().UTC().Format(time.RFC3339),
		})
	})
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Server-Status", "200")
		_ = json.NewEncoder(w).Encode(apiResponse{
			Service: "xgcpx-api",
			Status:  "ready",
			Method:  r.Method,
			Path:    r.URL.Path,
			Time:    time.Now().UTC().Format(time.RFC3339),
		})
	})
	server := &http.Server{
		Addr:              ":8081",
		Handler:           h2c.NewHandler(requestLogger(logger, mux), &http2.Server{}),
		ReadHeaderTimeout: 5 * time.Second,
	}
	logger.Info("control backend starting", "address", server.Addr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		logger.Error("control backend stopped", "error", err)
		os.Exit(1)
	}
}

func requestLogger(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		logger.Info("request", "method", r.Method, "path", r.URL.Path, "duration_ms", time.Since(start).Milliseconds())
	})
}

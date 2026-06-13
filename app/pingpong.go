package main

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/VictoriaMetrics/metrics"
	"github.com/golang/gddo/httputil/header"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	dto "github.com/prometheus/client_model/go"
	"github.com/prometheus/prom2json"
)

// Config holds the server configuration
type Config struct {
	Port            int
	PortTLS         int
	ServerKey       string
	ServerCert      string
	DisableTLS      bool
	InsecureAllowed bool
}

// MetricInfo represents a single metric's metadata and values
type MetricInfo struct {
	Name    string   `json:"name"`
	Help    string   `json:"help"`
	Type    string   `json:"type"`
	Metrics []Metric `json:"metrics,omitempty"`
}

type MetricsInfo []MetricInfo

// Metric represents a single metric data point
type Metric struct {
	Labels      map[string]string `json:"labels,omitempty"`
	TimestampMs string            `json:"timestamp_ms,omitempty"`
	Value       string            `json:"value"`
}

// MetricMeta holds metadata about a metric
type MetricMeta struct {
	Name   string
	Labels []string
}

// CustomMetricPrometheus wraps a Prometheus counter with its metadata
type CustomMetricPrometheus struct {
	meta MetricMeta
	obj  *prometheus.CounterVec
}

// CustomMetricVictoria wraps a VictoriaMetrics counter with its metadata
type CustomMetricVictoria struct {
	meta MetricMeta
	obj  *metrics.Counter
}

// MetricLineInfo holds formatted metric data
type MetricLineInfo struct {
	Name       string
	MetricExpo string
}

type MetricLinesInfo []*MetricLineInfo

const (
	defaultHTTPPort  = 8090
	defaultHTTPSPort = 8443
)

var (
	someLabels = []string{
		"path", "receiver", "webhook", "routing_key",
		"extra_slack_recipient", "extra_slack_recipient_god",
		"instance", "arg1", "arg2",
	}

	defaultLabelNames = []string{
		"path", "receiver", "routing_key",
		"extra_slack_recipient", "extra_slack_recipient_god",
		"instance",
	}

	// Global metrics registries
	metricsMapPrometheus = make(map[string]*CustomMetricPrometheus)
	metricsMapVictoria   = make(map[string]*CustomMetricVictoria)

	// Global counters
	pingCounterPrometheus = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name:        "ping_request_count",
			Help:        "No of request handled by Ping handler (to /ping)",
			ConstLabels: prometheus.Labels{"app": "pingpong"},
		},
		someLabels,
	)

	pingCounterVictoria = metrics.NewCounter(`ping_request_count{path="/tmp/cups_of_tea", receiver="slack-receiver-god"}`)

	// Logger
	logger = log.New(os.Stdout, "metrics-server: ", log.LstdFlags|log.Lshortfile)
)

// Server represents the metrics server
type Server struct {
	config   *Config
	mux      *http.ServeMux
	registry *prometheus.Registry
}

// NewServer creates a new metrics server instance
func NewServer(config *Config) *Server {
	mux := http.NewServeMux()
	registry := prometheus.NewRegistry()

	registry.MustRegister(
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		pingCounterPrometheus,
	)

	return &Server{
		config:   config,
		mux:      mux,
		registry: registry,
	}
}

// setupRoutes configures all HTTP routes
func (s *Server) setupRoutes() {
	s.mux.HandleFunc("/", s.rootHandler)
	s.mux.HandleFunc("/ping", s.pingHandler)
	s.mux.HandleFunc("/time", s.timeHandler)
	s.mux.HandleFunc("/echo", s.echoHandler)
	s.mux.HandleFunc("/create", s.createHandler)
	s.mux.HandleFunc("/update", s.updateHandler)
	s.mux.HandleFunc("/metrics", s.metricsHandler)
	s.mux.HandleFunc("/webhook", s.webhookHandler)
	s.mux.HandleFunc("/v2/enqueue", s.webhookHandler)
	s.mux.HandleFunc("/slack", s.webhookHandler)
	s.mux.HandleFunc("/pagerduty", s.webhookHandler)
	s.mux.HandleFunc("/logs", s.logsHandler)
	s.mux.HandleFunc("/runbooks/", s.runbookHandler)

	s.mux.Handle("/metrics.d", promhttp.HandlerFor(
		s.registry,
		promhttp.HandlerOpts{
			EnableOpenMetrics: true,
		}),
	)
}

// Handler implementations
func (s *Server) rootHandler(w http.ResponseWriter, r *http.Request) {
	logger.Println("rootHandler() called /")
	formatted, err := httputil.DumpRequest(r, false)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Write(formatted)
}

func (s *Server) pingHandler(w http.ResponseWriter, r *http.Request) {
	currentTime := time.Now()

	// Extract query parameters with defaults
	params := map[string]string{
		"path":                      r.URL.Query().Get("path"),
		"instance":                  r.URL.Query().Get("instance"),
		"receiver":                  r.URL.Query().Get("receiver"),
		"webhook":                   r.URL.Query().Get("webhook"),
		"routing_key":               r.URL.Query().Get("routing_key"),
		"extra_slack_recipient":     r.URL.Query().Get("extra_slack_recipient"),
		"extra_slack_recipient_god": r.URL.Query().Get("extra_slack_recipient_god"),
		"arg1":                      r.URL.Query().Get("arg1"),
		"arg2":                      r.URL.Query().Get("arg2"),
	}

	// Set defaults
	if params["path"] == "" {
		params["path"] = "/tmp/cups_of_tea"
	}
	if params["instance"] == "" {
		params["instance"] = "pingpong"
	}
	if params["receiver"] == "" {
		params["receiver"] = "default-receiver-god"
	}

	// Update metrics
	pingCounterPrometheus.WithLabelValues(
		params["path"], params["receiver"], params["webhook"],
		params["routing_key"], params["extra_slack_recipient"],
		params["extra_slack_recipient_god"], params["instance"],
		params["arg1"], params["arg2"],
	).Inc()
	pingCounterVictoria.Inc()

	logger.Printf("Ping request handled at %v", currentTime)

	// Format response
	result := fmt.Sprintf("PONG - %s\n", currentTime)
	fmt.Fprint(w, result)
}

func (s *Server) timeHandler(w http.ResponseWriter, r *http.Request) {
	logger.Println("timeHandler() called")
	tm := time.Now().Format(time.RFC1123)
	w.Write([]byte("The time is: " + tm + "\n"))
}

func (s *Server) metricsHandler(w http.ResponseWriter, r *http.Request) {
	logger.Println("metricsHandler() called")

	messages := make(chan string)
	go s.getMetrics(messages)

	data := <-messages
	fmt.Fprint(w, data)
}

func (s *Server) getMetrics(c chan string) {
	logger.Println("getMetrics() called")

	resp, err := http.Get(fmt.Sprintf("http://localhost:%d/metrics.d", s.config.Port))
	if err != nil {
		logger.Printf("Error getting metrics: %v", err)
		c <- ""
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		logger.Printf("Error reading metrics body: %v", err)
		c <- ""
		return
	}

	c <- string(body)
}

func (s *Server) createHandler(w http.ResponseWriter, r *http.Request) {
	//logger.Println("createHandler() called")

	if !s.requestIsAllowed(w, r) {
		return
	}

	contentType, _ := header.ParseValueAndParams(r.Header, "Content-Type")
	defer r.Body.Close()

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Error reading request body", http.StatusBadRequest)
		return
	}

	var decodedMetricInfo MetricsInfo
	var jsonText []byte

	switch contentType {
	case "application/x-www-form-urlencoded", "text/plain":
		parsedMetrics, jsonData := parseInputToMetrics(io.NopCloser(bytes.NewBuffer(body)))
		if parsedMetrics == nil {
			http.Error(w, "Error parsing metrics", http.StatusBadRequest)
			return
		}
		jsonText = jsonData
	default:
		jsonText = body
	}

	if err := json.NewDecoder(bytes.NewReader(jsonText)).Decode(&decodedMetricInfo); err != nil {
		http.Error(w, fmt.Sprintf("Error decoding metrics: %v", err), http.StatusBadRequest)
		return
	}

	// Create metrics
	for _, metric := range decodedMetricInfo {
		metricLines := s.createNewMetric(&metric)
		fmt.Fprintf(w, "created metric...\n")
		for _, line := range metricLines {
			fmt.Fprintf(w, "%s", line.MetricExpo)
		}
		fmt.Fprintf(w, "\n")
	}
}

func (s *Server) updateHandler(w http.ResponseWriter, r *http.Request) {
	logger.Println("updateHandler() called")

	if !s.requestIsAllowed(w, r) {
		return
	}

	contentType, _ := header.ParseValueAndParams(r.Header, "Content-Type")
	defer r.Body.Close()

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Error reading request body", http.StatusBadRequest)
		return
	}

	var decodedMetricInfo MetricsInfo
	var jsonText []byte

	switch contentType {
	case "application/x-www-form-urlencoded", "text/plain":
		parsedMetrics, jsonData := parseInputToMetrics(io.NopCloser(bytes.NewBuffer(body)))
		if parsedMetrics == nil {
			http.Error(w, "Error parsing metrics", http.StatusBadRequest)
			return
		}
		jsonText = jsonData
	default:
		jsonText = body
	}

	if err := json.NewDecoder(bytes.NewReader(jsonText)).Decode(&decodedMetricInfo); err != nil {
		http.Error(w, fmt.Sprintf("Error decoding metrics: %v", err), http.StatusBadRequest)
		return
	}

	// Update metrics
	for _, metric := range decodedMetricInfo {
		metricLines := s.updateMetric(&metric)
		for _, line := range metricLines {
			fmt.Fprintf(w, "%s", line.MetricExpo)
		}
	}
}

func (s *Server) webhookHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	contentType, _ := header.ParseValueAndParams(r.Header, "Content-Type")
	if contentType != "application/json" {
		http.Error(w, "Content-Type must be application/json", http.StatusUnsupportedMediaType)
		return
	}

	formatted, err := httputil.DumpRequest(r, true)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	parts := splitByEmptyNewline(string(formatted))
	headers := parts[0]
	body := parts[1]

	prettyBody, err := prettyJSON([]byte(body))
	if err != nil {
		logger.Printf("Error formatting JSON: %v", err)
	}

	logger.Printf("Webhook request:\nHeaders:\n%s\n\nBody:\n%s", headers, prettyBody)
}

func (s *Server) logsHandler(w http.ResponseWriter, r *http.Request) {
	cluster := r.URL.Query().Get("cluster")
	instance := r.URL.Query().Get("instance")

	label := cluster
	labelKey := "cluster"
	if label == "" {
		label = instance
		labelKey = "instance"
	}
	if label == "" {
		label = "unknown"
		labelKey = "cluster"
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Demo Logs - %s</title>
<style>
body{font-family:monospace;background:#0d1117;color:#c9d1d9;margin:0;padding:24px}
h1{color:#58a6ff;font-size:1.2rem;margin-bottom:8px}
.meta{color:#8b949e;font-size:.85rem;margin-bottom:20px}
.entry{padding:6px 0;border-bottom:1px solid #21262d;display:flex;gap:12px}
.ts{color:#3fb950;white-space:nowrap}
.lvl-error{color:#f85149;font-weight:bold}
.lvl-warn{color:#e3b341}
.lvl-info{color:#58a6ff}
.msg{flex:1}
.badge{background:#21262d;border-radius:4px;padding:2px 6px;font-size:.8rem}
</style>
</head>
<body>
<h1>Log viewer - %s=<span style="color:#e3b341">%s</span></h1>
<div class="meta">Demo log stream &mdash; alertstack &mdash; last 20 entries</div>
`, label, labelKey, label)

	now := time.Now()
	entries := []struct {
		offset int
		level  string
		msg    string
	}{
		{2, "INFO", "upstream connection established"},
		{7, "INFO", "request routed to backend"},
		{15, "INFO", "health check passed"},
		{28, "WARN", "upstream response latency elevated: 420ms"},
		{41, "INFO", "request routed to backend"},
		{55, "ERROR", "upstream 503 received"},
		{63, "ERROR", "upstream 503 received"},
		{71, "ERROR", "upstream 503 received"},
		{80, "WARN", "circuit breaker threshold approaching"},
		{92, "INFO", "request routed to backend"},
		{105, "INFO", "upstream connection established"},
		{118, "ERROR", "upstream 503 received"},
		{130, "WARN", "retrying upstream connection"},
		{142, "ERROR", "upstream 503 received: request rate dropped below threshold"},
		{158, "INFO", "alert fired: envoy_cluster_request_rate_low"},
		{170, "INFO", "alertmanager notified"},
		{182, "INFO", "slack notification sent to #alert-receiver"},
		{195, "INFO", "upstream connection re-established"},
		{210, "INFO", "request rate recovering"},
		{225, "INFO", "health check passed"},
	}

	for _, e := range entries {
		ts := now.Add(-time.Duration(e.offset) * time.Second).Format("2006-01-02 15:04:05")
		cls := "lvl-info"
		if e.level == "ERROR" {
			cls = "lvl-error"
		} else if e.level == "WARN" {
			cls = "lvl-warn"
		}
		fmt.Fprintf(w, `<div class="entry"><span class="ts">%s</span><span class="%s badge">%s</span><span class="msg">%s</span></div>`, ts, cls, e.level, e.msg)
	}

	fmt.Fprintf(w, `</body></html>`)
}

func (s *Server) runbookHandler(w http.ResponseWriter, r *http.Request) {
	slug := strings.TrimPrefix(r.URL.Path, "/runbooks/")
	if slug == "" {
		slug = "unknown"
	}

	title := strings.ReplaceAll(slug, "-", " ")
	title = strings.ToTitle(title[:1]) + title[1:]

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Runbook - %s</title>
<style>
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#0d1117;color:#c9d1d9;margin:0;padding:32px;max-width:860px}
h1{color:#58a6ff;font-size:1.6rem;margin-bottom:4px}
.slug{color:#8b949e;font-size:.9rem;margin-bottom:28px;font-family:monospace}
h2{color:#e6edf3;font-size:1.1rem;border-bottom:1px solid #21262d;padding-bottom:6px;margin-top:28px}
p{line-height:1.6;color:#c9d1d9}
code{background:#161b22;padding:2px 6px;border-radius:4px;font-family:monospace;color:#79c0ff}
ul{line-height:2}
.step{background:#161b22;border-left:3px solid #58a6ff;padding:12px 16px;margin:10px 0;border-radius:0 6px 6px 0}
.step strong{color:#e6edf3}
.warn{border-left-color:#e3b341}
.alert-box{background:#161b22;border:1px solid #f85149;border-radius:6px;padding:14px;margin:18px 0}
.alert-box .label{color:#f85149;font-size:.8rem;font-weight:bold;margin-bottom:4px}
</style>
</head>
<body>
<h1>Runbook: %s</h1>
<div class="slug">%s</div>

<div class="alert-box">
<div class="label">ALERT</div>
This is a demo runbook for alertstack. The content below is illustrative only.
</div>

<h2>Overview</h2>
<p>This runbook covers the <code>%s</code> alert. It fires when the request rate on an Envoy upstream cluster
drops below the configured threshold, indicating a possible upstream failure or traffic drain.</p>

<h2>Symptoms</h2>
<ul>
<li>Envoy <code>cluster_request_rate_low</code> alert is firing</li>
<li>Request rate on one or more upstream clusters near zero</li>
<li>Downstream services may be timing out or returning errors</li>
</ul>

<h2>Investigation steps</h2>
<div class="step"><strong>Step 1</strong> - Check the Grafana dashboard for the affected cluster.
Use the <code>var-cluster</code> URL parameter to filter to the specific cluster.</div>
<div class="step"><strong>Step 2</strong> - Review recent logs for upstream 503 / connection errors.</div>
<div class="step warn"><strong>Step 3</strong> - Check if a deployment or config change was recently applied to the affected backend.</div>
<div class="step"><strong>Step 4</strong> - Inspect Envoy admin interface: <code>/clusters</code> endpoint for health state.</div>
<div class="step"><strong>Step 5</strong> - If traffic drain is intentional (planned maintenance), silence the alert in Alertmanager.</div>

<h2>Escalation</h2>
<p>If the cluster does not recover within 10 minutes, escalate to the on-call SRE via PagerDuty.</p>

<h2>Resolution</h2>
<p>Once the upstream recovers, the alert will auto-resolve. Confirm in Grafana that the request rate
returns to baseline before closing the incident.</p>
</body></html>`, title, title, slug, slug)
}

func (s *Server) echoHandler(w http.ResponseWriter, r *http.Request) {
	logger.Println("echoHandler() called")

	formatted, err := httputil.DumpRequest(r, true)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Write(formatted)
	fmt.Fprintf(w, "The time is: %s\n", time.Now().Format(time.RFC1123))
}

// Helper methods
func (s *Server) requestIsAllowed(w http.ResponseWriter, r *http.Request) bool {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return false
	}

	if r.Header.Get("Content-Type") == "" {
		http.Error(w, "Content-Type header required", http.StatusBadRequest)
		return false
	}

	contentType, _ := header.ParseValueAndParams(r.Header, "Content-Type")
	allowedTypes := []string{"application/x-www-form-urlencoded", "application/json", "text/plain"}

	if !contains(allowedTypes, contentType) {
		http.Error(w, "Invalid Content-Type", http.StatusUnsupportedMediaType)
		return false
	}

	return true
}

func (s *Server) createNewMetric(f *MetricInfo) MetricLinesInfo {
	var result MetricLinesInfo

	if metricsMapPrometheus[f.Name] == nil {
		labelSet := make(map[string]struct{})
		for _, item := range f.Metrics {
			for k := range item.Labels {
				labelSet[k] = struct{}{}
			}
		}
		labelNames := make([]string, 0, len(labelSet))
		for k := range labelSet {
			labelNames = append(labelNames, k)
		}
		sort.Strings(labelNames)

		counter := prometheus.NewCounterVec(
			prometheus.CounterOpts{
				Name: f.Name,
				Help: fmt.Sprintf("Custom Metric for %s", f.Name),
			},
			labelNames,
		)

		if err := s.registry.Register(counter); err != nil {
			logger.Printf("Error registering metric: %v", err)
			return nil
		}

		metricsMapPrometheus[f.Name] = &CustomMetricPrometheus{
			meta: MetricMeta{Name: f.Name, Labels: labelNames},
			obj:  counter,
		}
	}

	metric := metricsMapPrometheus[f.Name]

	for _, item := range f.Metrics {
		value, err := strconv.ParseFloat(item.Value, 64)
		if err != nil {
			logger.Printf("Error parsing metric %s value: %v", f.Name, err)
			continue
		}

		paddedLabels := padLabels(item.Labels, metric.meta.Labels)
		counter, err := metric.obj.GetMetricWith(paddedLabels)
		if err != nil {
			logger.Printf("Error getting metric: %v", err)
			continue
		}

		counter.Add(value)

		metricLine := &MetricLineInfo{
			Name:       f.Name,
			MetricExpo: createMetricLine(f.Name, paddedLabels, fmt.Sprintf("%.0f", value)),
		}
		result = append(result, metricLine)
	}

	return result
}

func (s *Server) updateMetric(f *MetricInfo) MetricLinesInfo {
	var result MetricLinesInfo

	metric, exists := metricsMapPrometheus[f.Name]
	if !exists {
		logger.Printf("Metric %s not found", f.Name)
		return nil
	}

	//b, _ := json.MarshalIndent(metric, "", "  ")
	b, _ := json.Marshal(metric.meta)
	logger.Printf("updateMetric() %s meta=%s obj=%p", f.Name, b, metric.obj)

	for _, item := range f.Metrics {
		delta, err := strconv.ParseFloat(item.Value, 64)
		if err != nil || delta <= 0 {
			delta = 1
		}


		paddedLabels := padLabels(item.Labels, metric.meta.Labels)
		counter, err := metric.obj.GetMetricWith(paddedLabels)
		if err != nil {
			logger.Printf("Error getting metric: %v", err)
			continue
		}

		counter.Add(delta)

		value := getMetricValue(counter)
		logger.Printf("updateMetric() %s before: %.0f delta: %.0f after: %.0f", f.Name, value-delta, delta, value)
		metricLine := &MetricLineInfo{
			Name:       f.Name,
			MetricExpo: createMetricLine(f.Name, paddedLabels, fmt.Sprintf("%.0f", value)),
		}
		result = append(result, metricLine)
	}

	return result
}

// Start starts the HTTP and HTTPS servers
func (s *Server) Start() error {
	var wg sync.WaitGroup

	// Start HTTP server
	wg.Add(1)
	go func() {
		defer wg.Done()
		addr := fmt.Sprintf(":%d", s.config.Port)
		logger.Printf("Starting HTTP server on %s", addr)
		if err := http.ListenAndServe(addr, s.mux); err != nil {
			logger.Printf("HTTP server error: %v", err)
		}
	}()

	// Start HTTPS server if enabled
	if !s.config.DisableTLS {
		wg.Add(1)
		go func() {
			defer wg.Done()
			addr := fmt.Sprintf(":%d", s.config.PortTLS)
			logger.Printf("Starting HTTPS server on %s", addr)

			tlsConfig := &tls.Config{
				MinVersion: tls.VersionTLS12,
			}

			server := &http.Server{
				Addr:      addr,
				Handler:   s.mux,
				TLSConfig: tlsConfig,
			}

			if err := server.ListenAndServeTLS(s.config.ServerCert, s.config.ServerKey); err != nil {
				logger.Printf("HTTPS server error: %v", err)
			}
		}()
	}

	wg.Wait()
	return nil
}

func parseInputToMetrics(input io.ReadCloser) ([]*prom2json.Family, []byte) {
	if input == nil {
		logger.Println("parseInputToMetrics: input cannot be nil")
		return nil, nil
	}

	mfChan := make(chan *dto.MetricFamily, 1024)
	done := make(chan struct{}) // Add a done channel for coordination

	// Start parser goroutine
	go func() {
		//defer close(mfChan) // Only close once when parsing is done
		defer close(done) // Signal completion
		if err := prom2json.ParseReader(input, mfChan); err != nil {
			logger.Printf("Error parsing metrics: %v", err)
		}
	}()

	result := []*prom2json.Family{}
	for mf := range mfChan {
		result = append(result, prom2json.NewFamily(mf))
	}

	<-done // Wait for parsing to complete

	jsonText, err := json.Marshal(result)
	if err != nil {
		logger.Printf("Error marshaling metrics: %v", err)
		return nil, nil
	}

	return result, jsonText
}

// Helper functions
func parseInputToMetricsDDD(input io.ReadCloser) ([]*prom2json.Family, []byte) {
	if input == nil {
		logger.Println("parseInputToMetrics: input cannot be nil")
		return nil, nil
	}

	mfChan := make(chan *dto.MetricFamily, 1024)

	go func() {
		if err := prom2json.ParseReader(input, mfChan); err != nil {
			logger.Printf("Error parsing metrics: %v", err)
		}
		close(mfChan)
	}()

	result := []*prom2json.Family{}
	for mf := range mfChan {
		result = append(result, prom2json.NewFamily(mf))
	}

	jsonText, err := json.Marshal(result)
	if err != nil {
		logger.Printf("Error marshaling metrics: %v", err)
		return nil, nil
	}

	return result, jsonText
}

func createMetricLine(name string, labels map[string]string, value string) string {
	var pairs []string
	for k, v := range labels {
		pairs = append(pairs, fmt.Sprintf("%s=%q", k, v))
	}
	sort.Strings(pairs)

	if value != "" {
		return fmt.Sprintf("%s{%s} %s\n", name, strings.Join(pairs, ","), value)
	}
	return fmt.Sprintf("%s{%s}\n", name, strings.Join(pairs, ","))
}

func getMetricValue(collector prometheus.Collector) float64 {
	var value float64

	collect(collector, func(m dto.Metric) {
		if h := m.GetHistogram(); h != nil {
			value += float64(h.GetSampleCount())
		} else {
			value += m.GetCounter().GetValue()
		}
	})

	return value
}

func collect(collector prometheus.Collector, callback func(dto.Metric)) {
	ch := make(chan prometheus.Metric)
	go func() {
		collector.Collect(ch)
		close(ch)
	}()

	for metric := range ch {
		var m dto.Metric
		if err := metric.Write(&m); err != nil {
			logger.Printf("Error writing metric: %v", err)
			continue
		}
		callback(m)
	}
}

func splitByEmptyNewline(input string) []string {
	normalized := regexp.MustCompile("\n").ReplaceAllString(input, "\n")
	return regexp.MustCompile(`\n\s*\n`).Split(normalized, -1)
}

func prettyJSON(data []byte) (string, error) {
	var buf bytes.Buffer
	if err := json.Indent(&buf, data, "", "    "); err != nil {
		return "", err
	}
	return buf.String(), nil
}

func padLabels(labels map[string]string, schema []string) map[string]string {
	result := make(map[string]string, len(schema))
	for _, k := range schema {
		result[k] = labels[k]
	}
	return result
}

func getKeys(m map[string]string) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}

func main() {
	// Parse command line flags
	config := &Config{}

	flag.IntVar(&config.Port, "port", defaultHTTPPort, "HTTP port to listen on")
	flag.IntVar(&config.PortTLS, "port-tls", defaultHTTPSPort, "HTTPS port to listen on")
	flag.StringVar(&config.ServerKey, "key", "certs/server.key", "TLS key file")
	flag.StringVar(&config.ServerCert, "cert", "certs/server.crt", "TLS certificate file")
	flag.BoolVar(&config.DisableTLS, "disable-tls", false, "Disable HTTPS server")
	flag.BoolVar(&config.InsecureAllowed, "allow-insecure", true, "Allow self-signed certificates")

	flag.Parse()

	// Create and start server
	server := NewServer(config)
	server.setupRoutes()

	logger.Printf("Starting metrics server with configuration: %+v", config)

	if err := server.Start(); err != nil {
		logger.Fatalf("Server failed to start: %v", err)
	}
}

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
		"extra_slack_recipient", "extra_slack_recipient_sre",
		"instance", "arg1", "arg2",
	}

	defaultLabelNames = []string{
		"path", "receiver", "routing_key",
		"extra_slack_recipient", "extra_slack_recipient_sre",
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

	pingCounterVictoria = metrics.NewCounter(`ping_request_count{path="/tmp/kafka_upload", receiver="slack-receiver-sre"}`)

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
		"extra_slack_recipient_sre": r.URL.Query().Get("extra_slack_recipient_sre"),
		"arg1":                      r.URL.Query().Get("arg1"),
		"arg2":                      r.URL.Query().Get("arg2"),
	}

	// Set defaults
	if params["path"] == "" {
		params["path"] = "/tmp/kafka_upload"
	}
	if params["instance"] == "" {
		params["instance"] = "pingpong"
	}
	if params["receiver"] == "" {
		params["receiver"] = "default-receiver-sre"
	}

	// Update metrics
	pingCounterPrometheus.WithLabelValues(
		params["path"], params["receiver"], params["webhook"],
		params["routing_key"], params["extra_slack_recipient"],
		params["extra_slack_recipient_sre"], params["instance"],
		params["arg1"], params["arg2"],
	).Inc()
	pingCounterVictoria.Inc()

	logger.Printf("Ping request handled at %v", currentTime)

	// Format response
	result := fmt.Sprintf("PONG - %s\n", currentTime)
	fmt.Fprintf(w, result)
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
	fmt.Fprintf(w, data)
}

func (s *Server) getMetrics(c chan string) {
	logger.Println("getMetrics() called")

	resp, err := http.Get("http://localhost:8090/metrics.d")
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

	if contentType == "application/x-www-form-urlencoded" {
		parsedMetrics, jsonData := parseInputToMetrics(io.NopCloser(bytes.NewBuffer(body)))
		if parsedMetrics == nil {
			http.Error(w, "Error parsing metrics", http.StatusBadRequest)
			return
		}
		jsonText = jsonData
	} else {
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

	if contentType == "application/x-www-form-urlencoded" {
		parsedMetrics, jsonData := parseInputToMetrics(io.NopCloser(bytes.NewBuffer(body)))
		if parsedMetrics == nil {
			http.Error(w, "Error parsing metrics", http.StatusBadRequest)
			return
		}
		jsonText = jsonData
	} else {
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
	allowedTypes := []string{"application/x-www-form-urlencoded", "application/json"}

	if !contains(allowedTypes, contentType) {
		http.Error(w, "Invalid Content-Type", http.StatusUnsupportedMediaType)
		return false
	}

	return true
}

func (s *Server) createNewMetric(f *MetricInfo) MetricLinesInfo {
	var result MetricLinesInfo

	for _, item := range f.Metrics {
		value, err := strconv.ParseFloat(item.Value, 64)
		if err != nil {
			logger.Printf("Error parsing metric value: %v", err)
			continue
		}

		labelNames := getKeys(item.Labels)

		if metricsMapPrometheus[f.Name] == nil {
			counter := prometheus.NewCounterVec(
				prometheus.CounterOpts{
					Name: f.Name,
					Help: fmt.Sprintf("Custom Metric for %s", f.Name),
				},
				labelNames,
			)

			if err := s.registry.Register(counter); err != nil {
				logger.Printf("Error registering metric: %v", err)
				continue
			}

			metricsMapPrometheus[f.Name] = &CustomMetricPrometheus{
				meta: MetricMeta{Name: f.Name, Labels: labelNames},
				obj:  counter,
			}
		}

		metric := metricsMapPrometheus[f.Name]
		counter, err := metric.obj.GetMetricWith(item.Labels)
		if err != nil {
			logger.Printf("Error getting metric: %v", err)
			continue
		}

		counter.Add(value)

		// Create the metric line for response
		metricLine := &MetricLineInfo{
			Name:       f.Name,
			MetricExpo: createMetricLine(f.Name, item.Labels, fmt.Sprintf("%.0f", value)),
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

	for _, item := range f.Metrics {
		counter, err := metric.obj.GetMetricWith(item.Labels)
		if err != nil {
			logger.Printf("Error getting metric: %v", err)
			continue
		}

		counter.Inc()

		value := getMetricValue(counter)

		metricLine := &MetricLineInfo{
			Name:       f.Name,
			MetricExpo: createMetricLine(f.Name, item.Labels, fmt.Sprintf("%.0f", value)),
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

```go

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

// https://pkg.go.dev/github.com/prometheus/prom2json#section-readme
// https://docs.google.com/document/d/1ZjyKiKxZV83VI9ZKAXRGKaUKK2BIWCT7oiGBKDBpjEY/edit#heading=h.wnviarbnyxcj
// Prometheus Client Data Exposition Format

var someLabels []string = []string{"path", "receiver", "webhook", "routing_key", "extra_slack_recipient", "extra_slack_recipient_test", "instance", "arg1", "arg2"}
var defaultLabelNames []string = []string{"path", "receiver", "routing_key", "extra_slack_recipient", "extra_slack_recipient_test", "instance"}

// this input might be an io buffer or a req/resp body - r.Body
func parseInputToMetrics(input io.ReadCloser) ([]*prom2json.Family, []byte) {
	if input == nil {
		fmt.Fprintln(os.Stderr, "parseInputToMetrics: input cannot be nil")
		return nil, []byte{}
	}

	var err error

	// channel for the results of the conversions
	mfChan := make(chan *dto.MetricFamily, 1024)

	// Missing input means we are reading from an URL.
	if input != nil {
		go func() {
			if err := prom2json.ParseReader(input, mfChan); err != nil {
				res := fmt.Sprintf("error parsing input into MetricFamily type - %s\n", err.Error())
				fmt.Fprintln(os.Stderr, res)
			}
		}()
	}

	// all our individual metrics go here
	result := []*prom2json.Family{}

	for mf := range mfChan {
		result = append(result, prom2json.NewFamily(mf))
	}

	jsonText, err := json.Marshal(result)
	if err != nil {
		res := fmt.Sprintf("error encoding metrics into JSON - %s\n", err.Error())
		fmt.Fprintln(os.Stderr, res)
		return nil, []byte{}
	}
	return result, jsonText
}

var pingCounterPrometheus = prometheus.NewCounterVec(
	prometheus.CounterOpts{
		Name:        "ping_request_count",
		Help:        "No of request handled by Ping handler (to /ping)",
		ConstLabels: prometheus.Labels{"app": "pingpong"},
	},
	someLabels,
)

// we define a parallel metric in victoria metrics just because it's easier to
// get the current count out of!
var pingCounterVictoriaMetrics = metrics.NewCounter(`ping_request_count{path="/tmp/kafka_upload", receiver="slack-receiver-ico"}`)

// get the current count
func pingCounterVictoriaMetricsTotal() uint64 {
	return pingCounterVictoriaMetrics.Get()
}

// make any string that is json look pretty for display. this is for when we are
// dumping out webhook json payload POST requests from alertmanager
func PrettyString(str string) (string, error) {
	var prettyJSON bytes.Buffer
	if err := json.Indent(&prettyJSON, []byte(str), "", "    "); err != nil {
		return "", err
	}
	return prettyJSON.String(), nil
}

// split the POST request into two strings
// string 1 = the request headers
// string 2 = the request body
func splitByEmptyNewline(str string) []string {
	strNormalized := regexp.
		MustCompile("\n").
		ReplaceAllString(str, "\n")

	return regexp.
		MustCompile(`\n\s*\n`).
		Split(strNormalized, -1)
}

// remove any duplicates from a list of strings, then sort it.
func removeDuplicateStr(strSlice []string) []string {
	allKeys := make(map[string]bool)
	list := []string{}
	for _, item := range strSlice {
		if _, value := allKeys[item]; !value {
			allKeys[item] = true
			list = append(list, item)
		}
	}
	sort.Strings(list)
	return list
}

// get the keys of a map
func Keys[K comparable, V any](m map[K]V) []K {
	r := make([]K, 0, len(m))
	for k := range m {
		r = append(r, k)
	}
	return r
}

// does the list contain a certain string
func stringInSlice(a string, list []string) bool {
	for _, b := range list {
		if b == a {
			return true
		}
	}
	return false
}

// creates one or more lines that represent the metric in Prometheus Client Data Exposition
// Format - for example `metric_name{[name="value",...]}`
func createMetricLine(name string, labelPairs map[string]string, value ...string) string {
	var labelPairsEscaped []string
	allLabels := removeDuplicateStr(Keys(labelPairs))
	for _, labelName := range allLabels {

		labelValue := labelPairs[labelName]
		kv := fmt.Sprintf("%s=\"%s\"", labelName, labelValue)
		labelPairsEscaped = append(labelPairsEscaped, kv)
	}
	if len(value) > 0 {
		return fmt.Sprintf("%s{%s} %s\n", name, strings.Join(labelPairsEscaped, ", "), value[0])
	}
	return fmt.Sprintf("%s{%s}\n", name, strings.Join(labelPairsEscaped, ", "))
}

// the /ping endpoint which just increments the counters and
// returns PONG
func ping(w http.ResponseWriter, req *http.Request) {
	currentTime := time.Now()

	path := req.URL.Query().Get("path")
	if path == "" {
		path = "/tmp/kafka_upload"
	}

	instance := req.URL.Query().Get("instance")
	if instance == "" {
		instance = "pingpong"
	}

	arg1 := req.URL.Query().Get("arg1")
	arg2 := req.URL.Query().Get("arg2")

	receiver := req.URL.Query().Get("receiver")
	if receiver == "" {
		receiver = "default-receiver-ico"
	}

	webhook := req.URL.Query().Get("webhook")
	if webhook == "" {
		webhook = ""
	}

	extra_slack_recipient := req.URL.Query().Get("extra_slack_recipient")
	if extra_slack_recipient == "" {
		extra_slack_recipient = ""
	}

	extra_slack_recipient_test := req.URL.Query().Get("extra_slack_recipient_test")
	if extra_slack_recipient_test == "" {
		extra_slack_recipient_test = ""
	}

	routing_key := req.URL.Query().Get("routing_key")
	if routing_key == "" {
		routing_key = ""
	}

	cm := metricsMapP["my_metric"]
	if cm != nil {
		m := cm.obj
		m.WithLabelValues(path, receiver)
	}

	pingCounterPrometheus.WithLabelValues(path, receiver, webhook, routing_key, extra_slack_recipient, extra_slack_recipient_test, instance, arg1, arg2).Inc()
	pingCounterVictoriaMetrics.Inc()

	fmt.Println("The time is", currentTime)

	res := fmt.Sprintf("ping_request_count{path=\"%s\",receiver=\"%s\",webhook=\"%s\", routing_key=\"%s\", extra_slack_recipient=\"%s\", extra_slack_recipient_test=\"%s\", instance=\"%s\", arg1=\"%s\", arg2=\"%s\"} %d", path, receiver, webhook, routing_key, extra_slack_recipient, extra_slack_recipient_test, instance, arg1, arg2, pingCounterVictoriaMetricsTotal())
	fmt.Println(res)

	result := "PONG - " + currentTime.String() + "\n"
	fmt.Fprintf(w, result)
}

// a function wrapper type effort so we can log to requests from prometheus to
// our /metrics endpoint when it scrapes us ( http://127.0.0.1:8090/metrics )
func GetMetrics(c chan string) {
	fmt.Println("GetMetrics()\n")

	// internally call the actual metrics stuff
	//	resp, err := http.Get("https://localhost:8443/metrics.d")
	resp, err := http.Get("http://localhost:8090/metrics.d")
	if err != nil {
		panic(err)
	} else {
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		// send back to the channel
		c <- string(body)
	}
}

// just send the time to caller - just to see if still alive
func timeHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Println("timeHandler()\n")
	tm := time.Now().Format(time.RFC1123)
	w.Write([]byte("The time is: " + tm + "\n"))
}

// print out a bit of logging about the /metrics call and then return it
// to the caller (prometheus for example)
func metricsHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Println("metricsHandler()\n")
	currentTime := time.Now()

	// create a channel for the internal /metrics to use
	messages := make(chan string)

	// get the metrics as a goroutine
	go GetMetrics(messages)

	// the metrics result from the go routine
	data := <-messages

	// just a log to tell us that prometheus had scraped us
	fmt.Println("/metrics called - " + currentTime.String() + "\n")

	// send back the metrics to the caller (prometheus)
	fmt.Fprintf(w, data)
}

// ensure we only allow a POST request and a certain set of Content-Types
func requestIsAllowed(w http.ResponseWriter, r *http.Request) bool {
	if r.Method != "POST" {
		http.Error(w, "expected a POST request", http.StatusBadRequest)
		return false
	}

	allowedContentTypes := []string{"application/x-www-form-urlencoded", "application/json"}

	if r.Header.Get("Content-Type") == "" {
		http.Error(w, "expected a Content-Type in POST request", http.StatusBadRequest)
		return false
	}

	contentType, _ := header.ParseValueAndParams(r.Header, "Content-Type")

	if !stringInSlice(contentType, allowedContentTypes) {
		http.Error(w, "unexpected Content-Type in POST request", http.StatusBadRequest)
		return false
	}

	formattedHeaders, err := httputil.DumpRequest(r, false)
	if err != nil {
		http.Error(w, "unexpected error dumping headers", http.StatusBadRequest)
		return false
	}
	// dump the request headers
	fmt.Fprintln(os.Stderr, string(formattedHeaders))
	return true
}

type Metric struct {
	Labels      map[string]string `json:"labels,omitempty"`
	TimestampMs string            `json:"timestamp_ms,omitempty"`
	Value       string            `json:"value"`
}

type MetricInfo struct {
	//Time    time.Time
	Name    string   `json:"name"`
	Help    string   `json:"help"`
	Type    string   `json:"type"`
	Metrics []Metric `json:"metrics,omitempty"` // Either metric or summary.
}

type MetricsInfo []MetricInfo

type MetricLineInfo struct {
	Name       string
	MetricExpo string
}

type MetricLinesInfo []*MetricLineInfo

type MetricMeta struct {
	Name   string
	Labels []string
}

type pcustom_metrics struct {
	meta MetricMeta
	obj  *prometheus.CounterVec
}

type vcustom_metrics struct {
	meta MetricMeta
	obj  *metrics.Counter
}

var metricsMapP = make(map[string]*pcustom_metrics)
var metricsMapV = make(map[string]*vcustom_metrics)

// wrap up some data and give it io methods
func getNio(data []byte) io.ReadCloser {
	return io.NopCloser(bytes.NewBuffer(data))
}

// handler for metrics creation request to /create
func createHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(os.Stderr, "createHandler() /create\n")
	if !requestIsAllowed(w, r) {
		return
	}

	contentType, _ := header.ParseValueAndParams(r.Header, "Content-Type")
	defer r.Body.Close()

	// body will either be Prometheus Client Data Exposition Format `metric_name{[name="value",...]}`
	// representing 1 or more metrics, or
	// a json object representing 1 or more metrics
	body, _ := io.ReadAll(r.Body)

	// body now contains the req POST Body. Each time we need to use it again later we need it wrapped
	// in an io object.
	var nio = getNio(body)
	var prettified string
	var jsonText []byte

	var parsedMetricFamilies []*prom2json.Family
	var decodedMetricInfo MetricsInfo

	if contentType == "application/x-www-form-urlencoded" {
		// turn the request body into a MetricsFamily and a json version of same
		parsedMetricFamilies, jsonText = parseInputToMetrics(nio)
		if parsedMetricFamilies == nil {
			http.Error(w, "error parsing the input to valid metric(s)", http.StatusBadRequest)
			return
		}
		// wrap the jsonText in a new nio IO object again so our json.NewDecoder can use it later
		nio = getNio([]byte(jsonText))
	} else if contentType == "application/json" {
		jsonText = body
	}

	// this is a sanity check that the metrics structure was ok
	err := json.NewDecoder(nio).Decode(&decodedMetricInfo)
	if err != nil {
		res := fmt.Sprintf("error parsing metrics into JSON from input stream - %s\n", err.Error())
		fmt.Fprintln(os.Stderr, res)
		http.Error(w, res, http.StatusBadRequest)
		return
	}

	// get a pretty print/indented version of the json
	prettified, err = PrettyString(string(jsonText))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	} else {
		fmt.Fprintf(os.Stderr, "%s\n", prettified)
	}

	// create the metrics...
	for _, f := range decodedMetricInfo {
		// create the actual metric objects that we will use later
		metricLinesInfo := createNewMetric(&f, jsonText)

		// send back the metric lines to the caller
		for _, li := range metricLinesInfo {
			w.Write([]byte(li.MetricExpo))
		}
	}
}

func updateHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(os.Stderr, "updateHandler()\n")
	if !requestIsAllowed(w, r) {
		return
	}

	contentType, _ := header.ParseValueAndParams(r.Header, "Content-Type")
	defer r.Body.Close()

	// body will either be Prometheus Client Data Exposition Format `metric_name{[name="value",...]}`
	// representing 1 or more metrics, or
	// a json object representing 1 or more metrics
	body, _ := io.ReadAll(r.Body)

	// body now contains the req POST Body. Each time we need to use it again later we need it wrapped
	// in an io object.
	var nio io.ReadCloser = io.NopCloser(bytes.NewBuffer(body))
	var prettified string
	var jsonText []byte

	var parsedMetricFamilies []*prom2json.Family
	var decodedMetricInfo MetricsInfo

	if contentType == "application/x-www-form-urlencoded" {
		// turn the request body into a MetricsFamily and a json version of same
		parsedMetricFamilies, jsonText = parseInputToMetrics(nio)
		if parsedMetricFamilies == nil {
			http.Error(w, "error parsing the input to valid metric(s)", http.StatusBadRequest)
			return
		}
		// wrap the jsonText in a new nio IO object again so our json.NewDecoder can use it later
		nio = getNio([]byte(jsonText))
	} else if contentType == "application/json" {
		jsonText = body
	}

	// this is a sanity check that the metrics structure was ok
	err := json.NewDecoder(nio).Decode(&decodedMetricInfo)
	if err != nil {
		res := fmt.Sprintf("error parsing metrics into JSON from input stream - %s\n", err.Error())
		fmt.Fprintln(os.Stderr, res)
		http.Error(w, res, http.StatusBadRequest)
		return
	}

	// get a pretty print/indented version of the json
	prettified, err = PrettyString(string(jsonText))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	} else {
		fmt.Fprintf(os.Stderr, "%s", prettified)
	}

	for _, f := range decodedMetricInfo {

		// create the actual metric objects that we will use later
		metricLinesInfo := updateMetric(&f, jsonText)

		// send back the metric lines to the caller
		for _, li := range metricLinesInfo {
			w.Write([]byte(li.MetricExpo))
		}

	}

}

func echoHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Println("echoHandler()    called  /echo")
	if r.Method == "POST" && r.Header.Get("Content-Type") != "" {
		contentType, _ := header.ParseValueAndParams(r.Header, "Content-Type")
		rr := r.Clone(r.Context())
		defer rr.Body.Close()
		fmt.Println(contentType)
		body, _ := io.ReadAll(r.Body)
		r.Body = io.NopCloser(bytes.NewBuffer(body))

		if contentType == "application/x-www-form-urlencoded" {
			// example body - 'metric_name{label="label_contentType"} 77'
			msg := "Content-Type header is application/x-www-form-urlencoded"
			fmt.Println(string(msg))
		}

		justTheBody, _ := PrettyString(string(body))
		fmt.Println(justTheBody)

		if contentType != "application/json" {
			msg := "Content-Type header is not application/json"
			fmt.Println(string(msg))
		} else {
			var formatted, err = httputil.DumpRequest(r, true)
			if err != nil {
				fmt.Fprint(w, err)
			}

			result := splitByEmptyNewline(string(formatted))

			var justTheHeaders = result[0]
			var justTheBody = result[1]

			justTheBody, _ = PrettyString(string(justTheBody))
			fmt.Println(justTheHeaders)
			fmt.Println()
			fmt.Println(justTheBody)
		}
	} else {
		var formatted, err = httputil.DumpRequest(r, true)
		if err != nil {
			fmt.Fprint(w, err)
		}
		fmt.Println(string(formatted))
		w.Write(formatted)
	}
	tm := time.Now().Format(time.RFC1123)
	w.Write([]byte("The time is: " + tm + "\n"))
}

// GetMetricValue returns the sum of the Counter metrics associated with the Collector
// e.g. the metric for a non-vector, or the sum of the metrics for vector labels.
// If the metric is a Histogram then number of samples is used.
func GetMetricValue(col prometheus.Collector) float64 {
	var total float64
	collect(col, func(m dto.Metric) {
		if h := m.GetHistogram(); h != nil {
			total += float64(h.GetSampleCount())
		} else {
			total += m.GetCounter().GetValue()
		}
	})
	return total
}

// collect calls the function for each metric associated with the Collector
func collect(col prometheus.Collector, do func(dto.Metric)) {
	c := make(chan prometheus.Metric)
	go func(c chan prometheus.Metric) {
		col.Collect(c)
		close(c)
	}(c)
	for x := range c { // eg range across distinct label vector values
		m := dto.Metric{}
		_ = x.Write(&m)
		do(m)
	}
}

func createNewMetric(f *MetricInfo, jsonText []byte) MetricLinesInfo {
	fmt.Fprintf(os.Stderr, "\ncreateNewMetric()\n")

	name := f.Name
	var metricLinesInfo MetricLinesInfo
	for _, item := range f.Metrics {

		labelPairs := item.Labels
		metricValue := item.Value

		metricValueFloat64, err := strconv.ParseFloat(metricValue, 64)

		if err != nil {
			fmt.Fprintf(os.Stderr, "failed to get metric value as %s as float64 for %s with error: %s - skipping", metricValue, name, err.Error())
			continue
		}

		var labelNamesOnly []string = Keys(labelPairs)
		for _, labelName := range labelNamesOnly {
			labelNamesOnly = append(labelNamesOnly, labelName)
		}
		labelNamesOnly = removeDuplicateStr(labelNamesOnly)

		if metricsMapP[name] == nil {
			fmt.Fprintf(os.Stdout, "%s was not already registered with metricsMapP\n", name)

			pMetricMeta := MetricMeta{
				Name:   name,
				Labels: labelNamesOnly,
			}

			cm := &pcustom_metrics{
				meta: pMetricMeta,
				obj: prometheus.NewCounterVec(
					prometheus.CounterOpts{
						Name:        pMetricMeta.Name,
						Help:        fmt.Sprintf("Custom Metric for %s created by /create", name),
						ConstLabels: prometheus.Labels{},
					},
					pMetricMeta.Labels,
				),
			}

			// try to register the counter
			if err := prometheus.Register(cm.obj); err == nil {
				fmt.Fprintf(os.Stderr, "successfully registered %s\n", name)
				metricsMapP[name] = cm
			} else {
				fmt.Fprintf(os.Stderr, "failed to register %s with error: %s - trying to re-register\n", name, err.Error())
				if prometheus.Unregister(cm.obj) {
					if metricsMapP[name] != nil {
						delete(metricsMapP, name)
					}
					if err := prometheus.Register(cm.obj); err != nil {
						fmt.Fprintf(os.Stderr, "failed to register %s with error: %s - skipping", name, err.Error())
						continue
					} else {
						fmt.Fprintf(os.Stderr, "successfully registered %s\n", name)
						metricsMapP[name] = cm
					}
				} else {
					fmt.Fprintf(os.Stderr, "failed to unregister %s - skipping\n", name)
					continue
				}
			}

			// get the counter object we created above
			cm = metricsMapP[name]
			pobj, err := cm.obj.GetMetricWith(labelPairs)
			if err != nil {
				fmt.Fprintf(os.Stderr, "failed to GetMetricWith for %s with error: %s - skipping", name, err.Error())
				continue
			}

			pobj.Add(metricValueFloat64)
			registry.MustRegister(
				cm.obj,
			)

		} else {
			fmt.Fprintf(os.Stdout, "%s was already registered with metricsMapP - %v\n", name, metricsMapP[name])
		}

		cm := metricsMapP[name]

		// get the counter object we created above
		pobj, err := cm.obj.GetMetricWith(labelPairs)
		if err != nil {
			fmt.Fprintf(os.Stderr, "failed to GetMetricWith for %s with error: %s - skipping", name, err.Error())
			continue
		}
		// get the current value and convert it to an int string for display
		metricValue = fmt.Sprintf("%.0f", GetMetricValue(pobj))

		// create the Prometheus Data Exposition Format version of the metric
		metricLine := createMetricLine(name, labelPairs, metricValue)

		// will hold the metricLine and name for reporting back to user
		metricLineInfo := new(MetricLineInfo)

		metricLineInfo.Name = name
		metricLineInfo.MetricExpo = metricLine

		// add it to the list - we may have more than one
		metricLinesInfo = append(metricLinesInfo, metricLineInfo)
	}
	return metricLinesInfo
}

func updateMetric(f *MetricInfo, jsonText []byte) MetricLinesInfo {
	fmt.Fprintf(os.Stderr, "\nupdateMetric()\n")
	name := f.Name
	var metricLinesInfo MetricLinesInfo
	for _, item := range f.Metrics {

		if metricsMapP[name] == nil {
			fmt.Fprintf(os.Stderr, "%s was  not found - ensure it was created\n", name)
			continue
		}

		labelPairs := item.Labels

		var labelNamesOnly []string = Keys(labelPairs)
		for _, labelName := range labelNamesOnly {
			labelNamesOnly = append(labelNamesOnly, labelName)
		}
		labelNamesOnly = removeDuplicateStr(labelNamesOnly)

		cm := metricsMapP[name]

		// get the counter object we created above
		pobj, err := cm.obj.GetMetricWith(labelPairs)
		if err != nil {
			fmt.Fprintf(os.Stderr, "failed to GetMetricWith for %s with error: %s - skipping", name, err.Error())
			continue
		}
		pobj.Inc()

		// get the current value and convert it to an int string for display
		metricValue := fmt.Sprintf("%.0f", GetMetricValue(pobj))

		// create the Prometheus Data Exposition Format version of the metric
		metricLine := createMetricLine(name, labelPairs, metricValue)

		// will hold the metricLine and name for reporting back to user
		metricLineInfo := new(MetricLineInfo)

		metricLineInfo.Name = name
		metricLineInfo.MetricExpo = metricLine

		// add it to the list - we may have more than one
		metricLinesInfo = append(metricLinesInfo, metricLineInfo)
	}
	return metricLinesInfo
}

// just send the time to caller - just to see if still alive
func rootHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Println("root()    called  /")
	var formatted, err = httputil.DumpRequest(r, false)
	if err != nil {
		fmt.Fprint(w, err)
	}
	w.Write([]byte(formatted))
}

// this is the main handler to respond to the /webhook /pagerduty and /slack pretend
// POST requests from alertmanager
// the point of this being we can see exactly what the alertmanager has done with
// the alerts and the templating substitution etc
func webhookHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == "POST" && r.Header.Get("Content-Type") != "" {
		contentType, _ := header.ParseValueAndParams(r.Header, "Content-Type")
		if contentType != "application/json" {
			msg := "Content-Type header is not application/json - "
			fmt.Println(string(msg))
			http.Error(w, msg, http.StatusUnsupportedMediaType)
			return
		} else {

			var formatted, err = httputil.DumpRequest(r, true)
			if err != nil {
				fmt.Fprint(w, err)
			}

			result := splitByEmptyNewline(string(formatted))

			var justTheHeaders = result[0]
			var justTheBody = result[1]

			justTheBody, _ = PrettyString(string(justTheBody))
			fmt.Println(justTheHeaders)
			fmt.Println()
			fmt.Println(justTheBody)
		}
	} else {
		var formatted, err = httputil.DumpRequest(r, true)
		if err != nil {
			fmt.Fprint(w, err)
		}
		fmt.Println(string(formatted))
		w.Write(formatted)
	}
}

func setup() (*http.ServeMux, *prometheus.Registry) {
	// Create non-global registry.
	mux := http.NewServeMux()
	registry := prometheus.NewRegistry()

	// Add our custom counter, go runtime metrics and process collectors.
	registry.MustRegister(
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		pingCounterPrometheus,
	)

	// expose our test endpoints
	// 1. the simple /ping
	// 2. the current time /time
	// 3. a wrapper for the internal /metrics so we can log the requests
	mux.HandleFunc("/", rootHandler)

	mux.HandleFunc("/ping", ping)
	mux.HandleFunc("/time", timeHandler)
	mux.HandleFunc("/echo", echoHandler)
	mux.HandleFunc("/create", createHandler)
	mux.HandleFunc("/update", updateHandler)
	mux.HandleFunc("/metrics", metricsHandler)

	mux.HandleFunc("/webhook", webhookHandler)
	mux.HandleFunc("/v2/enqueue", webhookHandler)
	mux.HandleFunc("/slack", webhookHandler)
	mux.HandleFunc("/pagerduty", webhookHandler)

	mux.Handle(
		"/metrics.d", promhttp.HandlerFor(
			registry,
			promhttp.HandlerOpts{
				EnableOpenMetrics: true,
			}),
	)

	return mux, registry
}

var buf bytes.Buffer
var portFlag int
var portFlagTLS int
var help = flag.Bool("help", false, "Show help")
var disableTLS = flag.Bool("disable-tls", false, "Disable the additional TLS listener which is listening to PORT_TLS by default (PORT_TLS=8443)")

var serverKey = flag.String("key", "server.key", "client certificate's key file")
var serverCert = flag.String("cert", "server.crt", "client certificate file")
var enforceServerCertCheck = flag.Bool("disable-insecure", false, "Disallow self signed certificates. Allowed by default. Insecure, testing use only.")

var logger = log.New(&buf, "logger: ", log.Ldate|log.Ltime|log.Lshortfile)

var mux *http.ServeMux
var registry *prometheus.Registry

// WaitGroup is used to wait for the program to finish goroutines.
var wg sync.WaitGroup

func makeTransport(certificate string, key string, skipServerCertCheck bool) (*http.Transport, error) {
	// Start with the DefaultTransport for sane defaults.
	transport := http.DefaultTransport.(*http.Transport).Clone()
	// Conservatively disable HTTP keep-alives as this program will only
	// ever need a single HTTP request.
	transport.DisableKeepAlives = true
	// Timeout early if the server doesn't even return the headers.
	transport.ResponseHeaderTimeout = time.Minute
	tlsConfig := &tls.Config{InsecureSkipVerify: skipServerCertCheck}
	if certificate != "" && key != "" {
		cert, err := tls.LoadX509KeyPair(certificate, key)
		if err != nil {
			return nil, err
		}
		tlsConfig.Certificates = []tls.Certificate{cert}
	}
	transport.TLSClientConfig = tlsConfig
	return transport, nil
}

func main() {

	flag.IntVar(&portFlag, "port", 8090, "The port to listen for requests")
	flag.IntVar(&portFlagTLS, "port-tls", 8443, "The port to listen for TLS requests")
	flag.Parse()

	if *help {
		flag.Usage()
		os.Exit(0)
	}

	// logger.Print("Hello, log file!")
	// logger.Print(*serverCert)
	// logger.Print(*serverKey)
	// logger.Print(*enforceServerCertCheck)
	// fmt.Print(&buf)

	// setup the request mux, prometheus registry and all the handlers for routes
	mux, registry = setup()

	// two options for ports - the standard HTTP then an optional HTTPS one.
	portStr := strconv.Itoa(portFlag)
	portTLSStr := strconv.Itoa(portFlagTLS)

	wg.Add(1)
	go func() {
		fmt.Println("server started on port", portStr)
		err := http.ListenAndServe(":"+string(portStr), mux)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
		}
	}()

	if !*disableTLS {
		wg.Add(1)
		go func() {
			transport, err := makeTransport(*serverCert, *serverKey, !*enforceServerCertCheck)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			http.DefaultTransport = transport
			fmt.Println("server started on TLS port", portTLSStr)
			err = http.ListenAndServeTLS(":"+string(portTLSStr), *serverCert, *serverKey, mux)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
			}
		}()
	}

	// Wait for the goroutines above to finish. There will be at least 1 for the standard HTTP listener.
	wg.Wait()
	fmt.Println("server shutting down")
}

```

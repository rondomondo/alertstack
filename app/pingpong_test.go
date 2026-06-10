package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	cfg := &Config{
		Port:            0,
		PortTLS:         0,
		DisableTLS:      true,
		InsecureAllowed: true,
	}
	srv := NewServer(cfg)
	srv.setupRoutes()
	return httptest.NewServer(srv.mux)
}

func promTextBody(metric string) io.Reader {
	return strings.NewReader(metric)
}

func jsonMetricBody(t *testing.T, name string, labels map[string]string, value float64) io.Reader {
	t.Helper()
	info := MetricsInfo{
		{
			Name: name,
			Type: "COUNTER",
			Metrics: []Metric{
				{Labels: labels, Value: fmt.Sprintf("%.0f", value)},
			},
		},
	}
	b, err := json.Marshal(info)
	if err != nil {
		t.Fatalf("marshal metric body: %v", err)
	}
	return bytes.NewReader(b)
}

func TestPingEndpoint(t *testing.T) {
	ts := newTestServer(t)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/ping")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.HasPrefix(string(body), "PONG") {
		t.Errorf("expected body to start with PONG, got: %s", body)
	}
}

func TestTimeEndpoint(t *testing.T) {
	ts := newTestServer(t)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/time")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "The time is:") {
		t.Errorf("unexpected body: %s", body)
	}
}

func TestEchoEndpoint(t *testing.T) {
	ts := newTestServer(t)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/echo")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "GET /echo") {
		t.Errorf("expected echo to contain request dump, got: %s", body)
	}
}

func TestCreateHandler_PromText(t *testing.T) {
	ts := newTestServer(t)
	defer ts.Close()

	metric := "envoy_cluster_upstream_rq_total{cluster_name=\"frontend\",envoy_response_code=\"503\",envoy_response_code_class=\"5xx\",job=\"envoy\",severity=\"critical\"} 6\n"

	// prom text is sent as x-www-form-urlencoded
	resp, err := http.Post(
		ts.URL+"/create",
		"application/x-www-form-urlencoded",
		promTextBody(metric),
	)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 200, got %d: %s", resp.StatusCode, body)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "created metric") {
		t.Errorf("expected 'created metric' in response, got: %s", body)
	}
}

func TestCreateHandler_JSON(t *testing.T) {
	ts := newTestServer(t)
	defer ts.Close()

	body := jsonMetricBody(t, "test_json_metric", map[string]string{
		"env":      "test",
		"severity": "info",
	}, 42)

	resp, err := http.Post(ts.URL+"/create", "application/json", body)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 200, got %d: %s", resp.StatusCode, b)
	}
	b, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(b), "created metric") {
		t.Errorf("expected 'created metric' in response, got: %s", b)
	}
}

func TestCreateHandler_NoLabels(t *testing.T) {
	ts := newTestServer(t)
	defer ts.Close()

	body := jsonMetricBody(t, "metric_with_no_labels", map[string]string{}, 1)

	resp, err := http.Post(ts.URL+"/create", "application/json", body)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 200, got %d: %s", resp.StatusCode, b)
	}
}

func TestUpdateHandler_ExistingMetric(t *testing.T) {
	ts := newTestServer(t)
	defer ts.Close()

	labels := map[string]string{"env": "test", "job": "ci"}

	// create first
	createBody := jsonMetricBody(t, "update_test_metric", labels, 1)
	resp, err := http.Post(ts.URL+"/create", "application/json", createBody)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("create failed with %d", resp.StatusCode)
	}

	// then update
	updateBody := jsonMetricBody(t, "update_test_metric", labels, 1)
	resp, err = http.Post(ts.URL+"/update", "application/json", updateBody)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected 200, got %d: %s", resp.StatusCode, b)
	}
	b, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(b), "update_test_metric") {
		t.Errorf("expected metric name in update response, got: %s", b)
	}
}

func TestUpdateHandler_UnknownMetric(t *testing.T) {
	ts := newTestServer(t)
	defer ts.Close()

	body := jsonMetricBody(t, "nonexistent_metric", map[string]string{"env": "test"}, 1)
	resp, err := http.Post(ts.URL+"/update", "application/json", body)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	// update of unknown metric returns 200 with empty body (logged server-side)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
}

func TestRequestIsAllowed_RejectsGet(t *testing.T) {
	ts := newTestServer(t)
	defer ts.Close()

	for _, path := range []string{"/create", "/update"} {
		resp, err := http.Get(ts.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Errorf("%s GET: expected 405, got %d", path, resp.StatusCode)
		}
	}
}

func TestRequestIsAllowed_RejectsMissingContentType(t *testing.T) {
	ts := newTestServer(t)
	defer ts.Close()

	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/create", strings.NewReader("data"))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("expected 400, got %d", resp.StatusCode)
	}
}

func TestRequestIsAllowed_RejectsInvalidContentType(t *testing.T) {
	ts := newTestServer(t)
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/create", "text/plain", strings.NewReader("data"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnsupportedMediaType {
		t.Errorf("expected 415, got %d", resp.StatusCode)
	}
}

func TestWebhookHandler_RejectsGet(t *testing.T) {
	ts := newTestServer(t)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/v2/enqueue")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("expected 405, got %d", resp.StatusCode)
	}
}

func TestWebhookHandler_RejectsNonJSON(t *testing.T) {
	ts := newTestServer(t)
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/v2/enqueue", "text/plain", strings.NewReader("data"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnsupportedMediaType {
		t.Errorf("expected 415, got %d", resp.StatusCode)
	}
}

func TestWebhookHandler_AcceptsJSON(t *testing.T) {
	ts := newTestServer(t)
	defer ts.Close()

	payload := `[{"name":"envoy_cluster_upstream_rq_total","type":"COUNTER","metrics":[{"labels":{"cluster_name":"frontend","envoy_response_code_class":"5xx","severity":"critical"},"value":"6"}]}]`
	resp, err := http.Post(ts.URL+"/v2/enqueue", "application/json", strings.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("expected 200, got %d", resp.StatusCode)
	}
}

func TestHelpers_CreateMetricLine(t *testing.T) {
	line := createMetricLine("foo", map[string]string{"a": "1", "b": "2"}, "42")
	if !strings.HasPrefix(line, "foo{") {
		t.Errorf("unexpected line: %s", line)
	}
	if !strings.Contains(line, "42") {
		t.Errorf("value missing from line: %s", line)
	}
	// labels must be sorted
	if strings.Index(line, "a=") > strings.Index(line, "b=") {
		t.Errorf("labels not sorted in: %s", line)
	}
}

func TestHelpers_GetKeys(t *testing.T) {
	keys := getKeys(map[string]string{"z": "1", "a": "2", "m": "3"})
	if keys[0] != "a" || keys[1] != "m" || keys[2] != "z" {
		t.Errorf("keys not sorted: %v", keys)
	}
}

func TestHelpers_Contains(t *testing.T) {
	if !contains([]string{"a", "b", "c"}, "b") {
		t.Error("expected contains to return true")
	}
	if contains([]string{"a", "b"}, "z") {
		t.Error("expected contains to return false")
	}
}

func TestHelpers_SplitByEmptyNewline(t *testing.T) {
	parts := splitByEmptyNewline("headers\n\nbody")
	if len(parts) != 2 {
		t.Fatalf("expected 2 parts, got %d", len(parts))
	}
	if parts[0] != "headers" || parts[1] != "body" {
		t.Errorf("unexpected split: %v", parts)
	}
}

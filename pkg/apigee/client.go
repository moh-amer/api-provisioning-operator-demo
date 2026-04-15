// Package apigee provides a REST client for the Apigee X Management API.
//
// This is the key difference from the StaticSite operator:
// Instead of calling the Kubernetes API to create child resources,
// we call an EXTERNAL REST API (Apigee) to manage API proxies.
//
// API Reference: https://cloud.google.com/apigee/docs/reference/apis/apigee/rest
package apigee

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"strings"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
	"k8s.io/klog/v2"
)

const (
	apigeeBaseURL = "https://apigee.googleapis.com/v1"
	scope         = "https://www.googleapis.com/auth/cloud-platform"
)

// Client wraps the Apigee Management API.
type Client struct {
	httpClient *http.Client
}

// NewClient creates an Apigee client using Google Application Default Credentials.
// Works with: GKE Workload Identity, SA key JSON, gcloud auth application-default login.
func NewClient(ctx context.Context) (*Client, error) {
	creds, err := google.FindDefaultCredentials(ctx, scope)
	if err != nil {
		return nil, fmt.Errorf("failed to find default credentials: %w", err)
	}
	return &Client{
		httpClient: oauth2.NewClient(ctx, creds.TokenSource),
	}, nil
}

// ProxyInfo represents an Apigee API proxy.
type ProxyInfo struct {
	Name     string   `json:"name"`
	Revision []string `json:"revision"`
}

// GetProxy checks if an API proxy exists.
func (c *Client) GetProxy(ctx context.Context, org, proxyName string) (*ProxyInfo, error) {
	url := fmt.Sprintf("%s/organizations/%s/apis/%s", apigeeBaseURL, org, proxyName)
	resp, err := c.doRequest(ctx, "GET", url, nil, "")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == 404 {
		return nil, nil // Not found
	}
	if resp.StatusCode != 200 {
		return nil, c.readError(resp)
	}

	var info ProxyInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return nil, fmt.Errorf("failed to decode proxy info: %w", err)
	}
	return &info, nil
}

// CreateProxyWithBundle creates or updates an API proxy by uploading a proxy bundle ZIP.
// The bundle is generated in-memory from the provided parameters.
func (c *Client) CreateProxyWithBundle(ctx context.Context, org, proxyName, basePath, targetURL, description string) (int, error) {
	logger := klog.FromContext(ctx)

	// Generate the proxy bundle ZIP in memory
	bundleBytes, err := generateProxyBundle(proxyName, basePath, targetURL, description)
	if err != nil {
		return 0, fmt.Errorf("failed to generate proxy bundle: %w", err)
	}
	logger.V(4).Info("Generated proxy bundle", "proxyName", proxyName, "size", len(bundleBytes))

	// Upload as multipart/form-data
	url := fmt.Sprintf("%s/organizations/%s/apis?action=import&name=%s", apigeeBaseURL, org, proxyName)

	var buf bytes.Buffer
	writer := multipart.NewWriter(&buf)
	part, err := writer.CreateFormFile("file", proxyName+".zip")
	if err != nil {
		return 0, fmt.Errorf("failed to create form file: %w", err)
	}
	if _, err := part.Write(bundleBytes); err != nil {
		return 0, fmt.Errorf("failed to write bundle: %w", err)
	}
	writer.Close()

	resp, err := c.doRequest(ctx, "POST", url, &buf, writer.FormDataContentType())
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 && resp.StatusCode != 201 {
		return 0, c.readError(resp)
	}

	var result struct {
		Revision string `json:"revision"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return 0, fmt.Errorf("failed to decode create response: %w", err)
	}

	rev := 1
	fmt.Sscanf(result.Revision, "%d", &rev)
	logger.Info("Created API proxy revision", "proxyName", proxyName, "revision", rev)
	return rev, nil
}

// DeployRevision deploys a specific revision to an environment.
func (c *Client) DeployRevision(ctx context.Context, org, env, proxyName string, revision int) error {
	logger := klog.FromContext(ctx)
	url := fmt.Sprintf("%s/organizations/%s/environments/%s/apis/%s/revisions/%d/deployments?override=true",
		apigeeBaseURL, org, env, proxyName, revision)

	resp, err := c.doRequest(ctx, "POST", url, nil, "")
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return c.readError(resp)
	}

	logger.Info("Deployed API proxy", "proxyName", proxyName, "environment", env, "revision", revision)
	return nil
}

// UndeployRevision undeploys a revision from an environment.
func (c *Client) UndeployRevision(ctx context.Context, org, env, proxyName string, revision int) error {
	logger := klog.FromContext(ctx)
	url := fmt.Sprintf("%s/organizations/%s/environments/%s/apis/%s/revisions/%d/deployments",
		apigeeBaseURL, org, env, proxyName, revision)

	resp, err := c.doRequest(ctx, "DELETE", url, nil, "")
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 && resp.StatusCode != 404 {
		return c.readError(resp)
	}

	logger.Info("Undeployed API proxy", "proxyName", proxyName, "environment", env, "revision", revision)
	return nil
}

// DeleteProxy deletes an API proxy and all its revisions.
func (c *Client) DeleteProxy(ctx context.Context, org, proxyName string) error {
	logger := klog.FromContext(ctx)
	url := fmt.Sprintf("%s/organizations/%s/apis/%s", apigeeBaseURL, org, proxyName)

	resp, err := c.doRequest(ctx, "DELETE", url, nil, "")
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 && resp.StatusCode != 404 {
		return c.readError(resp)
	}

	logger.Info("Deleted API proxy", "proxyName", proxyName)
	return nil
}

// envGroupsResponse is the API response from GET /organizations/{org}/envgroups.
type envGroupsResponse struct {
	EnvironmentGroups []struct {
		Name      string   `json:"name"`
		Hostnames []string `json:"hostnames"`
		State     string   `json:"state"`
	} `json:"environmentGroups"`
}

// envGroupAttachmentsResponse is the API response from GET /envgroups/{group}/attachments.
type envGroupAttachmentsResponse struct {
	Attachments []struct {
		Environment string `json:"environment"`
	} `json:"environmentGroupAttachments"`
}

// GetEnvironmentHostname returns the real public hostname for the given Apigee environment
// by querying the Environment Groups API. This is the correct way to get the URL for
// Apigee X — the hostname is configured per environment group, not derived from the org name.
//
// It prefers hostnames in this order:
//  1. nip.io hostnames (used by Apigee eval orgs with auto-assigned IPs)
//  2. Any other hostname attached to the environment's group
//
// Falls back to the legacy guessed format if the API call fails.
func (c *Client) GetEnvironmentHostname(ctx context.Context, org, env string) (string, error) {
	logger := klog.FromContext(ctx)

	url := fmt.Sprintf("%s/organizations/%s/envgroups", apigeeBaseURL, org)
	resp, err := c.doRequest(ctx, "GET", url, nil, "")
	if err != nil {
		return "", fmt.Errorf("failed to list envgroups: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return "", c.readError(resp)
	}

	var groups envGroupsResponse
	if err := json.NewDecoder(resp.Body).Decode(&groups); err != nil {
		return "", fmt.Errorf("failed to decode envgroups: %w", err)
	}

	// For each active envgroup, check if our environment is attached
	for _, group := range groups.EnvironmentGroups {
		if group.State != "ACTIVE" || len(group.Hostnames) == 0 {
			continue
		}

		// Check attachments
		attachURL := fmt.Sprintf("%s/organizations/%s/envgroups/%s/attachments", apigeeBaseURL, org, group.Name)
		attachResp, err := c.doRequest(ctx, "GET", attachURL, nil, "")
		if err != nil {
			logger.V(4).Info("Failed to get envgroup attachments", "group", group.Name, "err", err)
			continue
		}
		defer attachResp.Body.Close()

		var attachments envGroupAttachmentsResponse
		if err := json.NewDecoder(attachResp.Body).Decode(&attachments); err != nil {
			continue
		}

		// Check if our environment is attached to this group
		for _, attachment := range attachments.Attachments {
			if attachment.Environment != env {
				continue
			}
			// Found the group — pick the best hostname
			// Prefer nip.io (eval auto-assigned IPs), otherwise take the first one
			for _, h := range group.Hostnames {
				if strings.Contains(h, "nip.io") {
					logger.V(4).Info("Found nip.io hostname for environment", "env", env, "hostname", h)
					return h, nil
				}
			}
			// Return first available hostname
			logger.V(4).Info("Found hostname for environment", "env", env, "hostname", group.Hostnames[0])
			return group.Hostnames[0], nil
		}
	}

	return "", fmt.Errorf("no active envgroup found for environment %q in org %q", env, org)
}

// doRequest performs an authenticated HTTP request.
func (c *Client) doRequest(ctx context.Context, method, url string, body io.Reader, contentType string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	return c.httpClient.Do(req)
}

// readError reads the error body from a failed response.
func (c *Client) readError(resp *http.Response) error {
	body, _ := io.ReadAll(resp.Body)
	return fmt.Errorf("apigee API error (HTTP %d): %s", resp.StatusCode, strings.TrimSpace(string(body)))
}

// generateProxyBundle creates an Apigee proxy bundle ZIP in memory.
// A proxy bundle is a ZIP file containing XML configuration:
//
//	apiproxy/
//	├── {proxyName}.xml          (main proxy config)
//	├── proxies/
//	│   └── default.xml          (ProxyEndpoint — the incoming side)
//	└── targets/
//	    └── default.xml          (TargetEndpoint — the backend side)
func generateProxyBundle(proxyName, basePath, targetURL, description string) ([]byte, error) {
	if description == "" {
		description = "Managed by Kubernetes ApigeeAPI operator"
	}

	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)

	// Main proxy config
	mainXML := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy revision="1" name="%s">
  <Description>%s</Description>
  <BasePaths>%s</BasePaths>
  <Policies/>
  <ProxyEndpoints>
    <ProxyEndpoint>default</ProxyEndpoint>
  </ProxyEndpoints>
  <TargetEndpoints>
    <TargetEndpoint>default</TargetEndpoint>
  </TargetEndpoints>
</APIProxy>`, proxyName, description, basePath)

	// ProxyEndpoint — defines the incoming request handling
	proxyXML := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ProxyEndpoint name="default">
  <PreFlow name="PreFlow">
    <Request/>
    <Response/>
  </PreFlow>
  <Flows/>
  <PostFlow name="PostFlow">
    <Request/>
    <Response/>
  </PostFlow>
  <HTTPProxyConnection>
    <BasePath>%s</BasePath>
  </HTTPProxyConnection>
  <RouteRule name="default">
    <TargetEndpoint>default</TargetEndpoint>
  </RouteRule>
</ProxyEndpoint>`, basePath)

	// TargetEndpoint — defines the backend URL
	targetXML := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<TargetEndpoint name="default">
  <PreFlow name="PreFlow">
    <Request/>
    <Response/>
  </PreFlow>
  <Flows/>
  <PostFlow name="PostFlow">
    <Request/>
    <Response/>
  </PostFlow>
  <HTTPTargetConnection>
    <URL>%s</URL>
  </HTTPTargetConnection>
</TargetEndpoint>`, targetURL)

	files := map[string]string{
		"apiproxy/" + proxyName + ".xml": mainXML,
		"apiproxy/proxies/default.xml":   proxyXML,
		"apiproxy/targets/default.xml":   targetXML,
	}

	for name, content := range files {
		fw, err := zw.Create(name)
		if err != nil {
			return nil, err
		}
		if _, err := fw.Write([]byte(content)); err != nil {
			return nil, err
		}
	}

	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

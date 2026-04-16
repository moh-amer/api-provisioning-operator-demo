package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// +genclient
// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object

// ApigeeAPI is the CRD that manages an API proxy on Google Cloud Apigee.
// When created, the controller:
//   1. Generates a proxy bundle (ZIP) with the specified basePath and targetUrl
//   2. Uploads it to the Apigee organization via REST API
//   3. Deploys the revision to the specified environment
//   4. Reports the public URL and deployment status in .status
//
// When deleted, a Finalizer ensures the proxy is undeployed and removed from Apigee
// before the CR is garbage collected. (OwnerReferences can't be used for external resources.)
type ApigeeAPI struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   ApigeeAPISpec   `json:"spec"`
	Status ApigeeAPIStatus `json:"status"`
}

// PolicySpec defines a single Apigee policy to attach to the proxy.
// All policies run in ProxyEndpoint PreFlow Request, in declaration order,
// after the built-in StripBasePath policy.
type PolicySpec struct {
	// Type is the Apigee policy type.
	// Supported: Quota, SpikeArrest, VerifyAPIKey, CORS, OAuthV2.
	Type string `json:"type"`
	// Name is the policy instance name in Apigee.
	// Defaults to "{Type}-{index}". Must be unique within the proxy.
	Name string `json:"name,omitempty"`
	// Config holds policy-specific key-value configuration.
	// See README for supported keys per policy type.
	Config map[string]string `json:"config,omitempty"`
}

// ApigeeAPISpec defines the desired state — what API proxy to create on Apigee.
type ApigeeAPISpec struct {
	// Organization is the Apigee organization name (GCP project for Apigee X).
	Organization string `json:"organization"`
	// Environment is the Apigee environment to deploy to (e.g. "eval", "dev", "prod").
	Environment string `json:"environment"`
	// ProxyName is the name of the API proxy in Apigee. Defaults to CR name if empty.
	ProxyName string `json:"proxyName,omitempty"`
	// BasePath is the URL path prefix for the API (e.g. "/hello").
	BasePath string `json:"basePath"`
	// TargetURL is the backend URL the proxy routes to (e.g. "https://httpbin.org").
	TargetURL string `json:"targetUrl"`
	// Description is an optional description for the API proxy.
	Description string `json:"description,omitempty"`
	// Policies is the ordered list of Apigee policies to attach to the proxy.
	// Policies run in ProxyEndpoint PreFlow Request, in declaration order,
	// after the built-in StripBasePath policy.
	Policies []PolicySpec `json:"policies,omitempty"`
}

// ApigeeAPIStatus defines the observed state — what Apigee reports back.
type ApigeeAPIStatus struct {
	// ProxyRevision is the currently deployed revision number.
	ProxyRevision int `json:"proxyRevision,omitempty"`
	// Deployed indicates whether the proxy is deployed to the environment.
	Deployed bool `json:"deployed"`
	// PublicURL is the public endpoint of the deployed API.
	PublicURL string `json:"publicUrl,omitempty"`
	// Message contains a human-readable status message.
	Message string `json:"message,omitempty"`
	// Phase is the current lifecycle phase: Pending, Creating, Deploying, Ready, Error, Deleting.
	Phase string `json:"phase,omitempty"`
	// ObservedGeneration is the .metadata.generation that was last reconciled.
	// Used to detect spec changes and avoid re-deploying when only status changed.
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
}

// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object

// ApigeeAPIList is a list of ApigeeAPI resources.
type ApigeeAPIList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata"`

	Items []ApigeeAPI `json:"items"`
}

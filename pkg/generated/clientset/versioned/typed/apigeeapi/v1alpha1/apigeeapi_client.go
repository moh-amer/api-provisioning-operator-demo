package v1alpha1

import (
	"net/http"

	apigeeapiv1alpha1 "github.com/devops-demo/apigee-api-operator/pkg/apis/apigeeapi/v1alpha1"
	"github.com/devops-demo/apigee-api-operator/pkg/generated/clientset/versioned/scheme"
	rest "k8s.io/client-go/rest"
)

type ApigeeapiV1alpha1Interface interface {
	RESTClient() rest.Interface
	ApigeeAPIsGetter
}

type ApigeeapiV1alpha1Client struct {
	restClient rest.Interface
}

func (c *ApigeeapiV1alpha1Client) ApigeeAPIs(namespace string) ApigeeAPIInterface {
	return newApigeeAPIs(c, namespace)
}

func (c *ApigeeapiV1alpha1Client) RESTClient() rest.Interface {
	if c == nil {
		return nil
	}
	return c.restClient
}

func NewForConfig(c *rest.Config) (*ApigeeapiV1alpha1Client, error) {
	config := *c
	if err := setConfigDefaults(&config); err != nil {
		return nil, err
	}
	httpClient, err := rest.HTTPClientFor(&config)
	if err != nil {
		return nil, err
	}
	return NewForConfigAndClient(&config, httpClient)
}

func NewForConfigAndClient(c *rest.Config, h *http.Client) (*ApigeeapiV1alpha1Client, error) {
	config := *c
	if err := setConfigDefaults(&config); err != nil {
		return nil, err
	}
	client, err := rest.RESTClientForConfigAndClient(&config, h)
	if err != nil {
		return nil, err
	}
	return &ApigeeapiV1alpha1Client{client}, nil
}

func setConfigDefaults(config *rest.Config) error {
	gv := apigeeapiv1alpha1.SchemeGroupVersion
	config.GroupVersion = &gv
	config.APIPath = "/apis"
	config.NegotiatedSerializer = scheme.Codecs.WithoutConversion()
	if config.UserAgent == "" {
		config.UserAgent = rest.DefaultKubernetesUserAgent()
	}
	return nil
}

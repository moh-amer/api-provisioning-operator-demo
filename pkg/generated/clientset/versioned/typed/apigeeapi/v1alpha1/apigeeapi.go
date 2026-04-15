package v1alpha1

import (
	"context"
	"time"

	apigeeapiv1alpha1 "github.com/devops-demo/apigee-api-operator/pkg/apis/apigeeapi/v1alpha1"
	scheme "github.com/devops-demo/apigee-api-operator/pkg/generated/clientset/versioned/scheme"
	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	watch "k8s.io/apimachinery/pkg/watch"
	rest "k8s.io/client-go/rest"
)

type ApigeeAPIsGetter interface {
	ApigeeAPIs(namespace string) ApigeeAPIInterface
}

type ApigeeAPIInterface interface {
	Create(ctx context.Context, api *apigeeapiv1alpha1.ApigeeAPI, opts v1.CreateOptions) (*apigeeapiv1alpha1.ApigeeAPI, error)
	Update(ctx context.Context, api *apigeeapiv1alpha1.ApigeeAPI, opts v1.UpdateOptions) (*apigeeapiv1alpha1.ApigeeAPI, error)
	UpdateStatus(ctx context.Context, api *apigeeapiv1alpha1.ApigeeAPI, opts v1.UpdateOptions) (*apigeeapiv1alpha1.ApigeeAPI, error)
	Delete(ctx context.Context, name string, opts v1.DeleteOptions) error
	Get(ctx context.Context, name string, opts v1.GetOptions) (*apigeeapiv1alpha1.ApigeeAPI, error)
	List(ctx context.Context, opts v1.ListOptions) (*apigeeapiv1alpha1.ApigeeAPIList, error)
	Watch(ctx context.Context, opts v1.ListOptions) (watch.Interface, error)
}

type apigeeAPIs struct {
	client rest.Interface
	ns     string
}

func newApigeeAPIs(c *ApigeeapiV1alpha1Client, namespace string) *apigeeAPIs {
	return &apigeeAPIs{client: c.RESTClient(), ns: namespace}
}

func (c *apigeeAPIs) Get(ctx context.Context, name string, options v1.GetOptions) (result *apigeeapiv1alpha1.ApigeeAPI, err error) {
	result = &apigeeapiv1alpha1.ApigeeAPI{}
	err = c.client.Get().Namespace(c.ns).Resource("apigeeapis").Name(name).VersionedParams(&options, scheme.ParameterCodec).Do(ctx).Into(result)
	return
}

func (c *apigeeAPIs) List(ctx context.Context, opts v1.ListOptions) (result *apigeeapiv1alpha1.ApigeeAPIList, err error) {
	var timeout time.Duration
	if opts.TimeoutSeconds != nil {
		timeout = time.Duration(*opts.TimeoutSeconds) * time.Second
	}
	result = &apigeeapiv1alpha1.ApigeeAPIList{}
	err = c.client.Get().Namespace(c.ns).Resource("apigeeapis").VersionedParams(&opts, scheme.ParameterCodec).Timeout(timeout).Do(ctx).Into(result)
	return
}

func (c *apigeeAPIs) Watch(ctx context.Context, opts v1.ListOptions) (watch.Interface, error) {
	var timeout time.Duration
	if opts.TimeoutSeconds != nil {
		timeout = time.Duration(*opts.TimeoutSeconds) * time.Second
	}
	opts.Watch = true
	return c.client.Get().Namespace(c.ns).Resource("apigeeapis").VersionedParams(&opts, scheme.ParameterCodec).Timeout(timeout).Watch(ctx)
}

func (c *apigeeAPIs) Create(ctx context.Context, api *apigeeapiv1alpha1.ApigeeAPI, opts v1.CreateOptions) (result *apigeeapiv1alpha1.ApigeeAPI, err error) {
	result = &apigeeapiv1alpha1.ApigeeAPI{}
	err = c.client.Post().Namespace(c.ns).Resource("apigeeapis").VersionedParams(&opts, scheme.ParameterCodec).Body(api).Do(ctx).Into(result)
	return
}

func (c *apigeeAPIs) Update(ctx context.Context, api *apigeeapiv1alpha1.ApigeeAPI, opts v1.UpdateOptions) (result *apigeeapiv1alpha1.ApigeeAPI, err error) {
	result = &apigeeapiv1alpha1.ApigeeAPI{}
	err = c.client.Put().Namespace(c.ns).Resource("apigeeapis").Name(api.Name).VersionedParams(&opts, scheme.ParameterCodec).Body(api).Do(ctx).Into(result)
	return
}

func (c *apigeeAPIs) UpdateStatus(ctx context.Context, api *apigeeapiv1alpha1.ApigeeAPI, opts v1.UpdateOptions) (result *apigeeapiv1alpha1.ApigeeAPI, err error) {
	result = &apigeeapiv1alpha1.ApigeeAPI{}
	err = c.client.Put().Namespace(c.ns).Resource("apigeeapis").Name(api.Name).SubResource("status").VersionedParams(&opts, scheme.ParameterCodec).Body(api).Do(ctx).Into(result)
	return
}

func (c *apigeeAPIs) Delete(ctx context.Context, name string, opts v1.DeleteOptions) error {
	return c.client.Delete().Namespace(c.ns).Resource("apigeeapis").Name(name).Body(&opts).Do(ctx).Error()
}

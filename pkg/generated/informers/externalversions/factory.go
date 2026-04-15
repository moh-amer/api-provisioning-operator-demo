package externalversions

import (
	"fmt"
	"reflect"
	"sync"
	"time"

	apigeeapiv1alpha1 "github.com/devops-demo/apigee-api-operator/pkg/apis/apigeeapi/v1alpha1"
	clientset "github.com/devops-demo/apigee-api-operator/pkg/generated/clientset/versioned"
	apigeeapiinformers "github.com/devops-demo/apigee-api-operator/pkg/generated/informers/externalversions/apigeeapi"
	internalinterfaces "github.com/devops-demo/apigee-api-operator/pkg/generated/informers/externalversions/internalinterfaces"
	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	runtime "k8s.io/apimachinery/pkg/runtime"
	schema "k8s.io/apimachinery/pkg/runtime/schema"
	cache "k8s.io/client-go/tools/cache"
)

type SharedInformerOption func(*sharedInformerFactory) *sharedInformerFactory

func WithNamespace(namespace string) SharedInformerOption {
	return func(factory *sharedInformerFactory) *sharedInformerFactory {
		factory.namespace = namespace
		return factory
	}
}

type sharedInformerFactory struct {
	client           clientset.Interface
	namespace        string
	tweakListOptions func(*v1.ListOptions)
	lock             sync.Mutex
	defaultResync    time.Duration
	informers        map[reflect.Type]cache.SharedIndexInformer
	startedInformers map[reflect.Type]bool
}

type SharedInformerFactory interface {
	Start(stopCh <-chan struct{})
	WaitForCacheSync(stopCh <-chan struct{}) map[reflect.Type]bool
	InformerFor(obj runtime.Object, newFunc internalinterfaces.NewInformerFunc) cache.SharedIndexInformer
	Apigeeapi() apigeeapiinformers.Interface
	ForResource(resource schema.GroupVersionResource) (GenericInformer, error)
}

func NewSharedInformerFactory(client clientset.Interface, defaultResync time.Duration) SharedInformerFactory {
	return NewSharedInformerFactoryWithOptions(client, defaultResync)
}

func NewSharedInformerFactoryWithOptions(client clientset.Interface, defaultResync time.Duration, options ...SharedInformerOption) SharedInformerFactory {
	factory := &sharedInformerFactory{
		client:           client,
		namespace:        v1.NamespaceAll,
		defaultResync:    defaultResync,
		informers:        make(map[reflect.Type]cache.SharedIndexInformer),
		startedInformers: make(map[reflect.Type]bool),
	}
	for _, opt := range options {
		factory = opt(factory)
	}
	return factory
}

func (f *sharedInformerFactory) Start(stopCh <-chan struct{}) {
	f.lock.Lock()
	defer f.lock.Unlock()
	for informerType, informer := range f.informers {
		if !f.startedInformers[informerType] {
			go informer.Run(stopCh)
			f.startedInformers[informerType] = true
		}
	}
}

func (f *sharedInformerFactory) WaitForCacheSync(stopCh <-chan struct{}) map[reflect.Type]bool {
	informers := func() map[reflect.Type]cache.SharedIndexInformer {
		f.lock.Lock()
		defer f.lock.Unlock()
		informers := make(map[reflect.Type]cache.SharedIndexInformer)
		for informerType, informer := range f.informers {
			if f.startedInformers[informerType] {
				informers[informerType] = informer
			}
		}
		return informers
	}()
	res := make(map[reflect.Type]bool)
	for informType, informer := range informers {
		res[informType] = cache.WaitForCacheSync(stopCh, informer.HasSynced)
	}
	return res
}

func (f *sharedInformerFactory) InformerFor(obj runtime.Object, newFunc internalinterfaces.NewInformerFunc) cache.SharedIndexInformer {
	f.lock.Lock()
	defer f.lock.Unlock()
	informerType := reflect.TypeOf(obj)
	informer, exists := f.informers[informerType]
	if exists {
		return informer
	}
	informer = newFunc(f.client, f.defaultResync)
	f.informers[informerType] = informer
	return informer
}

func (f *sharedInformerFactory) Apigeeapi() apigeeapiinformers.Interface {
	return apigeeapiinformers.New(f, f.namespace, f.tweakListOptions)
}

type GenericInformer interface {
	Informer() cache.SharedIndexInformer
	Lister() cache.GenericLister
}

type genericInformer struct {
	informer cache.SharedIndexInformer
	resource schema.GroupResource
}

func (f *genericInformer) Informer() cache.SharedIndexInformer { return f.informer }
func (f *genericInformer) Lister() cache.GenericLister {
	return cache.NewGenericLister(f.Informer().GetIndexer(), f.resource)
}

func (f *sharedInformerFactory) ForResource(resource schema.GroupVersionResource) (GenericInformer, error) {
	switch resource {
	case apigeeapiv1alpha1.SchemeGroupVersion.WithResource("apigeeapis"):
		return &genericInformer{informer: f.Apigeeapi().V1alpha1().Informer(), resource: resource.GroupResource()}, nil
	}
	return nil, fmt.Errorf("no informer found for %v", resource)
}
